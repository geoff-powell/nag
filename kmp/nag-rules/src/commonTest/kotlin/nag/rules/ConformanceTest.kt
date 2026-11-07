package nag.rules

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/** Runs Fixtures/conformance against the prototype through the JSON bridge, on every target. */
class ConformanceTest {
    private val platform = "kotlin"

    @Test
    fun escalationFixtures() = run("escalation")

    @Test
    fun snoozeFixtures() = run("snooze")

    private fun run(file: String) {
        val root = Json.parseToJsonElement(conformanceFixtures.getValue(file)).jsonObject
        assertEquals(1, root.getValue("schema").jsonPrimitive.int)
        val cases = root.getValue("cases").jsonArray.map { it.jsonObject }
        assertTrue(cases.isNotEmpty())
        val failures = cases.filter { (it["skip"] as? JsonObject)?.get(platform) == null }.mapNotNull { fixture ->
            val name = fixture.getValue("name").jsonPrimitive.content
            val expected = ((fixture["overrides"] as? JsonObject)?.get(platform) as? JsonObject)
                ?.getValue("expect") ?: fixture.getValue("expect")
            val response = Json.parseToJsonElement(RulesBridge.evaluate(fixture.getValue("input").toString())).jsonObject
            if (!response.getValue("ok").jsonPrimitive.boolean) return@mapNotNull "$name: ${response["error"]}"
            val problems = mutableListOf<String>()
            compare("", expected, response.getValue("result"), problems)
            problems.takeIf { it.isNotEmpty() }?.let { "$name: ${it.joinToString("; ")}" }
        }
        if (failures.isNotEmpty()) fail(failures.joinToString("\n"))
    }

    private fun compare(path: String, expected: JsonElement, actual: JsonElement?, problems: MutableList<String>) {
        when {
            expected is JsonObject -> {
                if (actual !is JsonObject) return run { problems += "$path: expected object, got $actual" }
                for ((key, value) in expected) compare(if (path.isEmpty()) key else "$path.$key", value, actual[key], problems)
            }
            expected is JsonNull || actual == null || actual is JsonNull ->
                if (expected != (actual ?: JsonNull)) problems += "$path: expected $expected, got $actual"
            expected is JsonPrimitive && !expected.isString && expected.content.toDoubleOrNull() != null -> {
                val e = expected.double
                val a = (actual as? JsonPrimitive)?.content?.toDoubleOrNull()
                if (a == null || abs(e - a) > 1e-9) problems += "$path: expected $e, got $actual"
            }
            expected != actual -> problems += "$path: expected $expected, got $actual"
        }
    }
}
