package dev.nag.core

import kotlinx.datetime.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.math.pow
import kotlin.time.Instant

@Serializable
enum class Repeat { Once, Daily, Weekdays, Weekly, Custom, EveryDays, Monthly }

@Serializable
enum class Escalation { Steady, Gentle, Relentless }

@Serializable
data class Slot(val minute: Int, val days: Set<Int> = (1..7).toSet())

@Serializable
data class Schedule(
    val anchor: Long,
    val repeat: Repeat = Repeat.Once,
    val intervalDays: Int = 1,
    val monthDay: Int = 1,
    val slots: List<Slot> = emptyList(),
) {
    fun next(after: Long, zone: TimeZone): Long? {
        if (repeat == Repeat.Once) return null
        val start = Instant.fromEpochMilliseconds(anchor).toLocalDateTime(zone)
        val current = Instant.fromEpochMilliseconds(after).toLocalDateTime(zone)
        fun at(day: LocalDate, minute: Int) = day.atTime(minute / 60, minute % 60)
            .toInstant(zone).toEpochMilliseconds()
        val minute = start.hour * 60 + start.minute
        return when (repeat) {
            Repeat.EveryDays -> {
                val elapsed = start.date.daysUntil(current.date).coerceAtLeast(0)
                val offset = elapsed / intervalDays * intervalDays
                val day = start.date.plus(offset, DateTimeUnit.DAY)
                at(day, minute).takeIf { it > after }
                    ?: at(day.plus(intervalDays, DateTimeUnit.DAY), minute)
            }
            Repeat.Monthly -> {
                val month = LocalDate(current.year, current.month, 1)
                (0..1).firstNotNullOfOrNull { offset ->
                    val first = month.plus(offset, DateTimeUnit.MONTH)
                    val next = first.plus(1, DateTimeUnit.MONTH)
                    val day = minOf(monthDay, first.daysUntil(next))
                    at(first.plus(day - 1, DateTimeUnit.DAY), minute).takeIf { it > after }
                }
            }
            else -> (0..7).firstNotNullOfOrNull { offset ->
                val day = current.date.plus(offset, DateTimeUnit.DAY)
                val weekday = day.dayOfWeek.isoDayNumber
                val candidates = when (repeat) {
                    Repeat.Custom -> slots.filter { weekday in it.days }.map { it.minute }
                    Repeat.Weekdays -> listOf(minute).filter { weekday <= 5 }
                    Repeat.Weekly -> listOf(minute).filter { day.dayOfWeek == start.dayOfWeek }
                    else -> listOf(minute)
                }
                candidates.map { at(day, it) }.filter { it > after }.minOrNull()
            }
        }
    }
}

@Serializable
data class QuietHours(val start: Int, val end: Int) {
    fun defer(time: Long, zone: TimeZone): Long {
        if (start == end) return time
        val today = Instant.fromEpochMilliseconds(time).toLocalDateTime(zone).date
        fun at(day: LocalDate, minute: Int) = day.atTime(minute / 60, minute % 60)
            .toInstant(zone).toEpochMilliseconds()
        val starts = if (start > end) listOf(today, today.minus(1, DateTimeUnit.DAY)) else listOf(today)
        return starts.firstNotNullOfOrNull { day ->
            val endDay = if (start > end) day.plus(1, DateTimeUnit.DAY) else day
            val endAt = at(endDay, end)
            endAt.takeIf { time >= at(day, start) && time < endAt }
        } ?: time
    }
}

