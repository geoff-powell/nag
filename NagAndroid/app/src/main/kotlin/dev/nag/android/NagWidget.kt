package dev.nag.android

import android.content.Context
import android.content.Intent
import androidx.compose.runtime.*
import android.content.SharedPreferences
import dev.nag.core.Nag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.Column
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.padding
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.text.FontWeight

class NagWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = NagWidget()
}

internal class NagWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val store = NagStore(context)
        provideContent {
            var state by remember { mutableStateOf(store.read()) }
            DisposableEffect(store) {
                val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ ->
                    state = store.read()
                }
                store.preferences.registerOnSharedPreferenceChangeListener(listener)
                state = store.read()
                onDispose { store.preferences.unregisterOnSharedPreferenceChangeListener(listener) }
            }
            val nags = state.nags.filterNot { it.completed || it.archived }.sortedBy { it.due }.take(3)
            GlanceTheme { WidgetContent(context, nags) }
        }
    }
}

@Composable
private fun WidgetContent(context: Context, nags: List<Nag>) {
    val open = Intent(Intent.ACTION_VIEW, android.net.Uri.parse("nag://nags"), context, MainActivity::class.java)
    val colors = GlanceTheme.colors
    Column(GlanceModifier.fillMaxSize().background(colors.widgetBackground).padding(12.dp)) {
        Text("Nag", GlanceModifier.clickable(actionStartActivity(open)),
            style = TextStyle(color = colors.onSurface, fontSize = 18.sp, fontWeight = FontWeight.Bold))
        if (nags.isEmpty()) Text("No open nags", style = TextStyle(color = colors.onSurface))
        nags.forEach { nag ->
            val detail = Intent(Intent.ACTION_VIEW, nagUri(nag.id), context, MainActivity::class.java)
            Text(nag.title, GlanceModifier.padding(top = 6.dp).clickable(actionStartActivity(detail)),
                style = TextStyle(color = colors.onSurface), maxLines = 1)
        }
    }
}

internal suspend fun refreshWidgets(context: Context) = NagWidget().updateAll(context)
