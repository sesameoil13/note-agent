package dev.noteagent.note_agent

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaPlayer
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/** Android microphone permission, foreground recorder and private-file player.
 * No network, Keychain, broad storage access, or automatic permission settings.
 */
class NativeAudio(private val activity: MainActivity, messenger: BinaryMessenger) {
    companion object {
        private const val PERMISSION = 9009

        /** Bounded complete-container inspection, based on real audio tracks and
         * packet timestamps, never filename/MIME provided by a file picker. */
        fun inspect(file: File): Map<String, Any> {
            check(file.isFile && file.length() > 0) { "录音文件为空或缺失，原件未改动。" }
            val header = ByteArray(12)
            val read = file.inputStream().use { it.read(header) }
            val container = when {
                read >= 12 && String(header, 0, 4, Charsets.US_ASCII) == "RIFF" &&
                    String(header, 8, 4, Charsets.US_ASCII) == "WAVE" -> "WAV"
                read >= 8 && String(header, 4, 4, Charsets.US_ASCII) == "ftyp" -> "M4A"
                read >= 4 && (String(header, 0, 3, Charsets.US_ASCII) == "ID3" ||
                    (header[0].toInt() and 255 == 255 && header[1].toInt() and 224 == 224)) -> "MP3"
                else -> error("暂不支持此音频容器，原件已保留。")
            }
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(file.path)
                val index = (0 until extractor.trackCount).firstOrNull {
                    extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
                } ?: error("没有可回放的音频轨道，现有原件已保留。")
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: error("无法识别音频。")
                val codec = when (mime) {
                    "audio/mp4a-latm" -> "AAC"
                    "audio/mpeg" -> "MP3"
                    "audio/raw" -> "PCM"
                    else -> error("暂不支持此音频编码，原件已保留。")
                }
                check((container == "M4A" && codec == "AAC") ||
                    (container == "MP3" && codec == "MP3") || (container == "WAV" && codec == "PCM")) {
                    "音频容器与编码不受支持，原件已保留。"
                }
                val duration = format.getLong(MediaFormat.KEY_DURATION) / 1000
                val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                val channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                check(duration > 0 && sampleRate in 8000..192000 && channels in 1..8) {
                    "音频参数不完整，原件已保留。"
                }
                extractor.selectTrack(index)
                val buffer = ByteBuffer.allocate(1_048_576)
                var packets = 0
                var lastTime = -1L
                while (true) {
                    buffer.clear()
                    val bytes = extractor.readSampleData(buffer, 0)
                    if (bytes < 0) break
                    check(bytes > 0 && ++packets <= 1_000_000 && extractor.sampleTime >= lastTime) {
                        "音频数据不完整，原件已保留。"
                    }
                    lastTime = extractor.sampleTime
                    if (!extractor.advance()) break
                }
                check(packets > 0 && lastTime >= 0 && duration - lastTime / 1000 in -2000..2000) {
                    "音频长度与容器不符，原件已保留。"
                }
                return mapOf("container" to container,
                    "codec" to codec, "durationMs" to duration, "sampleRate" to sampleRate, "channels" to channels)
            } finally { extractor.release() }
        }
    }

    private val channel = MethodChannel(messenger, "dev.noteagent/audio")
    private val io = Executors.newSingleThreadExecutor()
    private var pending: Pair<String, MethodChannel.Result>? = null
    private var recordingPath: String? = null
    private var player: MediaPlayer? = null
    private var playbackPosition = 0
    private var closed = false

    init { channel.setMethodCallHandler(::handle) }

    private fun path(call: MethodCall): String = requireNotNull(call.argument<String>("path"))

    private fun privateFile(path: String): File {
        val file = File(path).canonicalFile
        val root = File(activity.filesDir, "workspace").canonicalFile
        require(file.path.startsWith(root.path + File.separator) && file.isFile) {
            "此音频不是已保留的本机原件。"
        }
        return file
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "startRecording" -> start(path(call), result)
                "recoverRecording" -> {
                    val path = RecordingService.source(activity, path(call)).path
                    val value = RecordingService.recovered(activity, path)
                    if (value != null) recordingPath = path
                    result.success(value)
                }
                "pauseRecording" -> { live().pause(); result.success(null) }
                "resumeRecording" -> { live().resume(); result.success(null) }
                "recordingSnapshot" -> result.success(snapshot())
                "stopRecording" -> {
                    val service = RecordingService.current
                    result.success(if (service != null && service.matches(recordingPath)) service.finish() else snapshot())
                }
                "inspectRecording", "inspectAudioSource" -> {
                    val source = privateFile(path(call))
                    io.execute {
                        try {
                            val metadata = inspect(source)
                            activity.runOnUiThread { if (!closed) result.success(if (call.method == "inspectRecording") metadata["durationMs"] else metadata) }
                        } catch (error: Exception) {
                            activity.runOnUiThread { if (!closed) result.error("audio_invalid", error.message ?: "无法检查原音频，原件已保留。", null) }
                        }
                    }
                }
                "play", "playAudioSource" -> {
                    check(RecordingService.current?.snapshot()?.get("phase") !in listOf("recording", "paused")) { "请先结束录音。" }
                    stopPlayer()
                    val native = MediaPlayer()
                    player = native
                    native.setDataSource(privateFile(path(call)).path)
                    native.setOnCompletionListener { playbackPosition = it.duration; stopPlayer(keepPosition = true) }
                    native.setOnErrorListener { _, _, _ -> stopPlayer(); true }
                    native.prepare()
                    native.start()
                    result.success(null)
                }
                "stopPlayback" -> { stopPlayer(); result.success(null) }
                "playbackSnapshot" -> result.success(mapOf("isPlaying" to (player?.isPlaying ?: false),
                    "positionMs" to (player?.currentPosition ?: playbackPosition)))
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("audio_operation", error.message ?: "音频操作未完成，现有原件已保留。", null)
        }
    }

    private fun live(): RecordingService = RecordingService.current?.takeIf { it.matches(recordingPath) }
        ?: error("录音服务已结束，请核对保留的原音频。")
    private fun snapshot(): Map<String, Any?> = recordingPath?.let { RecordingService.recovered(activity, it) }
        ?: error("录音已中断，现有原文件已保留；请重新打开后核对。")

    private fun start(path: String, result: MethodChannel.Result) {
        check(pending == null && RecordingService.current == null) { "请先结束当前录音或权限请求。" }
        val source = RecordingService.source(activity, path)
        require(!source.exists()) { "原音频已存在，未覆盖。" }
        stopPlayer()
        pending = source.path to result
        val needed = mutableListOf<String>()
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.POST_NOTIFICATIONS)
        try {
            if (needed.isEmpty()) launch() else activity.requestPermissions(needed.toTypedArray(), PERMISSION)
        } catch (error: Exception) {
            pending = null
            throw error
        }
    }

    fun onPermissionResult(requestCode: Int) {
        if (requestCode != PERMISSION || pending == null) return
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            pending?.second?.error("microphone_denied", "麦克风权限未开启。请在系统设置中允许“笔记工作区”使用麦克风后重试。未开始录音。", null)
            pending = null
        } else launch() // Notification denial must not deny the granted microphone.
    }

    private fun launch() {
        val request = pending ?: return
        try {
            val intent = Intent(activity, RecordingService::class.java).setAction(RecordingService.START)
                .putExtra("path", request.first).putExtra("result", object : ResultReceiver(Handler(Looper.getMainLooper())) {
                    override fun onReceiveResult(resultCode: Int, data: Bundle?) {
                        if (closed) return
                        pending = null
                        if (resultCode == 0) { recordingPath = request.first; request.second.success(null) }
                        else request.second.error("recording_start", data?.getString("error") ?: "未能开始录音，原件保留。", null)
                    }
                })
            if (Build.VERSION.SDK_INT >= 26) activity.startForegroundService(intent) else activity.startService(intent)
        } catch (_: Exception) {
            pending = null
            request.second.error("foreground_service", "系统未允许开始录音。请返回 App 前台后重试；未在后台启动麦克风。", null)
        }
    }

    private fun stopPlayer(keepPosition: Boolean = false) {
        player?.release(); player = null
        if (!keepPosition) playbackPosition = 0
    }

    fun close() {
        closed = true
        pending = null
        stopPlayer()
        channel.setMethodCallHandler(null)
        io.shutdown()
        // Capture belongs to RecordingService, not this Activity.
    }
}
