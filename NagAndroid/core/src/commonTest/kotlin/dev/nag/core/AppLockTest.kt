package dev.nag.core

import kotlin.test.Test
import kotlin.test.assertEquals

class AppLockTest {
    @Test
    fun recordsCandidatesBeforeSuspendingAndRetainsOnlyAppsItSuspended() {
        val events = mutableListOf<Set<String>>()
        val lock = AppLock(emptySet(), { events.add(it) }) { packages, suspended ->
            assertEquals(listOf(packages), events)
            assertEquals(true, suspended)
            setOf("rejected")
        }
        assertEquals(setOf("rejected"), lock.engage(setOf("allowed", "rejected")))
        assertEquals(listOf(setOf("allowed", "rejected"), setOf("allowed")), events)
    }

    @Test
    fun retainsFailedRestoresForRetry() {
        val events = mutableListOf<Set<String>>()
        val lock = AppLock(setOf("restored", "retry"), { events.add(it) }) { _, suspended ->
            assertEquals(false, suspended)
            setOf("retry")
        }
        assertEquals(setOf("retry"), lock.release())
        assertEquals(listOf(setOf("retry")), events)
    }
}
