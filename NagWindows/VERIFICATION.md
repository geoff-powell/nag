# Windows verification — 2026-11-02

Local environment: Windows x64, .NET SDK 10.0.403 installed under a disposable temporary SDK directory. No real reminder store, login setting or service was changed. Hermes WebUI was not modified. The Windows implementation is in a separate Nag checkout.

Commands (using the temporary SDK's `dotnet.exe`):

- `dotnet build NagWindows/Nag.Windows -c Release`: passes, zero warnings/errors.
- `dotnet run --project NagWindows/Nag.Core.Tests -c Release`: 20 checks pass. Covers the shared conformance fixtures in `Fixtures/conformance` (escalation and snooze, with recorded differences from Swift), recurrence, skipped occurrences, snooze allowance, completion reset, quiet hours, escalation, reminder wording, lock conditions, emergency/timer expiry, atomic persistence, backup, invalid mutations and corrupt-store refusal.
- `dotnet run --project NagWindows/Nag.Windows.Tests -c Release`: passes. Uses disposable stores and actual form controls to verify completion, snooze, filtering, reopening and editor creation, checking persisted state. Produces control-rendered images under `build/windows-evidence`.
- `./NagWindows/build.ps1 -Dotnet <temporary-sdk>/dotnet.exe`: produces the self-contained x64 executable and ZIP.
- The packaged `build/Nag-win-x64/Nag.exe --demo` launched with an isolated temporary store and without `DOTNET_ROOT` pointing at the temporary SDK. The smoke-test process was stopped afterward.

The normal WinForms window was also inspected through Windows accessibility and completion was invoked, with the updated list observed. Desktop screenshot capture was unavailable. The session restricts windows to 660×500 regardless of requested dimensions, so larger desktop layouts, normal title-bar appearance, DPI scaling and multiple monitors have not been visually verified. Generated images reflect that constrained session and are control renders, not desktop screenshots.

The optional `--integration` test launches a disposable executable and attempts to verify foreground app minimization without termination. Its target opened, but foreground activation was denied in this session, so the integration test fails at the foreground precondition. No claim of successful OS lock enforcement is made. Run it again on an interactive desktop. It does not target existing user apps.

Remaining manual checks: native notification delivery and Do not disturb behavior; persistent panel positioning; tray restore; actual foreground minimization; login enable/disable after placing the portable app in a stable folder; suspend/resume; wide/narrow layouts on a normal desktop; keyboard navigation and scaling. ARM64 packaging/hardware, signing, installer and hosted CI execution are unverified. Existing Swift/iOS/macOS tests were not run on Windows; their source is untouched.
