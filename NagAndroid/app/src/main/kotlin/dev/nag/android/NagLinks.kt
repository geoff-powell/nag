package dev.nag.android

import android.net.Uri
import dev.nag.core.Escalation
import dev.nag.core.Nag
import dev.nag.core.Repeat
import dev.nag.core.Schedule
import dev.nag.core.Slot
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import java.util.UUID

internal fun minuteOfDay(text: String): Int {
    val match = Regex("(\\d{1,2}):(\\d{2})|(\\d{2})(\\d{2})").matchEntire(text.trim())
    require(match != null) { "Enter a time as HH:mm" }
    val hour = (match.groups[1] ?: match.groups[3])!!.value.toInt()
    val minute = (match.groups[2] ?: match.groups[4])!!.value.toInt()
    require(hour in 0..23 && minute in 0..59) { "Enter a valid time" }
    return hour * 60 + minute
}

internal fun timeText(minute: Int) = LocalTime.of(minute / 60, minute % 60).toString()
internal fun localTime(time: Long) = Instant.ofEpochMilli(time).atZone(ZoneId.systemDefault())
    .toLocalDateTime().withSecond(0).withNano(0).toString().replace('T', ' ')

internal fun startTime(text: String, now: Long): Long {
    val zone = ZoneId.systemDefault()
    val current = Instant.ofEpochMilli(now).atZone(zone)
    val input = text.trim()
    runCatching { return Instant.parse(input).toEpochMilli() }
    runCatching { return java.time.OffsetDateTime.parse(input).toInstant().toEpochMilli() }
    runCatching { return LocalDateTime.parse(input.replace(' ', 'T')).atZone(zone).toInstant().toEpochMilli() }
    runCatching { return LocalDate.parse(input).atTime(9, 0).atZone(zone).toInstant().toEpochMilli() }
    val minute = minuteOfDay(input)
    val candidate = current.toLocalDate().atTime(minute / 60, minute % 60).atZone(zone)
    return (if (candidate.toInstant().toEpochMilli() > now - 60_000L) candidate else candidate.plusDays(1))
        .toInstant().toEpochMilli()
}

internal fun parseDays(raw: String): Set<Int> {
    val days = listOf("mon", "tue", "wed", "thu", "fri", "sat", "sun")
    return raw.split(',').flatMap { token ->
        when (val day = token.trim().lowercase()) {
            "daily", "everyday", "all" -> (1..7).toList()
            "weekdays" -> (1..5).toList()
            "weekends" -> listOf(6, 7)
            else -> listOf((days.indexOf(day.take(3)) + 1).also {
                require(it > 0) { "Unknown weekday: ${token.trim()}" }
            })
        }
    }.toSet()
}

internal fun number(raw: String, range: IntRange, label: String): Int {
    val value = raw.toIntOrNull()
    require(value != null && value in range) { "$label must be between ${range.first} and ${range.last}" }
    return value
}

internal fun nagFromLink(uri: Uri, now: Long, existing: List<Nag>): Nag {
    val values = uri.queryParameterNames.associate { it.lowercase() to uri.getQueryParameter(it)?.trim() }
    fun value(vararg names: String) = names.firstNotNullOfOrNull { values[it]?.takeIf(String::isNotBlank) }
    fun int(range: IntRange, vararg names: String) = value(*names)?.let { number(it, range, names.first()) }
    val title = value("title", "text", "name") ?: error("This Nag link needs a title")
    val previous = existing.firstOrNull {
        it.source != null && it.externalId != null && it.source == value("source") &&
            it.externalId == value("id", "externalid", "external_id")
    }
    val anchor = value("at", "start", "date")?.let { startTime(it, now) }
        ?: value("in")?.let { Math.addExact(now, delayMillis(it)) }
        ?: previous?.schedule?.anchor ?: now
    val times = value("times", "time")
    val days = value("days")
    val repeat = when (value("repeat")?.lowercase()) {
        null -> if (times != null || days != null) Repeat.Custom else previous?.schedule?.repeat ?: Repeat.Once
        "once", "never", "none" -> Repeat.Once
        "daily", "day", "everyday" -> Repeat.Daily
        "weekdays", "weekday" -> Repeat.Weekdays
        "weekly", "week" -> Repeat.Weekly
        "monthly", "month" -> Repeat.Monthly
        "every_days" -> Repeat.EveryDays
        "custom" -> Repeat.Custom
        else -> error("Unknown repeat rule")
    }
    val local = Instant.ofEpochMilli(anchor).atZone(ZoneId.systemDefault())
    val slots = if (times == null && days == null) previous?.schedule?.slots.orEmpty() else {
        val weekdays = days?.let(::parseDays) ?: (1..7).toSet()
        val minutes = times?.split(',')?.map(::minuteOfDay) ?: listOf(local.hour * 60 + local.minute)
        minutes.map { Slot(it, weekdays) }
    }
    require(repeat != Repeat.Custom || slots.isNotEmpty()) { "Custom repeats need at least one time" }
    val schedule = Schedule(anchor, repeat, int(1..3650, "every_days") ?: previous?.schedule?.intervalDays ?: 1,
        int(1..31, "month_day") ?: previous?.schedule?.monthDay ?: local.dayOfMonth, slots)
    val escalation = value("escalation")?.let { raw ->
        Escalation.entries.firstOrNull { it.name.equals(raw, ignoreCase = true) } ?: error("Unknown escalation")
    }
    val limit = value("snoozes")
    return (previous ?: Nag(UUID.randomUUID().toString(), title, schedule)).copy(
        title = title,
        notes = values["notes"] ?: previous?.notes.orEmpty(),
        schedule = schedule,
        interval = int(1..1440, "every", "interval") ?: previous?.interval ?: 15,
        escalation = escalation ?: previous?.escalation ?: Escalation.Steady,
        snoozeMinutes = int(1..1440, "snooze") ?: previous?.snoozeMinutes ?: 10,
        snoozeLimit = when (limit?.lowercase()) {
            null -> previous?.snoozeLimit
            "unlimited", "none", "any" -> null
            else -> number(limit, 0..1000, "Snooze limit")
        },
        source = value("source"),
        externalId = value("id", "externalid", "external_id"),
        link = value("link", "url")?.also { require(Uri.parse(it).scheme != null) } ?: previous?.link,
    )
}

private fun delayMillis(raw: String): Long {
    val input = raw.lowercase().filterNot(Char::isWhitespace)
    input.toLongOrNull()?.let {
        require(it >= 0) { "Delay must be positive" }
        return Math.multiplyExact(it, 60_000)
    }
    val pattern = Regex("(\\d+)([smhd])")
    val parts = pattern.findAll(input).toList()
    require(parts.isNotEmpty() && parts.joinToString("") { it.value } == input) { "Invalid reminder delay" }
    return parts.fold(0L) { total, part ->
        val factor = when (part.groupValues[2]) {
            "d" -> 86_400_000L
            "h" -> 3_600_000L
            "m" -> 60_000L
            else -> 1_000L
        }
        Math.addExact(total, Math.multiplyExact(part.groupValues[1].toLong(), factor))
    }
}
