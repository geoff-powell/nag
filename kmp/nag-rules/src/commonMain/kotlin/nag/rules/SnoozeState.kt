package nag.rules

/**
 * The fields of a nag that snoozing reads and changes. Ported from Swift NagCore (`TaskRules.swift`).
 * Instants are Unix epoch milliseconds so they cross Swift, C and JSON without a date type.
 * Only one-off nags are modelled here; recurrence is out of scope for the first slice.
 *
 * @property maxSnoozes null allows unlimited snoozes.
 */
data class SnoozeState(
    val startAtMillis: Long,
    val completed: Boolean,
    val snoozeMinutes: Int,
    val maxSnoozes: Int?,
    val snoozeCount: Int,
    val snoozedUntilMillis: Long?,
) {
    /** The occurrence has started and isn't done. Snoozed nags are still outstanding. */
    fun isOutstanding(nowMillis: Long): Boolean = !completed && startAtMillis <= nowMillis

    fun isSnoozed(nowMillis: Long): Boolean =
        isOutstanding(nowMillis) && (snoozedUntilMillis ?: Long.MIN_VALUE) > nowMillis

    /** Snoozes left, or null when unlimited. */
    val snoozesLeft: Int? get() = maxSnoozes?.let { maxOf(0, it - snoozeCount) }

    /** Snoozing an active snooze is allowed and replaces it, as in Swift. */
    fun canSnooze(nowMillis: Long): Boolean = isOutstanding(nowMillis) && (snoozesLeft ?: 1) > 0

    /** The state after snoozing for [snoozeMinutes], or null when snoozing is refused. */
    fun snoozed(nowMillis: Long): SnoozeState? {
        if (!canSnooze(nowMillis)) return null
        return copy(
            snoozedUntilMillis = nowMillis + snoozeMinutes * 60_000L,
            snoozeCount = snoozeCount + 1,
        )
    }

    /** Completing a one-off finishes it and resets the snooze for the occurrence. */
    fun complete(): SnoozeState = copy(completed = true, snoozeCount = 0, snoozedUntilMillis = null)
}
