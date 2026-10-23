package dev.noteagent.note_agent

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * Durable local reminder state shared by the Flutter channel and the receivers
 * that run without the Flutter engine (alarm, action button, boot). Alarms are
 * owned here so they can be re-armed after reboot or a force stop; a
 * successful schedule is OS acceptance only, never proof of delivery.
 */
object ReminderStore {
    private const val PREFS = "note_agent_notifications"
    private const val REQUESTS = "requests.v1"
    private const val ACCEPTED = "accepted.v1"
    private const val DELIVERED = "delivered.v1"
    private const val INTERACTIONS = "interactions.v1"
    private const val ASKED = "permissionAsked.v1"
    const val CHANNEL_ID = "note_agent_reminders"
    const val EXTRA_ID = "dev.noteagent.notificationId"
    const val EXTRA_ACTION = "dev.noteagent.notificationAction"
    const val ACTION_FIRE = "dev.noteagent.reminder.FIRE"
    const val ACTION_RESPOND = "dev.noteagent.reminder.RESPOND"

    /** Set while the Flutter engine is attached; responses are durable anyway. */
    @Volatile var onInteraction: (() -> Unit)? = null

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun obj(context: Context, key: String) = JSONObject(prefs(context).getString(key, "{}")!!)
    private fun list(context: Context, key: String) = JSONArray(prefs(context).getString(key, "[]")!!)
    private fun set(context: Context, key: String): MutableSet<String> =
        prefs(context).getStringSet(key, emptySet())!!.toMutableSet()

    @Synchronized fun requests(context: Context): JSONObject = obj(context, REQUESTS)
    @Synchronized fun accepted(context: Context): Set<String> = set(context, ACCEPTED)
    @Synchronized fun delivered(context: Context): Set<String> = set(context, DELIVERED)
    @Synchronized fun permissionAsked(context: Context) = prefs(context).getBoolean(ASKED, false)
    @Synchronized fun markPermissionAsked(context: Context) { prefs(context).edit().putBoolean(ASKED, true).commit() }

    private fun commit(context: Context, edit: (android.content.SharedPreferences.Editor) -> Unit) {
        val editor = prefs(context).edit()
        edit(editor)
        check(editor.commit()) { "无法保存提醒状态。" }
    }