@Serializable
data class Nag(
    val id: String,
    val title: String,
    val schedule: Schedule,
    val due: Long = schedule.anchor,
    val notes: String = "",
    val interval: Int = 15,
    val escalation: Escalation = Escalation.Steady,
    val snoozeMinutes: Int = 10,
    val snoozeLimit: Int? = null,
    val workMinutes: Int = 25,
    val source: String? = null,
    val externalId: String? = null,
    val link: String? = null,
    val completed: Boolean = false,
    val started: Long? = null,
    val snoozed: Long? = null,
    val snoozes: Int = 0,
    val lastAlert: Long? = null,
    val revision: Long = 0,
    val archived: Boolean = false,
    val lastCompleted: Long? = null,
) {
    fun canStart(now: Long) = !archived && !completed && due <= now && started == null
    fun canSnooze(now: Long) = !archived && !completed && due <= now && (snoozeLimit == null || snoozes < snoozeLimit)

    fun canComplete(now: Long, zone: TimeZone): Boolean {
        val tomorrow = Instant.fromEpochMilliseconds(now).toLocalDateTime(zone).date
            .plus(1, DateTimeUnit.DAY).atStartOfDayIn(zone).toEpochMilliseconds()
        return !archived && !completed && (schedule.repeat == Repeat.Once || due < tomorrow)
    }

    fun complete(now: Long, zone: TimeZone): Nag {
        if (!canComplete(now, zone)) return this
        val next = schedule.next(maxOf(now, due), zone)
        return copy(due = next ?: due, completed = next == null, lastCompleted = now, started = null, snoozed = null,
            snoozes = 0, lastAlert = null, revision = revision + 1)
    }

    fun start(now: Long) = if (canStart(now)) copy(started = now, lastAlert = null,
        revision = revision + 1) else this

    fun snooze(now: Long, minutes: Int = snoozeMinutes) = if (canSnooze(now)) copy(snoozed = now + minutes * 60_000L,
        snoozes = snoozes + 1, lastAlert = null, revision = revision + 1) else this

    fun reopen() = if (completed && !archived) copy(completed = false, lastCompleted = null,
        lastAlert = null, revision = revision + 1) else this

    fun archive(value: Boolean) = copy(archived = value, lastAlert = null, revision = revision + 1)

    fun reminder(now: Long, quiet: QuietHours?, zone: TimeZone): Long? {
        if (completed || archived) return null
        val workEnd = started?.plus(workMinutes * 60_000L) ?: due
        val nagStart = maxOf(due, snoozed ?: due, workEnd)
        val base = interval * 60_000L
        val overdue = ((lastAlert ?: nagStart) - nagStart).coerceAtLeast(0)
        val delay = when (escalation) {
            Escalation.Steady -> base
            Escalation.Gentle -> maxOf(60_000L, base / 2, (base * 0.75.pow((overdue / 3_600_000L).toDouble())).toLong())
            Escalation.Relentless -> maxOf(60_000L, (base * 0.5.pow((overdue / 1_800_000L).toDouble())).toLong())
        }
        val next = maxOf(nagStart, lastAlert?.plus(delay) ?: nagStart)
        val candidate = maxOf(next, now)
        return quiet?.defer(candidate, zone) ?: candidate
    }
}

@Serializable
data class NagState(val nags: List<Nag> = emptyList(), val quiet: QuietHours? = null) {
    fun groups(now: Long, zone: TimeZone): NagGroups {
        fun date(time: Long) = Instant.fromEpochMilliseconds(time).toLocalDateTime(zone).date
        val today = date(now)
        val open = nags.filterNot { it.archived }
        val (due, future) = open.partition { !it.completed && it.due <= now }
        val (done, later) = future.partition { it.completed || it.lastCompleted?.let(::date) == today }
        return NagGroups(due.sortedBy { it.due }, later.sortedBy { it.due },
            done.sortedByDescending { it.lastCompleted }, nags.filter { it.archived })
    }

    fun save(nag: Nag, now: Long, zone: TimeZone): NagState {
        val previous = nags.firstOrNull { it.id == nag.id }
        val basis = if (previous == null || previous.schedule != nag.schedule) {
            val due = if (nag.schedule.repeat == Repeat.Custom) {
                nag.schedule.next(now, zone) ?: nag.schedule.anchor
            } else nag.schedule.anchor
            nag.copy(due = due, completed = false, started = null, snoozed = null,
                snoozes = 0, lastAlert = null)
        } else {
            nag.copy(due = previous.due, completed = previous.completed, started = previous.started,
                snoozed = previous.snoozed, snoozes = previous.snoozes, lastAlert = previous.lastAlert)
        }
        val saved = basis.copy(revision = (previous?.revision ?: 0L) + 1,
            archived = previous?.archived ?: false, lastCompleted = previous?.lastCompleted)
        return copy(nags = if (previous == null) nags + saved else nags.map {
            if (it.id == nag.id) saved else it
        })
    }

    fun encode(): String = Json.encodeToString(this)

    companion object {
        fun decode(text: String): NagState = Json.decodeFromString(text)
    }
}
data class NagGroups(val now: List<Nag>, val later: List<Nag>, val done: List<Nag>, val archived: List<Nag>)
