package dev.nag.android

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import dev.nag.core.Nag
import dev.nag.core.NagState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.datetime.TimeZone

internal class NagStore(private val context: Context) {
    val preferences = context.getSharedPreferences("nags", Context.MODE_PRIVATE)
    fun read() = preferences.getString("state", null)?.let(NagState::decode) ?: NagState()

    fun update(transform: (NagState) -> NagState): Boolean {
        val before = read()
        val after = transform(before)
        if (after == before) return false
        check(preferences.edit().putString("state", after.encode()).commit()) {
            "Could not save nags"
        }
        val notifications = context.getSystemService(NotificationManager::class.java)
        val previous = before.nags.associateBy { it.id }
        val retained = after.nags.map { it.id }.toSet()
        before.nags.filterNot { it.id in retained }.forEach { notifications.cancel(it.id, 1) }
        after.nags.filter { previous[it.id]?.revision != it.revision }.forEach {
            notifications.cancel(it.id, 1)
        }
        Reminders.schedule(context, after)
        return true
    }
}

internal object Reminders {
    const val FIRE = "dev.nag.android.FIRE"
    const val CHANNEL = "nag_reminders"

    fun schedule(context: Context, state: NagState = NagStore(context).read()) {
        val alarm = context.getSystemService(AlarmManager::class.java)
        val pending = PendingIntent.getBroadcast(context, 0,
            Intent(context, ReminderReceiver::class.java).setAction(FIRE),
            PendingIntent.FLAG_IMMUTABLE)
        val now = System.currentTimeMillis()
        val zone = TimeZone.currentSystemDefault()
        val next = state.nags.mapNotNull { it.reminder(now, state.quiet, zone) }.minOrNull()
        if (next == null || !canNotify(context)) {
            alarm.cancel(pending)
            return
        }
        val trigger = maxOf(next, now + 500)
        try {
            if (Build.VERSION.SDK_INT < 31 || alarm.canScheduleExactAlarms()) {
                alarm.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pending)
                return
            }
        } catch (_: SecurityException) {
            // Access can be revoked between the permission check and registration.
        }
        alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pending)
    }

    fun canNotify(context: Context): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(
            CHANNEL, "Nag reminders", NotificationManager.IMPORTANCE_HIGH))
        return manager.areNotificationsEnabled() &&
            manager.getNotificationChannel(CHANNEL).importance != NotificationManager.IMPORTANCE_NONE
    }

    fun show(context: Context, nag: Nag, now: Long) {
        if (!canNotify(context)) return
        val manager = context.getSystemService(NotificationManager::class.java)
        val open = PendingIntent.getActivity(context, 0,
            Intent(Intent.ACTION_VIEW, nagUri(nag.id), context, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_nag)
            .setContentTitle(nag.title)
            .setContentText(nag.notes.ifBlank { "Reminder due" })
            .setContentIntent(open)
            .setAutoCancel(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .addAction(0, "Done", action(context, nag, "done"))
        if (nag.canSnooze(now)) notification.addAction(0, "Snooze", action(context, nag, "snooze"))
        if (nag.canStart(now)) notification.addAction(0, "Start", action(context, nag, "start"))
        manager.notify(nag.id, 1, notification.build())
    }

    private fun action(context: Context, nag: Nag, command: String): PendingIntent {
        val uri = nagUri(nag.id).buildUpon().appendQueryParameter("revision", nag.revision.toString())
            .appendQueryParameter("alert", nag.lastAlert.toString()).build()
        return PendingIntent.getBroadcast(context, 0,
            Intent(context, ReminderReceiver::class.java).setAction(command).setData(uri),
            PendingIntent.FLAG_IMMUTABLE)
    }
}

internal fun nagUri(id: String): Uri = Uri.parse("nag://nag").buildUpon()
    .appendQueryParameter("id", id).build()

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val store = NagStore(context)
        val now = System.currentTimeMillis()
        val zone = TimeZone.currentSystemDefault()
        if (intent.action == Reminders.FIRE) {
            if (!Reminders.canNotify(context)) return
            val delivered = mutableListOf<Nag>()
            store.update { state ->
                state.copy(nags = state.nags.map { nag ->
                    if (nag.reminder(now, state.quiet, zone)?.let { it <= now } == true) {
                        nag.copy(lastAlert = now).also(delivered::add)
                    } else nag
                })
            }
            if (delivered.isEmpty()) Reminders.schedule(context)
            delivered.forEach { Reminders.show(context, it, now) }
            return
        }
        if (intent.action !in setOf("done", "start", "snooze")) {
            Reminders.schedule(context)
            return
        }
        val data = intent.data ?: return
        val changed = store.update { state ->
            state.copy(nags = state.nags.map { nag ->
                if (nag.id != data.getQueryParameter("id") ||
                    nag.revision.toString() != data.getQueryParameter("revision") ||
                    nag.lastAlert.toString() != data.getQueryParameter("alert")) nag
                else when (intent.action) {
                    "done" -> nag.complete(now, zone)
                    "start" -> nag.start(now)
                    else -> nag.snooze(now)
                }
            })
        }
        if (changed) {
            val pending = goAsync()
            CoroutineScope(Dispatchers.IO).launch {
                try {
                    refreshWidgets(context)
                } finally {
                    pending.finish()
                }
            }
        }
    }
}