    fun channel(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "待办提醒", NotificationManager.IMPORTANCE_HIGH)
                .apply { description = "已确认待办的本机提醒" }
        )
    }

    fun notificationsAllowed(context: Context): Boolean {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(
                context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = context.getSystemService(NotificationManager::class.java).getNotificationChannel(CHANNEL_ID)
            if (channel != null && channel.importance == NotificationManager.IMPORTANCE_NONE) return false
        }
        return true
    }

    fun permission(context: Context): String = when {
        notificationsAllowed(context) -> "allowed"
        Build.VERSION.SDK_INT >= 33 && !permissionAsked(context) -> "notDetermined"
        else -> "denied"
    }

    fun exactTiming(context: Context): Boolean =
        Build.VERSION.SDK_INT < 31 || context.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()

    private fun alarmIntent(context: Context, id: String, flags: Int): PendingIntent? =
        PendingIntent.getBroadcast(
            context, id.hashCode(),
            Intent(context, ReminderReceiver::class.java).setAction(ACTION_FIRE).setData(Uri.parse("noteagent://alarm/" + Uri.encode(id)))
                .putExtra(EXTRA_ID, id),
            flags or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun arm(context: Context, id: String, timeMs: Long) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        val intent = alarmIntent(context, id, PendingIntent.FLAG_UPDATE_CURRENT)!!
        // Without exact-alarm access the OS may defer; the App reports that.
        if (exactTiming(context)) alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, timeMs, intent)
        else alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, timeMs, intent)
    }

    @Synchronized fun schedule(context: Context, id: String, request: JSONObject) {
        val requests = requests(context).put(id, request)
        val accepted = accepted(context).toMutableSet().apply { add(id) }
        val delivered = delivered(context).toMutableSet().apply { remove(id) }
        commit(context) {
            it.putString(REQUESTS, requests.toString()).putStringSet(ACCEPTED, accepted).putStringSet(DELIVERED, delivered)
        }
        val time = request.getLong("timeMs")
        if (request.optBoolean("immediate") || time <= System.currentTimeMillis()) deliver(context, id)
        else arm(context, id, time)
    }

    @Synchronized fun cancel(context: Context, id: String) {
        alarmIntent(context, id, PendingIntent.FLAG_NO_CREATE)?.let {
            context.getSystemService(AlarmManager::class.java).cancel(it); it.cancel()
        }
        NotificationManagerCompat.from(context).cancel(id, 0)
        val requests = requests(context).apply { remove(id) }
        commit(context) {
            it.putString(REQUESTS, requests.toString())
                .putStringSet(ACCEPTED, accepted(context) - id)
                .putStringSet(DELIVERED, delivered(context) - id)
        }
    }

    /**
     * Re-arms stored alarms the OS dropped (reboot clears all alarms; a force
     * stop clears them and their PendingIntents). Overdue ones are shown now,
     * late, rather than reported as delivered on time.
     */
    @Synchronized fun restore(context: Context) {
        if (!notificationsAllowed(context)) return
        val requests = requests(context)
        val delivered = delivered(context)
        for (id in requests.keys().asSequence().toList()) {
            if (id in delivered || alarmIntent(context, id, PendingIntent.FLAG_NO_CREATE) != null) continue
            val time = requests.getJSONObject(id).getLong("timeMs")
            if (time <= System.currentTimeMillis()) deliver(context, id) else arm(context, id, time)
        }
    }

    /** Re-arms everything, e.g. when exact-alarm access was granted. */
    @Synchronized fun rearmAll(context: Context) {
        if (!notificationsAllowed(context)) return
        val requests = requests(context)
        val delivered = delivered(context)
        for (id in requests.keys().asSequence().toList()) {
            if (id in delivered) continue
            val time = requests.getJSONObject(id).getLong("timeMs")
            if (time <= System.currentTimeMillis()) deliver(context, id) else arm(context, id, time)
        }
    }

    @Synchronized fun deliver(context: Context, id: String) {
        val request = requests(context).optJSONObject(id) ?: return
        val payload = request.getJSONObject("payload")
        channel(context)
        val open = PendingIntent.getActivity(
            context, id.hashCode(),
            Intent(context, MainActivity::class.java).setAction(ACTION_RESPOND)
                .setData(Uri.parse("noteagent://open/" + Uri.encode(id)))
                .putExtra(EXTRA_ID, id).putExtra(EXTRA_ACTION, "default")
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(request.getString("title"))
            .setContentText(request.getString("body"))
            .setStyle(NotificationCompat.BigTextStyle().bigText(request.getString("body")))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setContentIntent(open)
            .setAutoCancel(true)
        if (payload.optString("kind") == "actionReminder") {
            for ((action, title) in listOf("complete" to "完成", "snooze" to "稍后提醒")) {
                builder.addAction(0, title, PendingIntent.getBroadcast(
                    context, (id + action).hashCode(),
                    Intent(context, ReminderReceiver::class.java).setAction(ACTION_RESPOND)
                        .setData(Uri.parse("noteagent://$action/" + Uri.encode(id)))
                        .putExtra(EXTRA_ID, id).putExtra(EXTRA_ACTION, action),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ))
            }
        }
        val delivered = delivered(context).toMutableSet().apply { add(id) }
        commit(context) { it.putStringSet(DELIVERED, delivered) }
        try {
            NotificationManagerCompat.from(context).notify(id, 0, builder.build())
        } catch (_: SecurityException) {
            /* Permission revoked after scheduling; the App reports the status. */
        }
    }

    /**
     * Records a response durably before anything else, so Complete / Snooze
     * survive the App not running. Snooze also re-arms the same alert natively
     * for the configured length; the workspace adopts that time later.
     */
    @Synchronized fun respond(context: Context, id: String, action: String) {
        val request = requests(context).optJSONObject(id) ?: return
        val payload = JSONObject(request.getJSONObject("payload").toString())
        var snoozedUntil: Long? = null
        if (action == "snooze") {
            val minutes = payload.optString("snoozeMinutes").toIntOrNull()?.takeIf { it in 1..1440 } ?: 30
            snoozedUntil = System.currentTimeMillis() + minutes * 60_000L
            payload.put("snoozedUntilMs", snoozedUntil.toString())
        }
        val interactions = list(context, INTERACTIONS)
            .put(JSONObject().put("id", id).put("actionIdentifier", action).put("payload", payload))
        val requests = requests(context)
        if (snoozedUntil != null) requests.put(id, request.put("timeMs", snoozedUntil).put("immediate", false))
        commit(context) {
            it.putString(INTERACTIONS, interactions.toString()).putString(REQUESTS, requests.toString())
                .putStringSet(DELIVERED, if (snoozedUntil != null) delivered(context) - id else delivered(context))
        }
        if (action != "default") NotificationManagerCompat.from(context).cancel(id, 0)
        if (snoozedUntil != null) arm(context, id, snoozedUntil)
        onInteraction?.let { signal -> Handler(Looper.getMainLooper()).post { signal() } }
    }

    @Synchronized fun take(context: Context, kind: String, vault: String?): List<Map<String, Any>> {
        val all = list(context, INTERACTIONS)
        val keep = JSONArray()
        val taken = mutableListOf<Map<String, Any>>()
        for (i in 0 until all.length()) {
            val item = all.getJSONObject(i)
            val payload = item.getJSONObject("payload")
            if (payload.optString("kind") == kind && (vault == null || payload.optString("vault") == vault)) {
                taken.add(mapOf(
                    "id" to item.getString("id"),
                    "actionIdentifier" to item.getString("actionIdentifier"),
                    "payload" to payload.keys().asSequence().associateWith { payload.getString(it) },
                ))
            } else keep.put(item)
        }
        commit(context) { it.putString(INTERACTIONS, keep.toString()) }
        return taken
    }
}

