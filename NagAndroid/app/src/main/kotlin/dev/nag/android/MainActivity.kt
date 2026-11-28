package dev.nag.android

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationManager
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.text.format.DateUtils
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextDecoration
import androidx.activity.ComponentActivity
import androidx.activity.compose.PredictiveBackHandler
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.activity.ExperimentalActivityApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import dev.nag.core.*
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.datetime.TimeZone
import java.util.UUID

class MainActivity : ComponentActivity() {
    private lateinit var store: NagStore
    private var state by mutableStateOf(NagState())
    private var selected by mutableStateOf<String?>(null)
    private var draft by mutableStateOf<Nag?>(null)
    private var message by mutableStateOf<String?>(null)
    private lateinit var appLock: ManagedAppLock
    private var locks by mutableStateOf(false)
    private var managed by mutableStateOf(false)
    private var settings by mutableStateOf(false)
    private var notificationAccess by mutableStateOf(false)
    private var exactAccess by mutableStateOf(false)
    private val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ ->
        state = store.read()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        store = NagStore(this)
        appLock = ManagedAppLock(this)
        state = store.read()
        store.preferences.registerOnSharedPreferenceChangeListener(listener)
        if (savedInstanceState == null) route(intent)
        else {
            selected = savedInstanceState.getString("selected")
            settings = savedInstanceState.getBoolean("settings")
            locks = savedInstanceState.getBoolean("locks")
            draft = savedInstanceState.getString("draft")?.let { NagState.decode(it).nags.single() }
        }
        setContent {
            val dark = androidx.compose.foundation.isSystemInDarkTheme()
            val colors = when {
                Build.VERSION.SDK_INT >= 31 && dark -> dynamicDarkColorScheme(this)
                Build.VERSION.SDK_INT >= 31 -> dynamicLightColorScheme(this)
                dark -> darkColorScheme()
                else -> lightColorScheme()
            }
            MaterialTheme(colorScheme = colors) { Screen() }
        }
    }

    override fun onResume() {
        super.onResume()
        managed = appLock.managed
        notificationAccess = getSystemService(NotificationManager::class.java).areNotificationsEnabled()
        exactAccess = Build.VERSION.SDK_INT < 31 || getSystemService(AlarmManager::class.java).canScheduleExactAlarms()
        Reminders.schedule(this)
    }

    private val requestNotifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        notificationAccess = getSystemService(NotificationManager::class.java).areNotificationsEnabled()
        Reminders.schedule(this)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString("selected", selected)
        outState.putBoolean("settings", settings)
        outState.putBoolean("locks", locks)
        draft?.let { outState.putString("draft", NagState(nags = listOf(it)).encode()) }
    }

    override fun onDestroy() {
        store.preferences.unregisterOnSharedPreferenceChangeListener(listener)
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        route(intent)
    }

    private fun newNag(title: String = "") = Nag(UUID.randomUUID().toString(), title,
        Schedule(System.currentTimeMillis()))

    private fun route(intent: Intent) {
        val now = System.currentTimeMillis()
        if (intent.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()?.takeIf { it.isNotEmpty() } ?: return
            val link = Uri.parse(text)
            if (link.scheme.equals("nag", ignoreCase = true)) routeLink(link, now)
            else draft = newNag(text.lineSequence().first().take(200)).copy(notes = text)
        } else if (intent.action == Intent.ACTION_VIEW) {
            intent.data?.let { routeLink(it, now) }
        }
    }

    private fun routeLink(uri: Uri, now: Long) {
        if (!uri.scheme.equals("nag", ignoreCase = true) || !uri.isHierarchical) return
        runCatching {
            draft = null
            settings = false
            locks = false
            selected = null
            when ((uri.host ?: uri.path?.trim('/'))?.lowercase()) {
                "nags" -> Unit
                "new-nag", "newnag" -> draft = newNag()
                "nag" -> {
                    val id = uri.getQueryParameter("id")
                    selected = state.nags.firstOrNull { it.id.equals(id, ignoreCase = true) }?.id
                        ?: error("Nag not found on this device")
                }
                "add", "new" -> save(nagFromLink(uri, now, state.nags))
                "locks", "unlock" -> locks = true
                "scan" -> error("Scan proof is unavailable on Android")
                else -> error("Unknown Nag link")
            }
        }.onFailure { message = it.message ?: "Could not open Nag link" }
    }

    private fun change(transform: (NagState) -> NagState) {
        if (store.update(transform)) lifecycleScope.launch { refreshWidgets(this@MainActivity) }
    }

    private fun save(nag: Nag) {
        val now = System.currentTimeMillis()
        val zone = TimeZone.currentSystemDefault()
        change { it.save(nag, now, zone) }
        selected = nag.id
        draft = null
    }

    private fun updateNag(id: String, transform: (Nag) -> Nag) {
        change { state -> state.copy(nags = state.nags.map { if (it.id == id) transform(it) else it }) }
    }

    @OptIn(ExperimentalMaterial3Api::class, ExperimentalActivityApi::class)
    @Composable
    private fun Screen() {
        var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
        LaunchedEffect(Unit) {
            while (true) {
                now = System.currentTimeMillis()
                delay(1_000)
            }
        }
        val zone = TimeZone.currentSystemDefault()
        val groups = state.groups(now, zone)
        val snackbar = remember { SnackbarHostState() }
        val scope = rememberCoroutineScope()
        var undoJob by remember { mutableStateOf<Job?>(null) }
        fun complete(nag: Nag) {
            val before = store.read().nags.firstOrNull { it.id == nag.id } ?: return
            val after = before.complete(System.currentTimeMillis(), zone)
            if (after == before) return
            updateNag(before.id) { after }
            undoJob?.cancel()
            undoJob = scope.launch {
                if (snackbar.showSnackbar("Marked done", "Undo", duration = SnackbarDuration.Short)
                    == SnackbarResult.ActionPerformed) {
                    updateNag(before.id) {
                        if (it.revision == after.revision) before.copy(revision = it.revision + 1) else it
                    }
                }
            }
        }
        var deletion by remember { mutableStateOf<Nag?>(null) }
        val current = state.nags.firstOrNull { it.id == selected }
        val editor = draft
        PredictiveBackHandler(editor != null || settings || locks || selected != null) { progress ->
            progress.collect {}
            when {
                editor != null -> draft = null
                settings -> settings = false
                locks -> locks = false
                else -> selected = null
            }
        }
        Scaffold(snackbarHost = { SnackbarHost(snackbar) }, topBar = {
            TopAppBar(title = { Text(when { settings -> "Settings"; locks -> "Locks"; else -> "Nags" }) }, actions = {
                if (!settings && !locks) {
                    TextButton(onClick = { locks = true }) { Text("Locks") }
                    TextButton(onClick = { settings = true }) { Text("Settings") }
                } else TextButton(onClick = { settings = false; locks = false }) { Text("Nags") }
            })
        }, floatingActionButton = {
            if (!settings && !locks) ExtendedFloatingActionButton(onClick = { draft = newNag() },
                text = { Text("New nag") }, icon = { Text("+") })
        }) { padding ->
            BoxWithConstraints(Modifier.fillMaxSize().padding(padding)) {
                val wide = maxWidth >= 720.dp
                if (locks) {
                    AppLocks(appLock, managed) { startActivity(Intent(Settings.ACTION_SETTINGS)) }
                } else if (settings) {
                    SettingsContent(state.quiet, notificationAccess, exactAccess,
                        onNotifications = {
                            if (Build.VERSION.SDK_INT >= 33 &&
                                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
                                !store.preferences.getBoolean("askedNotifications", false)) {
                                store.preferences.edit().putBoolean("askedNotifications", true).apply()
                                requestNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
                            } else startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
                        },
                        onExact = {
                            if (Build.VERSION.SDK_INT >= 31) startActivity(Intent(
                                Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName")))
                        },
                        onSave = { quiet -> change { it.copy(quiet = quiet) }; settings = false })
                } else {
                    Row(Modifier.fillMaxSize()) {
                        if (wide || current == null) {
                            LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = 90.dp)) {
                                if (state.nags.isEmpty()) item {
                                    Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                        Text("Nothing to nag about", style = MaterialTheme.typography.titleLarge)
                                        Text("Add a nag and get reminders until it is done.")
                                    }
                                }
                                val sections = listOf("Now" to groups.now, "Coming up" to groups.later,
                                    "Done" to groups.done, "Archived" to groups.archived)
                                sections.filter { it.second.isNotEmpty() }.forEach { (title, nags) ->
                                    item(key = title) {
                                        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 8.dp),
                                            horizontalArrangement = Arrangement.SpaceBetween,
                                            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                                            Text(title, style = MaterialTheme.typography.titleSmall,
                                                color = MaterialTheme.colorScheme.primary)
                                            if (title == "Done" && nags.any { it.completed }) {
                                                TextButton(onClick = {
                                                    change { it.copy(nags = it.nags.filterNot { nag ->
                                                        nag.completed && !nag.archived
                                                    }) }
                                                }) { Text("Clear") }
                                            }
                                        }
                                    }
                                    items(nags, key = { it.id }) { nag ->
                                        val color = if (selected == nag.id) MaterialTheme.colorScheme.secondaryContainer
                                            else MaterialTheme.colorScheme.surface
                                        Surface(onClick = { selected = nag.id }, color = color) {
                                            ListItem(headlineContent = { Text(nag.title, textDecoration =
                                                if (nag.completed) TextDecoration.LineThrough else null) },
                                                supportingContent = {
                                                    if (nag.notes.isNotBlank()) Text(nag.notes, maxLines = 2)
                                                    Text(status(nag, now, zone))
                                                },
                                                leadingContent = if (nag.archived) null else {
                                                    {
                                                        Checkbox(checked = nag.completed ||
                                                            (nag.schedule.repeat != Repeat.Once && !nag.canComplete(now, zone)),
                                                            modifier = Modifier.semantics {
                                                                contentDescription = if (nag.completed) "Reopen ${nag.title}"
                                                                    else "Mark ${nag.title} done"
                                                            },
                                                            enabled = nag.completed || nag.canComplete(now, zone),
                                                            onCheckedChange = {
                                                                if (nag.completed) updateNag(nag.id, Nag::reopen)
                                                                else complete(nag)
                                                            })
                                                    }
                                                },
                                                colors = ListItemDefaults.colors(containerColor =
                                                    androidx.compose.ui.graphics.Color.Transparent))
                                        }
                                    }
                                }
                            }
                        }
                        if (wide && current != null) VerticalDivider()
                        if (current != null) Column(Modifier.weight(1f)) {
                            NagDetail(current, now, zone, onBack = { selected = null },
                                onEdit = { draft = current },
                                onShare = { share(current) },
                                onDone = { complete(current) },
                                onStart = { updateNag(current.id) { it.start(System.currentTimeMillis()) } },
                                onSnooze = { minutes -> updateNag(current.id) { it.snooze(System.currentTimeMillis(), minutes) } },
                                onReopen = { updateNag(current.id, Nag::reopen) },
                                onArchive = { updateNag(current.id) { it.archive(!it.archived) } },
                                onDuplicate = {
                                    save(current.copy(id = UUID.randomUUID().toString(), title = "${current.title} copy",
                                        externalId = null))
                                },
                                onDelete = { deletion = current })
                        }
                    }
                }
            }
        }
        if (editor != null) key(editor.id) {
            NagEditor(editor, { draft = null }, { save(it) })
        }
        deletion?.let { nag ->
            AlertDialog(onDismissRequest = { deletion = null },
                title = { Text("Delete nag?") }, text = { Text(nag.title) },
                confirmButton = { TextButton(onClick = {
                    change { it.copy(nags = it.nags.filterNot { item -> item.id == nag.id }) }
                    deletion = null
                    selected = null
                }) { Text("Delete") } },
                dismissButton = { TextButton(onClick = { deletion = null }) { Text("Cancel") } })
        }
        val alert = message
        if (alert != null) AlertDialog(onDismissRequest = { message = null },
            text = { Text(alert) }, confirmButton = { TextButton(onClick = { message = null }) { Text("OK") } })
    }

    private fun share(nag: Nag) {
        if (nag.schedule.repeat == Repeat.Custom && nag.schedule.slots.map { it.days }.distinct().size > 1) {
            message = "Nag links need the same weekdays for all custom times."
            return
        }
        val link = Uri.parse("nag://add").buildUpon()
            .appendQueryParameter("title", nag.title)
            .appendQueryParameter("notes", nag.notes)
            .appendQueryParameter("at", localTime(nag.schedule.anchor).replace(' ', 'T'))
            .appendQueryParameter("every", nag.interval.toString())
            .appendQueryParameter("escalation", nag.escalation.name.lowercase())
            .appendQueryParameter("snooze", nag.snoozeMinutes.toString())
            .appendQueryParameter("snoozes", nag.snoozeLimit?.toString() ?: "unlimited")
        val schedule = nag.schedule
        // NagLink uses one weekday set for all custom times.
        link.appendQueryParameter("repeat", if (schedule.repeat == Repeat.EveryDays) "every_days"
            else schedule.repeat.name.lowercase())
        if (schedule.repeat == Repeat.EveryDays) link.appendQueryParameter("every_days", schedule.intervalDays.toString())
        if (schedule.repeat == Repeat.Monthly) link.appendQueryParameter("month_day", schedule.monthDay.toString())
        if (schedule.repeat == Repeat.Custom) {
            link.appendQueryParameter("times", schedule.slots.joinToString(",") { timeText(it.minute) })
            link.appendQueryParameter("days", daysText(schedule.slots.first().days))
        }
        nag.link?.let { link.appendQueryParameter("link", it) }
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain")
            .putExtra(Intent.EXTRA_TEXT, link.build().toString()), null))
    }
}

