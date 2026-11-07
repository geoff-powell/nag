package nag.rules

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RulesTest {
    private val now = 1_793_178_000_000L
    private val due = SnoozeState(
        startAtMillis = now - 3_600_000,
        completed = false,
        snoozeMinutes = 10,
        maxSnoozes = 1,
        snoozeCount = 0,
        snoozedUntilMillis = null,
    )

    @Test
    fun snoozingUsesUpTheAllowance() {
        val snoozed = due.snoozed(now)!!
        assertEquals(now + 600_000, snoozed.snoozedUntilMillis)
        assertTrue(snoozed.isSnoozed(now))
        assertTrue(snoozed.isOutstanding(now))
        assertEquals(0, snoozed.snoozesLeft)
        assertNull(snoozed.snoozed(now + 1))
    }

    @Test
    fun completionResetsSnooze() {
        val done = due.snoozed(now)!!.complete()
        assertFalse(done.isOutstanding(now))
        assertEquals(0, done.snoozeCount)
        assertNull(done.snoozedUntilMillis)
    }

    @Test
    fun bridgeReportsErrorsInsteadOfThrowing() {
        assertTrue(RulesBridge.evaluate("not json").startsWith("{\"ok\":false"))
        assertTrue(RulesBridge.evaluate("""{"op":"nope"}""").contains("Unknown op"))
        assertTrue(RulesBridge.evaluate("""{"op":"escalation","mode":"wild","baseSeconds":1,"overdueSeconds":0}""").contains("\"ok\":false"))
    }

    @Test
    fun escalationNamesMatchSwiftRawValues() {
        assertEquals(Escalation.Relentless, Escalation.parse("relentless"))
    }
}