/** Alarm delivery and action buttons; not exported, runs without Flutter. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(ReminderStore.EXTRA_ID) ?: return
        when (intent.action) {
            ReminderStore.ACTION_FIRE -> ReminderStore.deliver(context, id)
            ReminderStore.ACTION_RESPOND -> when (val action = intent.getStringExtra(ReminderStore.EXTRA_ACTION)) {
                "complete", "snooze" -> ReminderStore.respond(context, id, action)
            }
        }
    }
}

/** System broadcasts only: reboot, App update and exact-alarm access changes. */
class ReminderBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> ReminderStore.restore(context)
            AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED -> ReminderStore.rearmAll(context)
        }
    }
}

/** `dev.noteagent/notifications` on Android; same contract as macOS. */
class NativeNotifications(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "dev.noteagent/notifications")
    private var pendingPermission: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())
    private val network = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            main.post { channel.invokeMethod("networkAvailable", null) }
        }
    }

    init {
        ReminderStore.channel(activity)
        ReminderStore.onInteraction = { channel.invokeMethod("interactionAvailable", null) }
        channel.setMethodCallHandler { call, result -> handle(call, result) }
        try {
            activity.getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(network)
        } catch (_: Exception) { /* Resume still re-checks reminders. */ }
    }

    fun close() {
        ReminderStore.onInteraction = null
        try { activity.getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(network) } catch (_: Exception) {}
    }

    /** A tap on the alert body opens the App; it is recorded like any response. */
    fun onIntent(intent: Intent?) {
        if (intent?.action != ReminderStore.ACTION_RESPOND) return
        val id = intent.getStringExtra(ReminderStore.EXTRA_ID) ?: return
        // The Activity is exported; it may only record navigation, never a
        // completion or snooze.
        ReminderStore.respond(activity, id, "default")
        intent.action = null
    }

    fun onPermissionResult(requestCode: Int) {
        if (requestCode != PERMISSION_REQUEST) return
        pendingPermission?.success(ReminderStore.permission(activity))
        pendingPermission = null
        ReminderStore.rearmAll(activity)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "inspect" -> {
                    ReminderStore.restore(activity)
                    val delivered = ReminderStore.delivered(activity).toMutableSet()
                    result.success(mapOf(
                        "permission" to ReminderStore.permission(activity),
                        "pending" to ReminderStore.requests(activity).keys().asSequence()
                            .filter { it !in delivered }.toList(),
                        "accepted" to ReminderStore.accepted(activity).toList(),
                        "delivered" to delivered.toList(),
                        "exactTiming" to ReminderStore.exactTiming(activity),
                    ))
                }
                "requestPermission" -> requestPermission(result)
                "takeInteractions" -> {
                    val kind = call.argument<String>("kind")
                    if (kind == null) { result.error("notification_arguments", "通知类型无效。", null); return }
                    result.success(ReminderStore.take(activity, kind, call.argument<String>("vault")))
                }
                "schedule" -> {
                    val id = call.argument<String>("id")
                    val title = call.argument<String>("title")
                    val body = call.argument<String>("body")
                    val time = call.argument<Number>("timeMs")
                    val payload = call.argument<Map<String, String>>("payload")
                    if (id == null || !id.startsWith("note-agent:") || title == null || body == null || time == null || payload == null) {
                        result.error("notification_arguments", "提醒计划无效。", null); return
                    }
                    if (!ReminderStore.notificationsAllowed(activity)) {
                        result.error("notification_denied", "系统通知未允许，计划仍保留在 App。", null); return
                    }
                    ReminderStore.schedule(activity, id, JSONObject()
                        .put("title", title).put("body", body).put("timeMs", time.toLong())
                        .put("immediate", call.argument<Boolean>("immediate") == true)
                        .put("payload", JSONObject(payload)))
                    result.success(null)
                }
                "cancel" -> {
                    val id = call.argument<String>("id")
                    if (id == null || !id.startsWith("note-agent:")) {
                        result.error("notification_arguments", "提醒标识无效。", null); return
                    }
                    ReminderStore.cancel(activity, id)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("notification_schedule", error.message ?: "系统通知操作失败。", null)
        }
    }

    /** Only reached from the explicit App button, never while reconciling. */
    private fun requestPermission(result: MethodChannel.Result) {
        when {
            Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(
                activity, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
                (!ReminderStore.permissionAsked(activity) ||
                    activity.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)) -> {
                if (pendingPermission != null) { result.error("notification_permission", "权限请求已在进行。", null); return }
                ReminderStore.markPermissionAsked(activity)
                pendingPermission = result
                activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST)
            }
            !ReminderStore.notificationsAllowed(activity) -> {
                // The system no longer shows a prompt; open the App's page.
                openSettings(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName))
                result.success(ReminderStore.permission(activity))
            }
            !ReminderStore.exactTiming(activity) && Build.VERSION.SDK_INT >= 31 -> {
                openSettings(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:" + activity.packageName)))
                result.success(ReminderStore.permission(activity))
            }
            else -> result.success(ReminderStore.permission(activity))
        }
    }

    private fun openSettings(intent: Intent) {
        try { activity.startActivity(intent) } catch (_: Exception) {
            activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + activity.packageName)))
        }
    }

    companion object { const val PERMISSION_REQUEST = 3101 }
}
