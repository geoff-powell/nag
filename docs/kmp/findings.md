# KMP spike findings: escalation and snooze (#41, phases 0–2)

Status: first pass of the spike. The architecture decision record (ADR) and
the migration and rollback plan are deferred to phase 3; the ADR's
recommendation will be "adopt selectively", "defer", or "keep native cores
with shared conformance tests". This page records what was built and measured
so far.

The rule comparison that motivated this work is in
[rule-inventory.md](rule-inventory.md).

## What was built

| Piece | Path | Purpose |
|---|---|---|
| Conformance fixtures | `Fixtures/conformance/{escalation,snooze}.json` | 32 cases, language-neutral. Times are epoch milliseconds and durations are seconds or minutes, so no time zone is involved. Known platform differences are listed per case as `overrides`, and cases a platform can't express as `skip`. |
| Swift runner | `Packages/NagKit/Tests/NagCoreTests/ConformanceTests.swift` | Runs the fixtures against `NagCore`, the reference implementation. Part of `swift test`. |
| C# runner | `NagWindows/Nag.Core.Tests/ConformanceRunner.cs`, `NagCoreEvaluator.cs` | Runs the fixtures against `Nag.Core`. Part of `Nag.Core.Tests`, which now has 20 checks. |
| KMP library | `kmp/nag-rules` | Kotlin 2.4.21 and Gradle 9.7.1. `Escalation`, `SnoozeState`, and a JSON bridge called `RulesBridge`. Targets: `jvm`, `macosArm64`, `iosArm64`, `iosSimulatorArm64`, `mingwX64`. About 340 lines including tests. |
| C ABI | `kmp/nag-rules/src/nativeMain/.../CExports.kt` | `nag_eval(const char*) -> char*` and `nag_free(char*)`. Requests and responses are UTF-8 JSON; errors come back inside the response. |
| Swift consumer | `kmp/consumers/swift` | A SwiftPM executable that uses `NagRules.xcframework` (a static framework). It runs the fixtures through the typed API, then compares the prototype with `NagCore` on 40,000 seeded random inputs. |
| .NET consumer | `kmp/consumers/dotnet` | A .NET 10 console app that calls `nagrules` through `[LibraryImport]`. It runs the same fixtures with the C# runner, then checks errors, UTF-8, threads, and memory. |
| CI | `.github/workflows/kmp-spike.yml` | Jobs for macOS, Windows x64 (native build), Windows x64 (DLL cross-compiled on macOS), and Windows ARM64. |

## Behaviour parity

| Implementation | Fixture result | Notes |
|---|---|---|
| Swift `NagCore` | 32/32 | Reference. |
| C# `Nag.Core` | 30 match, 1 recorded difference, 2 skipped | The difference: C# won't snooze a nag that is already snoozed. Skipped: base intervals under a minute, and unlimited snoozes, which C# can't represent. `nextTighteningSeconds` is not compared because C# has no equivalent. |
| KMP on JVM, macOS, iOS simulator, mingwX64 | 32/32 on each target | The common tests use the same fixtures, embedded at build time. |
| KMP called from Swift (typed API) | 32/32, and 40,000 random inputs identical to `NagCore` | Exact equality, including fractional seconds: both sides use the platform's `pow`. |
| KMP called from .NET (C ABI) | 32/32 on macOS arm64, Windows x64, and Windows ARM64 (x64 emulation) | |

To confirm the runners actually catch problems, I changed one expected value
in the fixtures on purpose. The Swift runner and the Kotlin runner both failed.

## Interop matrix

✅ means verified on real hardware in CI or on a local Mac. ⚠️ means
verified, but with a caveat. ❌ means it doesn't work. "Untested" means not
attempted in this spike.

