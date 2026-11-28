package dev.nag.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.nag.core.Escalation
import dev.nag.core.Nag
import dev.nag.core.QuietHours
import dev.nag.core.Repeat
import dev.nag.core.Schedule
import dev.nag.core.Slot
import java.time.Instant
import java.time.ZoneOffset
import java.time.ZoneId

// Save each custom time as one integer with a seven-bit weekday mask.
private const val DAY_MASK_SIZE = 1 shl 7
private val everyDay = (1..7).toSet()

private fun dayMask(days: Set<Int>) = days.sumOf { 1 shl (it - 1) }
private fun slotDays(value: Int) = (1..7).filter { value and (1 shl (it - 1)) != 0 }.toSet()

internal fun daysText(days: Set<Int>): String =
    days.sorted().joinToString(",") { listOf("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")[it - 1] }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun NagEditor(nag: Nag, onDismiss: () -> Unit, onSave: (Nag) -> Unit) {
    val schedule = nag.schedule
    var title by rememberSaveable { mutableStateOf(nag.title) }
    var notes by rememberSaveable { mutableStateOf(nag.notes) }
    var startsAt by rememberSaveable { mutableStateOf<Long?>(if (nag.revision == 0L) null else schedule.anchor) }
    var pickDate by rememberSaveable { mutableStateOf(false) }
    var pickTime by rememberSaveable { mutableStateOf(false) }
    val zone = ZoneId.systemDefault()
    val local = Instant.ofEpochMilli(startsAt ?: System.currentTimeMillis()).atZone(zone)
    var repeat by rememberSaveable { mutableStateOf(schedule.repeat) }
    var intervalDays by rememberSaveable { mutableStateOf(schedule.intervalDays.toString()) }
    var monthDay by rememberSaveable { mutableStateOf(if (nag.revision == 0L) "" else schedule.monthDay.toString()) }
    var timeValues by rememberSaveable {
        mutableStateOf(ArrayList(schedule.slots.map { slot -> slot.minute * DAY_MASK_SIZE + dayMask(slot.days) }))
    }
    var editingSlot by rememberSaveable { mutableIntStateOf(-1) }
    fun updateSlot(index: Int, value: Int) {
        timeValues = ArrayList(timeValues).apply { this[index] = value }
    }
    var interval by rememberSaveable { mutableStateOf(nag.interval.toString()) }
    var escalation by rememberSaveable { mutableStateOf(nag.escalation) }
    var snooze by rememberSaveable { mutableStateOf(nag.snoozeMinutes.toString()) }
    var limit by rememberSaveable { mutableStateOf(nag.snoozeLimit?.toString().orEmpty()) }
    var work by rememberSaveable { mutableStateOf(nag.workMinutes.toString()) }
    var error by rememberSaveable { mutableStateOf<String?>(null) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text(if (nag.revision == 0L) "New nag" else "Edit nag") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Field("Title", title, { title = it })
                Field("Notes", notes, { notes = it }, singleLine = false)
                Text("When", style = MaterialTheme.typography.titleMedium)
                if (repeat != Repeat.Custom) {
                    Text(startsAt?.let(::localTime) ?: "Starts now")
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = { pickDate = true }) { Text("Date") }
                        OutlinedButton(onClick = { pickTime = true }) { Text("Time") }
                        if (startsAt != null) TextButton(onClick = { startsAt = null }) { Text("Now") }
                    }
                }
                Choice("Repeat", repeat, Repeat.entries, { choice ->
                    if (choice == Repeat.Custom && timeValues.isEmpty()) {
                        timeValues = arrayListOf((local.hour * 60 + local.minute) * DAY_MASK_SIZE + dayMask(everyDay))
                    }
                    repeat = choice
                }) {
                    if (it == Repeat.EveryDays) "Every N days" else it.name
                }
                if (repeat == Repeat.EveryDays) Field("Days between occurrences", intervalDays, { intervalDays = it })
                if (repeat == Repeat.Monthly) Field("Day of month", monthDay, { monthDay = it }, "Blank uses the start day")
                if (repeat == Repeat.Custom) {
                    timeValues.forEachIndexed { index, value ->
                        val days = slotDays(value)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = { editingSlot = index }) { Text(timeText(value / DAY_MASK_SIZE)) }
                            TextButton(onClick = {
                                timeValues = ArrayList(timeValues).apply { removeAt(index) }
                            }) { Text("Remove time") }
                        }
                        (1..7).chunked(4).forEach { row ->
                            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                row.forEach { day ->
                                    FilterChip(selected = day in days,
                                        onClick = { updateSlot(index, value xor (1 shl (day - 1))) },
                                        label = { Text(daysText(setOf(day))) })
                                }
                            }
                        }
                    }
                    TextButton(onClick = {
                        timeValues = ArrayList(timeValues).apply { add(9 * 60 * DAY_MASK_SIZE + dayMask(everyDay)) }
                    }) { Text("Add time") }
                }
                Text("Reminders", style = MaterialTheme.typography.titleMedium)
                Field("Reminder interval in minutes", interval, { interval = it })
                Choice("Escalation", escalation, Escalation.entries, { escalation = it }) { it.name }
                Field("Work session in minutes", work, { work = it })
                Text("Snooze", style = MaterialTheme.typography.titleMedium)
                Field("Snooze in minutes", snooze, { snooze = it })
                Field("Snooze limit", limit, { limit = it }, "Blank allows unlimited snoozes")
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            Button(onClick = {
                runCatching {
                    require(title.isNotBlank()) { "Enter a title" }
                    val now = System.currentTimeMillis()
                    val anchor = startsAt ?: now
                    val slots = if (repeat == Repeat.Custom) {
                        require(timeValues.isNotEmpty() && timeValues.all { slotDays(it).isNotEmpty() }) {
                            "Add a time and select at least one day for each time"
                        }
                        timeValues.map { Slot(it / DAY_MASK_SIZE, slotDays(it)) }
                    } else schedule.slots
                    val defaultDay = Instant.ofEpochMilli(anchor).atZone(ZoneId.systemDefault()).dayOfMonth
                    val nextSchedule = Schedule(anchor, repeat,
                        if (repeat == Repeat.EveryDays) number(intervalDays, 1..3650, "Days") else schedule.intervalDays,
                        if (repeat == Repeat.Monthly) monthDay.takeIf { it.isNotBlank() }
                            ?.let { number(it, 1..31, "Day of month") } ?: defaultDay else schedule.monthDay,
                        slots)
                    nag.copy(title = title.trim(), notes = notes, schedule = nextSchedule,
                        interval = number(interval, 1..1440, "Reminder interval"), escalation = escalation,
                        snoozeMinutes = number(snooze, 1..1440, "Snooze length"),
                        snoozeLimit = limit.takeIf { it.isNotBlank() }?.let { number(it, 0..1000, "Snooze limit") },
                        workMinutes = number(work, 1..1440, "Work session"))
                }.onSuccess(onSave).onFailure { error = it.message ?: "Check the reminder settings" }
            }) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } })
    if (pickDate) {
        val date = rememberDatePickerState(initialSelectedDateMillis =
            local.toLocalDate().atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli())
        DatePickerDialog(onDismissRequest = { pickDate = false }, confirmButton = {
            TextButton(onClick = {
                date.selectedDateMillis?.let {
                    val day = Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate()
                    startsAt = day.atTime(local.toLocalTime()).atZone(zone).toInstant().toEpochMilli()
                }
                pickDate = false
            }) { Text("OK") }
        }, dismissButton = { TextButton(onClick = { pickDate = false }) { Text("Cancel") } }) {
            DatePicker(state = date)
        }
    }
    if (editingSlot in timeValues.indices) {
        val value = timeValues[editingSlot]
        TimeDialog(value / DAY_MASK_SIZE, { editingSlot = -1 }) { minute ->
            updateSlot(editingSlot, minute * DAY_MASK_SIZE + value % DAY_MASK_SIZE)
        }
    }
    if (pickTime) {
        TimeDialog(local.hour * 60 + local.minute, { pickTime = false }) { minute ->
            startsAt = local.toLocalDate().atTime(minute / 60, minute % 60).atZone(zone).toInstant().toEpochMilli()
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TimeDialog(minute: Int, dismiss: () -> Unit, select: (Int) -> Unit) {
    val time = rememberTimePickerState(initialHour = minute / 60, initialMinute = minute % 60,
        is24Hour = android.text.format.DateFormat.is24HourFormat(androidx.compose.ui.platform.LocalContext.current))
    AlertDialog(onDismissRequest = dismiss, title = { Text("Select time") },
        text = { TimeInput(time) },
        confirmButton = {
            TextButton(onClick = { select(time.hour * 60 + time.minute); dismiss() }) { Text("OK") }
        }, dismissButton = { TextButton(onClick = dismiss) { Text("Cancel") } })
}

@Composable
internal fun SettingsContent(quiet: QuietHours?, notifications: Boolean, exact: Boolean,
    onNotifications: () -> Unit, onExact: () -> Unit, onSave: (QuietHours?) -> Unit) {
    var enabled by rememberSaveable { mutableStateOf(quiet != null) }
    var from by rememberSaveable { mutableStateOf(timeText(quiet?.start ?: 1320)) }
    var to by rememberSaveable { mutableStateOf(timeText(quiet?.end ?: 420)) }
    var error by rememberSaveable { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Reminders", style = MaterialTheme.typography.titleLarge)
        if (!notifications) Text("Allow notifications to receive reminder alerts and actions.")
        OutlinedButton(onClick = onNotifications) {
            Text(if (notifications) "Notification settings" else "Allow notifications")
        }
        if (!exact) {
            Text("Android may delay reminders when exact alarms are disabled.")
            OutlinedButton(onClick = onExact) { Text("Allow exact alarms") }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Text("Quiet hours", style = MaterialTheme.typography.titleLarge)
            Switch(checked = enabled, onCheckedChange = { enabled = it })
        }
        if (enabled) {
            Field("From", from, { from = it }, "HH:mm")
            Field("Until", to, { to = it }, "HH:mm")
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Button(onClick = {
            runCatching {
                if (!enabled) null else QuietHours(minuteOfDay(from), minuteOfDay(to)).also {
                    require(it.start != it.end) { "Choose different start and end times" }
                }
            }.onSuccess(onSave).onFailure { error = it.message }
        }) { Text("Save quiet hours") }
    }
}

@Composable
private fun Field(label: String, value: String, onChange: (String) -> Unit,
    help: String? = null, singleLine: Boolean = true) {
    OutlinedTextField(value, onChange, Modifier.fillMaxWidth(), label = { Text(label) },
        supportingText = help?.let { { Text(it) } }, singleLine = singleLine)
}

@Composable
private fun <T> Choice(label: String, selected: T, choices: List<T>, select: (T) -> Unit, name: (T) -> String) {
    var expanded by remember { mutableStateOf(false) }
    Column {
        Text(label, style = MaterialTheme.typography.labelLarge)
        Box {
            OutlinedButton(onClick = { expanded = true }) { Text(name(selected)) }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                choices.forEach { value ->
                    DropdownMenuItem(text = { Text(name(value)) }, onClick = { select(value); expanded = false })
                }
            }
        }
    }
}
