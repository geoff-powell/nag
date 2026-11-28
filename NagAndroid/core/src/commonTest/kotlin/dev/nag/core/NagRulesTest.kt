package dev.nag.core

import kotlinx.datetime.TimeZone
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.time.Instant

class NagRulesTest {
    private val utc = TimeZone.UTC
    private fun at(text: String) = Instant.parse(text).toEpochMilliseconds()

    @Test
    fun completesOneOffAndSkipsMissedRepeats() {
        val due = at("2026-01-31T09:00:00Z")
        val now = at("2026-03-01T10:00:00Z")
        val nag = Nag("1", "Reminder", Schedule(due))
        assertNull(nag.complete(now, utc).reminder(now, null, utc))

        val monthly = nag.copy(schedule = Schedule(due, Repeat.Monthly, monthDay = 31))
        assertEquals(at("2026-02-28T09:00:00Z"), monthly.complete(due, utc).due)
        assertEquals(at("2026-03-31T09:00:00Z"), monthly.complete(now, utc).due)
    }

    @Test
    fun retainsLocalTimeAcrossDaylightSaving() {
        val zone = TimeZone.of("America/New_York")
        val before = at("2026-03-07T14:00:00Z")
        assertEquals(at("2026-03-08T13:00:00Z"), Schedule(before, Repeat.Daily).next(before, zone))
    }

    @Test
    fun overnightQuietHoursDeferTheAlarm() {
        val due = at("2026-01-30T23:00:00Z")
        val quiet = QuietHours(22 * 60, 7 * 60)
        val nag = Nag("1", "Reminder", Schedule(due))
        val end = at("2026-01-31T07:00:00Z")
        assertEquals(end, nag.reminder(due, quiet, utc))
        assertEquals(end, nag.reminder(end - 1, quiet, utc))
        assertEquals(end, nag.reminder(end, quiet, utc))
    }

    @Test
    fun snoozeAndStartDeferAndCompletionResetsProgress() {
        val due = at("2026-01-31T09:00:00Z")
        val nag = Nag("1", "Reminder", Schedule(due, Repeat.Daily), snoozeLimit = 1)
        val snoozed = nag.snooze(due)
        assertFalse(snoozed.canSnooze(due))
        assertEquals(due + 10 * 60_000L, snoozed.reminder(due, null, utc))
        val started = snoozed.start(due)
        assertEquals(due + 25 * 60_000L, started.reminder(due, null, utc))
        val completed = started.complete(due, utc)
        assertEquals(0, completed.snoozes)
        assertNull(completed.started)
        assertNull(completed.snoozed)
        assertEquals(NagState(listOf(completed)), NagState.decode(NagState(listOf(completed)).encode()))
    }

    @Test
    fun escalationUsesOverdueTimeAndMinimumInterval() {
        val due = at("2026-01-31T09:00:00Z")
        val now = due + 2 * 3_600_000L
        val nag = Nag("1", "Reminder", Schedule(due), interval = 20, lastAlert = now)
        assertEquals(now + 20 * 60_000L, nag.reminder(now, null, utc))
        assertEquals(now + 675_000L, nag.copy(escalation = Escalation.Gentle).reminder(now, null, utc))
        assertEquals(now + 75_000L, nag.copy(escalation = Escalation.Relentless).reminder(now, null, utc))
    }
    @Test
    fun groupsFollowAppleOccurrenceStatus() {
        val now = at("2026-01-31T09:00:00Z")
        val due = Nag("1", "Due", Schedule(now))
        val repeating = Nag("2", "Repeating", Schedule(now, Repeat.Daily)).complete(now, utc)
        val later = Nag("3", "Later", Schedule(now + 60_000))
        val archived = due.copy(id = "4", archived = true)
        val groups = NagState(listOf(later, archived, repeating, due.snooze(now))).groups(now, utc)
        assertEquals(listOf("1"), groups.now.map { it.id })
        assertEquals(listOf("3"), groups.later.map { it.id })
        assertEquals(listOf("2"), groups.done.map { it.id })
        assertEquals(listOf("4"), groups.archived.map { it.id })
        assertNull(archived.reminder(now, null, utc))
    }
}
