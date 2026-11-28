package dev.nag.core

/** Keeps a durable restoration list even if the process dies during a policy call. */
class AppLock(
    private val recorded: Set<String>,
    private val save: (Set<String>) -> Unit,
    private val apply: (packages: Set<String>, suspended: Boolean) -> Set<String>,
) {
    fun engage(packages: Set<String>): Set<String> {
        check(recorded.isEmpty()) { "Restore the current apps before starting another lock" }
        if (packages.isEmpty()) return emptySet()
        save(packages)
        val failures = apply(packages, true)
        save(packages - failures)
        return failures
    }

    fun release(): Set<String> {
        if (recorded.isEmpty()) return emptySet()
        val failures = apply(recorded, false)
        save(failures)
        return failures
    }
}
