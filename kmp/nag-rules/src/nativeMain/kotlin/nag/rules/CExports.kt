@file:OptIn(ExperimentalForeignApi::class, ExperimentalNativeApi::class)

package nag.rules

import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.CPointer
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.allocArray
import kotlinx.cinterop.nativeHeap
import kotlinx.cinterop.set
import kotlinx.cinterop.toKString
import kotlin.experimental.ExperimentalNativeApi

/*
 * Plain C entry points for the shared library (nagrules.dll / libnagrules.dylib).
 *
 * Contract:
 * - nag_eval takes a NUL-terminated UTF-8 JSON request and returns a NUL-terminated UTF-8 JSON
 *   response that the caller owns and must release with nag_free. It never returns NULL.
 * - Errors are reported in the response ({"ok": false, ...}); no Kotlin exception crosses the ABI.
 * - Calls are stateless and may be made from any thread; Kotlin/Native attaches the calling thread.
 */

@CName("nag_eval")
fun nagEval(request: CPointer<ByteVar>?): CPointer<ByteVar> {
    val response = if (request == null) {
        """{"ok":false,"error":"request is NULL"}"""
    } else {
        RulesBridge.evaluate(request.toKString())
    }
    return response.toCString()
}

@CName("nag_free")
fun nagFree(response: CPointer<ByteVar>?) {
    if (response != null) nativeHeap.free(response.rawValue)
}

private fun String.toCString(): CPointer<ByteVar> {
    val bytes = encodeToByteArray()
    val buffer = nativeHeap.allocArray<ByteVar>(bytes.size + 1)
    bytes.forEachIndexed { index, byte -> buffer[index] = byte }
    buffer[bytes.size] = 0
    return buffer
}
