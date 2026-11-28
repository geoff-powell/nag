package dev.nag.android

import android.app.admin.DeviceAdminReceiver
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.nag.core.AppLock

class NagDeviceAdmin : DeviceAdminReceiver()

internal class ManagedAppLock(private val context: Context) {
    private val policy = context.getSystemService(DevicePolicyManager::class.java)
    private val admin = ComponentName(context, NagDeviceAdmin::class.java)
    private val storage = context.getSharedPreferences("app-lock", Context.MODE_PRIVATE)

    val managed: Boolean
        get() = policy.isDeviceOwnerApp(context.packageName) || policy.isProfileOwnerApp(context.packageName)

    val recorded: Set<String> get() = storage.getStringSet("suspended", emptySet()).orEmpty().toSet()
    val selection: Set<String> get() = storage.getStringSet("selection", emptySet()).orEmpty().toSet()

    fun select(packages: Set<String>) {
        storage.edit().putStringSet("selection", packages).apply()
    }

    fun availableApps(): List<LockApp> {
        val manager = context.packageManager
        val settings = Intent(Settings.ACTION_SETTINGS).resolveActivity(manager)?.packageName
        return manager.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
            .filterNot { it.activityInfo.packageName in setOf(context.packageName, settings) }
            .distinctBy { it.activityInfo.packageName }
            .map { LockApp(it.activityInfo.packageName, it.loadLabel(manager).toString()) }
            .sortedBy { it.label.lowercase() }
    }

    fun engage(): Set<String> {
        check(managed) { "Nag needs managed-device or managed-profile access" }
        val available = availableApps().map { it.packageName }.toSet()
        val candidates = selection.intersect(available).filterNot { isSuspended(it) }.toSet()
        return lock().engage(candidates) + (selection - candidates)
    }

    fun release(): Set<String> {
        check(managed) { "Managed access is required to restore apps" }
        return lock().release()
    }

    private fun isSuspended(packageName: String): Boolean = try {
        policy.isPackageSuspended(admin, packageName)
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    private fun lock() = AppLock(recorded, save = { packages ->
        check(storage.edit().putStringSet("suspended", packages).commit()) {
            "Could not save which apps need to be restored"
        }
    }) { packages, suspended ->
        policy.setPackagesSuspended(admin, packages.toTypedArray(), suspended).toSet()
            .filter { suspended || isSuspended(it) }.toSet()
    }
}

internal data class LockApp(val packageName: String, val label: String)

@Composable
internal fun AppLocks(controller: ManagedAppLock, managed: Boolean, openSettings: () -> Unit) {
    var selection by remember(controller) { mutableStateOf(controller.selection) }
    var recorded by remember(controller) { mutableStateOf(controller.recorded) }
    var message by remember { mutableStateOf<String?>(null) }
    val apps = remember(controller, managed) { if (managed) controller.availableApps() else emptyList() }
    fun changeLock() {
        val releasing = recorded.isNotEmpty()
        message = runCatching {
            val failed = if (releasing) controller.release() else controller.engage()
            if (failed.isEmpty()) null else {
                val names = failed.joinToString { pkg -> apps.firstOrNull { it.packageName == pkg }?.label ?: pkg }
                if (releasing) "Could not restore: $names" else "Could not pause: $names"
            }
        }.getOrElse { it.message ?: "Android could not change the lock" }
        recorded = controller.recorded
    }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (managed || recorded.isNotEmpty()) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Managed app lock", style = MaterialTheme.typography.titleLarge)
                    Text(when {
                        !managed -> "Restore Nag’s management access to release this lock."
                        recorded.isNotEmpty() -> "Lock on · ${recorded.size} apps recorded for restore"
                        else -> "Choose apps to pause in this Android profile."
                    })
                    Button(onClick = ::changeLock,
                        enabled = managed && (recorded.isNotEmpty() || apps.any { it.packageName in selection })) {
                        Text(if (recorded.isEmpty()) "Turn on lock" else "Turn off lock")
                    }
                    message?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                }
            }
            items(apps, key = { it.packageName }) { app ->
                ListItem(headlineContent = { Text(app.label) }, trailingContent = {
                    Checkbox(checked = app.packageName in selection, enabled = recorded.isEmpty(),
                        onCheckedChange = { checked ->
                            selection = if (checked) selection + app.packageName else selection - app.packageName
                            controller.select(selection)
                        })
                })
            }
            item { HorizontalDivider() }
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Digital Wellbeing", style = MaterialTheme.typography.titleLarge)
                Text("In Android Settings, open Digital Wellbeing and parental controls, then Focus mode. Choose apps and turn Focus mode on or off there.")
                Button(onClick = openSettings) { Text("Open Android Settings") }
            }
        }
    }
}
