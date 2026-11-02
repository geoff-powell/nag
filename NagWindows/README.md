# Nag for Windows

A standalone native Windows app built with C# and Windows Forms on .NET 10. No administrator access or third-party runtime packages are required. This is an initial Windows implementation, not full feature parity with the Apple apps.

## Run

Extract `Nag-win-x64.zip` and open `Nag.exe`. The portable download includes .NET. Keep the app in a stable folder before enabling **Settings → Enable open at login**. Code signing and an installer are not configured.

Create nags with a title, notes, start time, repeat, escalation and snooze allowance. Supported repeats: once, daily, weekdays and weekly. Completing repeating nags skips missed occurrences and retains the scheduled local time. Future repeating nags cannot be completed early. Reopen finished one-off nags from the Done filter.

Closing the window keeps Nag in the notification area. Right-click its tray icon to open, add a nag or quit. A small always-on-top panel keeps due nags visible. Quiet hours suppress notifications and the panel, including across midnight; equal start/end hours disable the quiet interval, matching NagCore. Windows Do not disturb can silence notification balloons; Nag cannot bypass it. Nag must be running and the user logged in; it does not wake a sleeping PC.

App locks target selected `.exe` paths, either for a timer or while any nag is due. Snoozing does not clear an outstanding nag. Nag minimizes matching foreground apps without terminating them or discarding work, checking every two seconds. Emergency unlock suspends a lock for five minutes. You can disable locks or quit Nag. Windows system apps and Nag itself cannot be selected. Elevated apps that cannot be inspected, packaged apps without an accessible executable, websites and other Windows sessions are not covered. This is a voluntary focus aid, not a security boundary.

## Data and isolation

Windows owns a separate versioned JSON store at `%LOCALAPPDATA%\Nag\windows-state.json`. Writes use flushed temporary files and atomic replacement; the previous successful store is retained as `.bak`. Changed in-memory state is published only after saving successfully. A per-store mutex prevents ordinary duplicate instances. Do not share a custom directory between Windows accounts or edit it while Nag is running.

Invalid stores cause an error and exit without replacement. To recover, quit Nag, preserve the damaged file, inspect the backup and copy it to `windows-state.json`. There is no silent reset. Reminder text is personal data; protect it with your Windows account permissions.

Set `NAG_WINDOWS_HOME` to select a different directory. Login changes are disabled with this override. For a disposable demo with app enforcement and login changes disabled:

```powershell
$env:NAG_WINDOWS_HOME = Join-Path $env:TEMP ('nag-demo-' + [guid]::NewGuid())
.\Nag.exe --demo
```

Use a fresh demo directory; interactions persist there. `--background` starts normally in the tray.

iCloud sync, remote MCP, NFC/QR proof, step counts, custom/monthly/every-N-days repeats, strict termination and scheduled lock windows are not implemented. Windows never accesses the Swift shared store.

## Build and verify

Install the .NET 10 SDK on Windows and run from the repository root:

```powershell
dotnet build NagWindows/Nag.Windows -c Release
dotnet run --project NagWindows/Nag.Core.Tests -c Release
dotnet run --project NagWindows/Nag.Windows.Tests -c Release
# Optional foreground-app check on an interactive desktop:
dotnet run --project NagWindows/Nag.Windows.Tests -c Release -- --integration
./NagWindows/build.ps1
# Optional ARM64 build; verify on ARM64 hardware:
./NagWindows/build.ps1 -Runtime win-arm64
```

Artifacts: `build/Nag-win-x64/Nag.exe` and `build/Nag-win-x64.zip`. Packaging downloads .NET runtime packs if needed. Building does not install a service, login task, protocol handler or firewall rule. The Windows CI workflow runs checks and uploads the portable app.

`Nag.Core` owns scheduling, snoozing, quiet hours, lock activation and storage. `Nag.Windows` owns forms, the timer, tray and foreground app minimization. Dependency-free executable test projects cover core rules and actual form-control interactions with disposable stores. UI checks write control-rendered images to `build/windows-evidence`, logging actual dimensions when the runner constrains window size. These are not desktop screenshots.

Before distribution, check the packaged app on a normal Windows desktop at 100%, 150% and 200% scaling, wide and narrow windows, multiple monitors, keyboard navigation, notification delivery, tray restore/quit, suspend/resume, login behavior, and app minimization using a disposable app. Verify emergency unlock and timer expiry. Model tests and control rendering do not prove those OS integrations.

See [VERIFICATION.md](VERIFICATION.md) for actual local results and outstanding checks.
