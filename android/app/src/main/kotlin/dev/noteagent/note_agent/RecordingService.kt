package dev.noteagent.note_agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.MediaRecorder
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ResultReceiver
import android.os.SystemClock
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.min

/** Owns capture independently of the Activity/Flutter screen. Never restarts a
 * microphone after process death. Only an explicit visible-app Start can start.
 * Completed containers have an atomic, fsynced journal beside the private source.
 */
class RecordingService : Service() {
    companion object {
        const val START = "dev.noteagent.recording.START"
        const val STOP = "dev.noteagent.recording.STOP"
        const val TOGGLE = "dev.noteagent.recording.TOGGLE"
        private const val CHANNEL = "note-agent-recording"
        private const val NOTIFICATION = 902
        const val MAX_DURATION = 600_000L
        private const val MAX_WALL_TIME = 1_800_000L
        var current: RecordingService? = null
            private set

        fun source(context: Context, path: String): File {
            val file = File(path).canonicalFile
            val root = File(context.filesDir, "workspace").canonicalFile
            require(file.path.startsWith(root.path + File.separator) &&
                file.parentFile?.name == "recordings" && file.extension == "m4a") {
                "录音位置无效，原件未改动。"
            }
            return file
        }

        fun recovered(context: Context, path: String): Map<String, Any?>? {
            val source = source(context, path)
            current?.let { if (it.original?.path == source.path) return it.snapshot() }
            val journal = AtomicFile(File(source.path + ".state.json"))
            return try {
                val json = journal.openRead().use { JSONObject(it.readBytes().toString(Charsets.UTF_8)) }
                if (json.getString("path") != source.path || !json.getBoolean("complete")) null
                else mapOf("phase" to "stopped", "durationMs" to json.getLong("durationMs"),
                    "level" to 0.0, "error" to if (json.isNull("error")) null else json.getString("error"))
            } catch (_: Exception) { null }
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var recorder: MediaRecorder? = null
    private var original: File? = null
    private var phase = "stopped"
    private var duration = 0L
    private var segmentStart = 0L
    private var wallStart = 0L
    private var failure: String? = null
    private var finishing = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        current = this
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "录音状态", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "录音或暂停时持续显示，可结束并保存；不包含原音频内容。"
                }
            )
        }
    }

    @Suppress("DEPRECATION")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            START -> {
                val receiver = intent.getParcelableExtra<ResultReceiver>("result")
                if (recorder != null || original != null) {
                    receiver?.send(1, Bundle().apply { putString("error", "请先结束当前录音。") })
                    return START_NOT_STICKY
                }
                try {
                    val file = source(this, requireNotNull(intent.getStringExtra("path")))
                    require(!file.exists()) { "录音原件已存在，未覆盖。" }
                    original = file
                    if (Build.VERSION.SDK_INT >= 29) {
                        startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
                    } else startForeground(NOTIFICATION, notification())
                    file.parentFile?.mkdirs()
                    val native = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(this) else MediaRecorder()
                    recorder = native
                    native.setAudioSource(MediaRecorder.AudioSource.MIC)
                    native.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                    native.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                    native.setAudioChannels(1)
                    native.setAudioSamplingRate(22050)
                    native.setAudioEncodingBitRate(32000)
                    native.setMaxDuration(MAX_DURATION.toInt())
                    native.setMaxFileSize(4_900_000L)
                    native.setOutputFile(file.path)
                    if (Build.VERSION.SDK_INT >= 29) {
                        native.registerAudioRecordingCallback(mainExecutor,
                            object : AudioManager.AudioRecordingCallback() {
                                override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) {
                                    if (configs.any { it.isClientSilenced } && phase != "stopped") {
                                        finish("系统暂停了麦克风输入，录音已结束；现有原文件保留，请回放核对。")
                                    }
                                }
                            })
                    }
                    native.setOnInfoListener { _, what, _ ->
                        if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED ||
                            what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_FILESIZE_REACHED) finish(nativeLimit = true)
                    }
                    native.setOnErrorListener { _, _, _ -> finish("系统中断了录音，现有原文件已保留；请回放核对。") }
                    native.prepare()
                    native.start()
                    wallStart = SystemClock.elapsedRealtime()
                    segmentStart = wallStart
                    phase = "recording"
                    writeJournal(false)
                    updateNotification()
                    handler.post(tick)
                    receiver?.send(0, Bundle.EMPTY)
                } catch (_: Exception) {
                    failure = "未能开始录音。请确认麦克风权限、系统麦克风开关和可用存储，再重试；已有原件保留。"
                    recorder?.release(); recorder = null
                    phase = "stopped"
                    receiver?.send(1, Bundle().apply { putString("error", failure) })
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
            STOP -> if (phase == "stopped") stopSelf() else finish()
            TOGGLE -> try {
                if (phase == "stopped") stopSelf()
                else if (phase == "paused") resume() else pause()
            } catch (_: Exception) { finish("系统无法继续录音，现有原文件已保留；请回放核对。") }
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    private val tick = object : Runnable {
        override fun run() {
            if (phase == "stopped") return
            if (elapsed() >= MAX_DURATION || SystemClock.elapsedRealtime() - wallStart >= MAX_WALL_TIME) {
                finish()
            } else handler.postDelayed(this, 250)
        }
    }

    private fun elapsed(): Long = min(MAX_DURATION,
        duration + if (phase == "recording") SystemClock.elapsedRealtime() - segmentStart else 0)

    fun snapshot(): Map<String, Any?> = mapOf(
        "phase" to phase, "durationMs" to elapsed(),
        "level" to if (phase == "recording") try { (recorder?.maxAmplitude ?: 0) / 32767.0 } catch (_: Exception) { 0.0 } else 0.0,
        "error" to failure,
    )

    fun matches(path: String?): Boolean = path != null && original?.path == path

    fun pause() {
        if (phase != "recording") return
        recorder?.pause()
        duration = elapsed()
        phase = "paused"
        writeJournal(false)
        updateNotification()
    }

    fun resume() {
        if (phase != "paused") return
        recorder?.resume()
        segmentStart = SystemClock.elapsedRealtime()
        phase = "recording"
        writeJournal(false)
        updateNotification()
    }

    fun finish(error: String? = null, nativeLimit: Boolean = false): Map<String, Any?> {
        if (phase == "stopped" || finishing) return snapshot()
        finishing = true
        duration = elapsed()
        phase = "stopped"
        failure = error
        handler.removeCallbacks(tick)
        try {
            recorder?.stop()
        } catch (_: Exception) {
            // Android may already have stopped at its native limit before the
            // info callback arrives. The complete container is still inspected
            // below; only a known limit can tolerate that stop-state race.
            if (!nativeLimit && duration < MAX_DURATION) {
                failure = "录音未完整结束，现有原文件已保留；请尝试回放。"
            }
        } finally {
            recorder?.release(); recorder = null
        }
        try {
            original?.let { file ->
                RandomAccessFile(file, "rw").use { it.fd.sync() }
                if (failure == null) duration = NativeAudio.inspect(file)["durationMs"] as Long
            }
            writeJournal(true)
        } catch (_: Exception) {
            failure = "录音保存未确认，现有原文件已保留；请尝试回放。"
            // An incomplete/old journal never establishes successful completion.
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        finishing = false
        return snapshot()
    }

    private fun writeJournal(complete: Boolean) {
        val file = original ?: return
        val atomic = AtomicFile(File(file.path + ".state.json"))
        val stream = atomic.startWrite()
        try {
            val data = JSONObject().put("path", file.path).put("complete", complete)
                .put("durationMs", elapsed()).put("error", failure ?: JSONObject.NULL)
            stream.write(data.toString().toByteArray(Charsets.UTF_8))
            atomic.finishWrite(stream)
        } catch (error: Exception) {
            atomic.failWrite(stream)
            throw error
        }
    }

    private fun action(action: String, request: Int): PendingIntent = PendingIntent.getService(this,
        request, Intent(this, RecordingService::class.java).setAction(action),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    @Suppress("DEPRECATION")
    private fun notification(): Notification {
        val open = PendingIntent.getActivity(this, 900, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        return builder.setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle(if (phase == "paused") "Note Agent · 录音已暂停" else "Note Agent · 正在录音")
            .setContentText("原音频只保留本机；结束后保存。点此返回。")
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(Notification.Action.Builder(if (phase == "paused") android.R.drawable.ic_media_play else android.R.drawable.ic_media_pause,
                if (phase == "paused") "继续" else "暂停", action(TOGGLE, 901)).build())
            .addAction(Notification.Action.Builder(android.R.drawable.ic_menu_save, "结束并保存", action(STOP, 902)).build())
            .build()
    }

    private fun updateNotification() {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification())
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Normal removal from recents finalizes the original, never silently
        // continues a hidden microphone. Force-stop/SIGKILL cannot run callbacks.
        finish()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        finish("系统结束了录音服务，现有原文件已保留；请回放核对。")
        handler.removeCallbacksAndMessages(null)
        if (current === this) current = null
        super.onDestroy()
    }
}
