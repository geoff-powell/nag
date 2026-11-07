# Core rule inventory: Swift `NagCore` and C# `Nag.Core`

Part of the Kotlin Multiplatform investigation (#41). This page lists the
domain rules that both clients implement and where they differ. Paths are
relative to the repository root.

- Swift: `Packages/NagKit/Sources/NagCore`. It is the larger implementation
  and is synced through iCloud, so it is treated as the reference.
- C#: `NagWindows/Nag.Core/Models.cs`, 178 lines. The Windows client stores
  its data separately and does not sync.

Neither core has a clock abstraction. Both take an explicit `now`. Swift also
takes a `Calendar`, while C# uses local wall-clock `DateTime`.

## Summary

| Area | Swift | C# | Same? |
|---|---|---|---|
| Repeat kinds | never, daily, weekdays, weekly, custom times, every N days, monthly | Once, Daily, Weekdays, Weekly | No: C# has a subset |
| Time zones and DST | `Calendar` with wall-clock hour/minute (`bySettingHour`) | local `DateTime` arithmetic, no handling of nonexistent or repeated times | No, and neither tests DST gaps or overlaps for daily/weekly |
| Escalation interval | seconds | minutes, same formulas | Yes (checked by fixtures) |
| Next tightening point | `nextTightening` | not implemented | Swift only |
| Snooze eligibility | outstanding and snoozes left | outstanding, **not already snoozed**, and snoozes left | No |
| Unlimited snoozes | `maxSnoozes == nil` | not representable (0…100) | Swift only |
| Snooze length | `now + minutes`, minutes not validated | `now + SnoozeMinutes` (validated 1…1440) | Same for valid input |
| Quiet hours | minute granularity | hour granularity | No |
| Completing a repeating nag early | allowed if due before the end of today | throws "not due yet" | No |
| Completion reset | clears snooze, count, started; undo snapshot | clears snooze, count, `LastNotified` | Snooze fields match |
| Locks | schedules, sessions, six requirement kinds, monthly emergency quota | while-due or timer; unlimited 5-minute emergency unlock | No, different models |
| Validation | `NagRequest.validateRanges` on input | `Reminder.Validate` / `State.Validate` on every save | Overlapping ranges |
| Sync merge | `TaskMerge`, last writer wins with tombstones | none | Swift only |
| Persistence | `state.json`, camelCase, `JSONEncoder` dates (seconds since 2001), no version | `windows-state.json`, PascalCase, ISO dates, `Version: 1` | No: separate formats |

## 1. Recurrence

**Swift** (`TaskRules.swift:20-160`, `Models.swift:6-56`)
- `occurrence(after:anchor:calendar:)` keeps the anchor's local hour and minute.
- `everyNDaysOccurrence` counts calendar days.
- `monthlyOccurrence` clamps the day to the length of the month, then goes back to the preferred day the following month.
- `complete` uses `max(now, startAt)` as the base. A late completion skips missed occurrences; an early one completes the upcoming occurrence. If no occurrence is found it falls back to +86 400 s (`TaskRules.swift:247`).

**C#** (`Models.cs:56-82`)
- Weekly jumps forward by whole weeks.
- Daily and Weekdays start from `now.Date + Due.TimeOfDay`.
- Completing a recurring nag before it is due throws (`Models.cs:64`).
- A Weekdays nag may start on a weekend; it only moves to Monday when completed.

**Differences**
- C# rejects early completion.
- C# does not handle times that don't exist or occur twice when the clocks change.
- When decoding, Swift derives the default `monthDay` in UTC (`Models.swift:295-299`); in `init` it uses `Calendar.current` (`Models.swift:260`).

## 2. Escalation

**Swift** (`NagPlanner.swift:3-43`)
- `interval(base:overdue:) = max(60, floor, base × factor^⌊overdue / step⌋)`, with `base` clamped to at least 60.

| Mode | Step | Factor | Floor |
|---|---|---|---|
| steady | none | none | base |
| gentle | 3600 s | 0.75 | base / 2 |
| relentless | 1800 s | 0.5 | 60 s |

- `nextTightening` returns the next step boundary only while the interval is still shrinking.

**C#** (`Models.cs:29-38`)
- The same formulas in minutes:
  - Gentle: `max(1, I/2, I × 0.75^⌊o/60⌋)`
  - Relentless: `max(1, I / 2^min(30, ⌊o/30⌋))`
- The cap of 30 on the exponent changes nothing, because the result is already floored at 1 minute.

**Overdue time** is measured from `startAt`/`Due` in both cores, so snoozing does not reset escalation.

**Result:** the formulas are equivalent for every valid input. `Fixtures/conformance/escalation.json` checks this.

## 3. Snooze

| Rule | Swift (`TaskRules.swift:220-292`) | C# (`Models.cs:48-55`) |
|---|---|---|
| Eligibility | `isOutstanding && (snoozesLeft ?? 1) > 0` | `Outstanding && !Snoozed && SnoozeCount < MaxSnoozes` |
| Snooze again while snoozed | allowed; replaces `snoozedUntil` with `now + minutes` | refused (throws) |
| Nag not yet due | refused | refused |
| One-off already done | refused | refused |
| `maxSnoozes = 0` | refused | refused |
| Unlimited | `maxSnoozes = nil` | not representable |
| Refusal | returns `false` and leaves the nag unchanged | throws `InvalidOperationException` |
| Side effects | `snoozeCount += 1`, `updatedAt` | `SnoozeCount++`, `LastNotified = null` |
| Reset | complete, a `save` that moves `startAt`, undo | complete, an editor change to `Due` or `Repeat` |

`Fixtures/conformance/snooze.json` records these differences.

## 4. Quiet hours

- **Swift** (`NagPlanner.swift:45-63`, `QuietHoursSyncing.swift`)
  - Uses minutes since midnight. The window is `[start, end)` and can cross midnight.
  - `nextAllowed` moves a time inside the window to the end of the window.
  - Quiet hours sync across devices, last writer wins.
- **C#** (`Models.cs:110-112`)
  - Uses whole hours (`now.Hour`) with the same window rules.
- **Shared limitation:** neither core handles a window boundary that falls in a DST gap or overlap.

## 5. Nag status

Neither core stores a status. Both derive it from the stored fields.

| Status | Swift | C# |
|---|---|---|
| finished | one-off with `completedAt` | `Finished` |
| outstanding | `startAt <= now` and not finished | `Due <= now` and not finished |
| snoozed | outstanding and `snoozedUntil > now` | outstanding and `SnoozedUntil > now` |

- Only Swift has the "started" status and its working window.
- C# Reopen sets `Due = DateTime.Now` (`MainWindow.cs:166`). Swift `reopen` only clears `completedAt`.

## 6. Locks

The two lock models are different, so locks are not a good first candidate for sharing.

- **Swift** (`LockRules.swift`, `UnlockEvaluator.swift`)
  - A lock moves between off, locked and unlocked-until, with sessions, schedules and auto-unlock.
  - Requirement kinds: tasks, due nags, key scan, walk, wait and typed phrase.
- **C#** (`Models.cs:92-103`)
  - A lock is active while a nag is due or until a timer ends.
  - Emergency unlock is unlimited and lasts 5 minutes (`MainWindow.cs:224`).

## 7. Validation and merge

- **Swift** (`NagRequest.swift`, `TaskMerge.swift`)
  - Range checks apply to incoming requests only. The model itself does not clamp `intervalMinutes`.
  - Merge is last writer wins, with an undo-aware completion merge and 30-day tombstones.
- **C#** (`Models.cs:83-89`, `121-134`)
  - Validates the whole state on every save.
  - Has no merge.

| Field | Swift request | C# reminder |
|---|---|---|
| interval | 1…1440 | 1…1440 |
| snooze minutes | 1…1440 | 1…1440 |
| max snoozes | ≥ 0 | 0…100 |
| title | any length | ≤ 200 |

## Test coverage gaps

The fixtures should eventually cover these:
- DST gaps and overlaps for daily, weekly and custom repeats, quiet hours and lock schedules.
- Changing time zone.
- Merge tie-breaks when titles are equal.
- In C#: quiet hours actually suppressing `ShouldNotify`, and early completion of recurring nags.

## Chosen first slice

The prototype covers **escalation and snooze eligibility** (#41 step 2):
- These rules need only instants and durations, so time zones don't affect them yet.
- Escalation should agree between the two cores. Snooze has a known difference, so the fixtures exercise both agreement and disagreement.