private fun status(nag: Nag, now: Long, zone: TimeZone): String {
    fun relative(time: Long) = DateUtils.getRelativeTimeSpanString(time, now, DateUtils.MINUTE_IN_MILLIS)
    fun elapsed(since: Long): String {
        val minutes = ((now - since) / 60_000).coerceAtLeast(0)
        return if (minutes < 60) "${minutes}m" else "${minutes / 60}h ${minutes % 60}m"
    }
    val started = nag.started
    val snoozed = nag.snoozed
    val completed = nag.lastCompleted
    return when {
        nag.archived -> "Archived"
        nag.completed -> completed?.let { "Done ${relative(it)}" } ?: "Done"
        snoozed != null && snoozed > now -> "Snoozed until ${localTime(snoozed)}"
        started != null -> "Started ${elapsed(started)} ago" +
            if (now < started + nag.workMinutes * 60_000L) "" else " / checking in"
        nag.due <= now -> {
            val due = if (now - nag.due < 60_000) "Due now" else "Overdue ${elapsed(nag.due)}"
            val remaining = nag.snoozeLimit?.let { (it - nag.snoozes).coerceAtLeast(0) }
            if (remaining == null) due else "$due / $remaining snooze${if (remaining == 1) "" else "s"} left"
        }
        completed != null && sameLocalDay(completed, now, zone) -> "Done today / next ${relative(nag.due)}"
        else -> "Starts ${relative(nag.due)}"
    }
}

