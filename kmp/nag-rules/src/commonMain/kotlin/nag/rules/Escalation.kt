package nag.rules

import kotlin.math.floor
import kotlin.math.max
import kotlin.math.pow

/**
 * How the nag interval tightens the longer a nag stays undone. Ported from Swift NagCore
 * (`NagPlanner.swift`), which is the reference. Durations are seconds, matching Swift's
 * `TimeInterval` so the Swift and C bridges need no unit conversion.
 */
enum class Escalation(
    private val stepSeconds: Double?,
    private val factor: Double,
) {
    Steady(stepSeconds = null, factor = 1.0),
    Gentle(stepSeconds = 3600.0, factor = 0.75),
    Relentless(stepSeconds = 1800.0, factor = 0.5),
    ;

    private fun floorFor(baseSeconds: Double): Double = when (this) {
        Steady -> baseSeconds
        Gentle -> baseSeconds / 2
        Relentless -> MIN_INTERVAL_SECONDS
    }

    /** Seconds between nags once a nag has been overdue for [overdueSeconds]. Never under a minute. */
    fun interval(baseSeconds: Double, overdueSeconds: Double): Double {
        val base = max(MIN_INTERVAL_SECONDS, baseSeconds)
        val step = stepSeconds ?: return base
        val steps = floor(max(0.0, overdueSeconds) / step)
        return maxOf(MIN_INTERVAL_SECONDS, floorFor(base), base * factor.pow(steps))
    }

    /** The overdue duration at which the interval next tightens, or null once it no longer will. */
    fun nextTightening(baseSeconds: Double, overdueSeconds: Double): Double? {
        val step = stepSeconds ?: return null
        val boundary = (floor(max(0.0, overdueSeconds) / step) + 1) * step
        return boundary.takeIf { interval(baseSeconds, it) < interval(baseSeconds, overdueSeconds) }
    }

    companion object {
        const val MIN_INTERVAL_SECONDS: Double = 60.0

        /** Parses the lowercase names used by Swift's `Escalation` raw values and the fixtures. */
        fun parse(name: String): Escalation =
            entries.firstOrNull { it.name.equals(name, ignoreCase = true) }
                ?: throw IllegalArgumentException("Unknown escalation '$name'")
    }
}
