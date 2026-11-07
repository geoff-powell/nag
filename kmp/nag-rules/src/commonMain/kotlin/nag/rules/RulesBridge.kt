package nag.rules

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put

/**
 * A JSON-in, JSON-out entry point for hosts that cannot use the typed API, such as .NET through the
 * C ABI. Requests have the same shape as a fixture case's `input`. The response is
 * `{"ok": true, "result": {...}}` or `{"ok": false, "error": "..."}`; this function never throws, so
 * no exception can cross a C boundary.
 */
object RulesBridge {
    fun evaluate(request: String): String {
        val response = try {
            buildJsonObject {
                put("ok", true)
                put("result", evaluate(Json.parseToJsonElement(request).jsonObject))
            }
        } catch (error: Throwable) {
            buildJsonObject {
                put("ok", false)
                put("error", "${error::class.simpleName}: ${error.message}")
            }
        }
        return response.toString()
    }

    internal fun evaluate(input: JsonObject): JsonObject = when (val op = input.string("op")) {
        "escalation" -> escalation(input)
        "snooze" -> snooze(input)
        "complete" -> buildJsonObject { put("task", input.task().complete().toJson()) }
        else -> throw IllegalArgumentException("Unknown op '$op'")
    }

    private fun escalation(input: JsonObject): JsonObject {
        val mode = Escalation.parse(input.string("mode"))
        val base = input.number("baseSeconds")
        val overdue = input.number("overdueSeconds")
        return buildJsonObject {
            put("intervalSeconds", mode.interval(base, overdue))
            put("nextTighteningSeconds", mode.nextTightening(base, overdue))
        }
    }

    private fun snooze(input: JsonObject): JsonObject {
        val now = input.field("now").jsonPrimitive.long
        val task = input.task()
        val snoozed = task.snoozed(now)
        return buildJsonObject {
            put("canSnooze", snoozed != null)
            put("task", (snoozed ?: task).toJson())
        }
    }

    private fun JsonObject.task(): SnoozeState {
        val task = field("task").jsonObject
        return SnoozeState(
            startAtMillis = task.field("startAt").jsonPrimitive.long,
            completed = task.field("completed").jsonPrimitive.boolean,
            snoozeMinutes = task.field("snoozeMinutes").jsonPrimitive.int,
            maxSnoozes = task.nullable("maxSnoozes")?.int,
            snoozeCount = task.field("snoozeCount").jsonPrimitive.int,
            snoozedUntilMillis = task.nullable("snoozedUntil")?.long,
        )
    }

    private fun SnoozeState.toJson(): JsonObject = buildJsonObject {
        put("startAt", startAtMillis)
        put("completed", completed)
        put("snoozeMinutes", snoozeMinutes)
        put("maxSnoozes", maxSnoozes)
        put("snoozeCount", snoozeCount)
        put("snoozedUntil", snoozedUntilMillis)
    }

    private fun JsonObject.string(key: String): String = field(key).jsonPrimitive.content
    private fun JsonObject.number(key: String): Double = field(key).jsonPrimitive.double
    private fun JsonObject.nullable(key: String): JsonPrimitive? =
        (get(key) as? JsonPrimitive)?.takeUnless { it is JsonNull }

    private fun JsonObject.field(key: String): JsonElement =
        get(key) ?: throw IllegalArgumentException("Missing '$key'")
}