private fun sameLocalDay(first: Long, second: Long, zone: TimeZone): Boolean {
    val javaZone = java.time.ZoneId.of(zone.id)
    return java.time.Instant.ofEpochMilli(first).atZone(javaZone).toLocalDate() ==
        java.time.Instant.ofEpochMilli(second).atZone(javaZone).toLocalDate()
}

@Composable
private fun NagDetail(nag: Nag, now: Long, zone: TimeZone, onBack: () -> Unit, onEdit: () -> Unit,
    onShare: () -> Unit, onDone: () -> Unit, onStart: () -> Unit, onSnooze: (Int) -> Unit,
    onReopen: () -> Unit, onArchive: () -> Unit, onDuplicate: () -> Unit, onDelete: () -> Unit) {
    val context = LocalContext.current
    var snoozeMenu by remember(nag.id) { mutableStateOf(false) }
    var moreMenu by remember(nag.id) { mutableStateOf(false) }
    LazyColumn(contentPadding = PaddingValues(24.dp, 16.dp, 24.dp, 96.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { TextButton(onClick = onBack) { Text("All nags") } }
        item { Text(nag.title, style = MaterialTheme.typography.headlineMedium) }
        item { Text(status(nag, now, zone)) }
        if (nag.notes.isNotBlank()) item { Text(nag.notes) }
        if (nag.link != null) {
            val uri = Uri.parse(nag.link)
            if (uri.scheme?.lowercase() in setOf("http", "https")) item {
                TextButton(onClick = { runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, uri)) } }) {
                    Text("Open source")
                }
            }
        }
        item {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (nag.canComplete(now, zone)) Button(onClick = onDone) { Text("Done") }
                if (nag.completed && !nag.archived) Button(onClick = onReopen) { Text("Reopen") }
                if (nag.canSnooze(now)) Box {
                    OutlinedButton(onClick = { snoozeMenu = true }) { Text("Snooze") }
                    DropdownMenu(expanded = snoozeMenu, onDismissRequest = { snoozeMenu = false }) {
                        listOf(5 to "5 minutes", 15 to "15 minutes", 60 to "1 hour").forEach { (minutes, label) ->
                            DropdownMenuItem(text = { Text(label) }, onClick = {
                                snoozeMenu = false
                                onSnooze(minutes)
                            })
                        }
                    }
                }
                if (nag.canStart(now)) OutlinedButton(onClick = onStart) { Text("Start") }
            }
        }
        item {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = onEdit) { Text("Edit") }
                TextButton(onClick = onShare) { Text("Share") }
                Box {
                    TextButton(onClick = { moreMenu = true }) { Text("More") }
                    DropdownMenu(expanded = moreMenu, onDismissRequest = { moreMenu = false }) {
                        listOf(
                            (if (nag.archived) "Restore" else "Archive") to onArchive,
                            "Duplicate" to onDuplicate,
                            "Delete" to onDelete,
                        ).forEach { (label, action) ->
                            DropdownMenuItem(text = { Text(label) }, onClick = { moreMenu = false; action() })
                        }
                    }
                }
            }
        }
    }
}