| Path | Status | Evidence |
|---|---|---|
| Kotlin → macOS arm64 framework → Swift | ✅ | Local run and CI `apple` job |
| Kotlin → iOS simulator arm64 | ✅ tests run | `iosSimulatorArm64Test`, locally and in CI |
| Kotlin → iOS device arm64 | ⚠️ builds only | The `ios-arm64` slice of the XCFramework links. Not run on a device. |
| XCFramework inside the Nag Xcode project (app plus widget, intents and shield extensions) | Untested | Only a SwiftPM executable consumed it. |
| Kotlin → `mingwX64` DLL built on a Windows host → .NET x64 | ✅ | CI `windows` job |
| Kotlin → `mingwX64` DLL cross-compiled on macOS → .NET x64 on Windows | ✅ | CI `windows-cross` job. One Mac can build every artifact. |
| `mingwX64` tests on Windows | ✅ | `mingwX64Test` runs on `windows-latest` (it is skipped on macOS) |
| Native win-arm64 process loading the DLL | ❌ | Fails with `BadImageFormatException`. Kotlin/Native has no Windows ARM64 target (see [supported targets](https://kotlinlang.org/docs/native-target-support.html)). |
| x64 process under emulation on Windows ARM64 | ✅ | CI `windows-arm64` job: a self-contained `win-x64` publish passes every check |
| Kotlin → macOS dylib → .NET osx-arm64 | ✅ | Used to check the C ABI locally before running on Windows |
| JVM target | ✅ tests | `jvmTest`. This is the path an Android client (#56) would use: the same `commonMain` code with no bridge. |
| JVM hosted from .NET (for example IKVM), or a JNI bridge | Untested | Possible fallback for win-arm64; not attempted |
| Swift export (experimental) instead of the Objective-C header | Untested | Could fix the Swift API problems listed below |
| C# NativeAOT consumer, WinForms UI thread | Untested | Calls from the thread pool were tested (8 threads) |

## Measurements

These come from CI run 42400175147 with an empty cache, and from an Apple
Silicon Mac. Treat them as rough figures from a single run.

| Item | Value |
|---|---|
| `nagrules.dll` (mingwX64, release) | 2.1 MB. It imports only `KERNEL32.dll` and `msvcrt.dll`, so no MinGW runtime DLLs need to ship with it. |
| `libnagrules.dylib` (macOS) | 2.1 MB |
| `NagRules.xcframework`, static, 3 slices | 14–15 MB on disk, about 5 MB of static archive per slice before linking |
| Swift consumer executable, which also contains `NagCore` | 3.9 MB, of which 1.7 MB is `__text` |
| First C ABI call, including library load and .NET JIT | 5–10 ms (Windows x64, macOS); 50 ms under x64 emulation on ARM64 |
| Later calls (JSON in and out) | 5 µs (local Mac), 16 µs (CI macOS), 20–22 µs (Windows x64), 40 µs (emulated) |
| 100,000 `nag_eval`/`nag_free` pairs | Working set changed by between −1.5 MB and +29 MB, which is under the 64 MB limit the check allows. Each run takes only one measurement, so this is a rough guard against leaks, not a soak test. |
| CI, macOS: Kotlin tests on 3 targets | 147 s (cold) |
| CI, macOS: XCFramework + dylib + cross-compiled DLL | 76 s (cold) |
| CI, Windows: JVM and mingwX64 tests | 136 s (cold) |
| CI, Windows: release DLL | 37 s |
| Local, incremental: all release binaries | about 20 s |
| Kotlin/Native toolchain on a developer machine | 2.2 GB (`~/.konan`: 1.1 GB compiler, 1.1 GB dependencies). The first native build downloaded it and compiled in about 5 minutes. |
| Code this spike added | About 340 lines of Kotlin; about 620 lines of runners and consumers in Swift and C# |

## API and bridge findings

**Swift, through the Objective-C header Kotlin generates.** It works, but it
doesn't read like native Swift:
- A Kotlin `enum` becomes a class with static members, so Swift can't `switch`
  over it exhaustively.
- Nullable primitives are boxed: `Int?` becomes `KotlinInt?` and `Long?`
  becomes `KotlinLong?`. Callers write `KotlinInt(int:)` and `.int64Value`.
- A property named `completed` clashed with a method named `completed()`.
  Kotlin renamed the getter to `completed_`. I renamed the method to
  `complete()` to avoid it.
- A function that took a kotlinx-serialization `JsonObject` appeared in the
  public Swift API until I made it `internal`. Every public Kotlin type
  becomes part of the Swift API, so the module boundary needs to stay small.
- KDoc comments were copied onto the generated `isEqual`, `hash` and
  `description` members.
- Exceptions: a Kotlin function without `@Throws` that throws will crash the
  Swift caller. `Escalation.parse` can throw, so production code would need
  `@Throws` or a function that returns null instead.

**The C ABI for .NET**
- `@CName` plus JSON strings keeps the ABI to two functions with clear memory
  ownership: the caller frees the response with `nag_free`.
- The JSON bridge catches all exceptions, so nothing can unwind across the C
  boundary. Invalid JSON, an unknown operation, a NULL request and non-ASCII
  input all produce an error response.
- Threads: Kotlin/Native attaches each calling thread to its runtime. 8,000
  calls from 8 threads all returned the same result.
- There is no direct C# binding. Every field the Windows client needs would go
  through hand-written JSON mapping on both sides, or through a code generator
  we would have to build.
- The generated `nagrules_api.h` also exports a struct of function pointers
  for the whole Kotlin API. The .NET consumer doesn't use it, and compiling the
  C++ glue for it produces `-Wc99-designator` warnings that we can't fix.

**Toolchain**
- Kotlin 2.4.21 supports Gradle up to 9.7.0. Gradle 9.7.1 worked.
- `kotlin.native.ignoreDisabledTargets=true` lets the Windows runner configure
  the project even though Apple targets can't be built there.
- `mingwX64` is a **Tier 3** target: JetBrains doesn't guarantee it is tested
  in their CI or that it stays compatible between releases. The Apple targets
  used here are Tier 1.

## Risks to weigh in the ADR

1. **Windows ARM64.** There is no native target. The options are:
   - ship the whole Windows client as x64 and rely on emulation (verified to
     work, but slower to start and not native);
   - host the JVM target from .NET (untested);
   - keep `Nag.Core` in C# and hold it to the shared fixtures.

   Today `build.ps1` publishes a native `win-arm64` build.
2. **mingwX64 is Tier 3.** A Kotlin upgrade could break the Windows build, and
   JetBrains wouldn't treat that as a regression.
3. **Swift API quality.** Without Swift export or a hand-written Swift wrapper,
   the Apple apps would call through boxed types and enum classes. A wrapper
   adds back some of the code that sharing was meant to remove.
4. **App extensions.** Nag has several extensions. A static framework copies
   the Kotlin runtime (about 2 MB) into every target that links it. A dynamic
   framework avoids the copies but adds its own embedding and loading work.
   Neither was measured in the real Xcode project.
5. **Toolchain cost.** Every developer and every CI runner needs a JDK, Gradle
   and the 2.2 GB Kotlin/Native toolchain. With an empty cache, the Kotlin
   steps took about 3.7 minutes on macOS and 2.9 minutes on Windows in CI.

## In favour of sharing

- The fixtures plus the Swift differential check show that the rules can be
  ported exactly, and that one Kotlin implementation can run on every target.
- Android (#56) would use the Kotlin code directly with no bridge. With three
  clients (Apple, Windows, Android), sharing removes more duplicate code than
  with two.
- The fixture approach is useful whatever the decision. It already found and
  pinned down a real difference between Swift and C# (snoozing while snoozed)
  at no extra cost. It also works without KMP: if the ADR chooses to keep
  native cores, these fixtures become the parity test.

## Next steps (phase 3)

- Write the ADR in `docs/adr/0001-kmp-shared-core.md` and decide between:
  - adopting KMP selectively, for example for the Android client plus Apple;
  - deferring;
  - keeping native cores and growing the fixtures.
- Decide whether Swift and C# should agree on snoozing while already snoozed,
  then update the fixture `overrides`.
- Extend the fixtures to time-dependent rules: recurrence, quiet hours, DST
  gaps and overlaps, and IANA time zones (in Kotlin, via `kotlinx-datetime`).
  Neither existing core tests these today.
- If adopting: link the XCFramework into the Nag app and one extension, and
  measure binary size and launch time. Also try Swift export, and test a call
  from the WinForms UI thread.
- Write the phased migration and rollback plan. Swift models stay
  authoritative and the JSON storage formats stay unchanged, so no storage
  migration is needed to start.

## How to reproduce

```sh
swift test --package-path Packages/NagKit --filter ConformanceTests
dotnet run --project NagWindows/Nag.Core.Tests -c Release
(cd kmp && ./gradlew :nag-rules:allTests :nag-rules:linkReleaseSharedMacosArm64)
./kmp/consumers/swift/run.sh
dotnet run --project kmp/consumers/dotnet -c Release   # set NAGRULES_LIB to use another library
```
