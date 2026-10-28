# Nag

Reminders that don't give up, plus app locks like [Brick](https://getbrick.app). Built for ADHD brains
that forget things the moment they leave the screen.

- **Nags** keep reminding you until something is actually done. They come more often the longer it
  waits, snoozes are limited, and the wording gets pushier. Nags can need a physical key scanned to
  finish (an NFC sticker on the pill bottle, say).
- **Locks** block the apps you choose until you've earned them back: finish specific nags, clear
  everything that's due, scan a key, walk some steps, wait out a timer, or type out a commitment.
  Locks switch on by hand, on a schedule, or automatically whenever a nag is due.
- **iPhone and Mac.** The iPhone uses Screen Time to block apps. The Mac app lives in the menu bar,
  hides or quits blocked apps, and keeps a reminder panel on screen while anything is due. Nags sync
  between them through iCloud.

## Setup

1. Open `Config/Signing.xcconfig` and set:
   - `DEVELOPMENT_TEAM` to your Team ID
   - `NAG_BUNDLE_ID` to something unique, e.g. `com.yourname.nag`
2. Open `Nag.xcodeproj`. Signing is automatic. Xcode registers the app group
   (`group.<NAG_BUNDLE_ID>`) and the iCloud key-value store for you.
3. Run the **Nag** scheme on an iPhone, and **NagMac** on your Mac.

You need a **paid Apple Developer account**. Family Controls (Screen Time), app groups, Time Sensitive
notifications, NFC and iCloud all need one. The Family Controls entitlement works for development
builds without approval. Before you can ship to TestFlight or the App Store, request the
[distribution entitlement](https://developer.apple.com/contact/request/family-controls-distribution)
for the app and all three extensions.

### Simulator vs device

Screen Time (choosing apps, shields, DeviceActivity) and NFC only work on a **real iPhone**. Nags,
editing, notifications and the unlock flow work in the simulator, which is fine for UI work.

### Tests

```sh
cd Packages/NagKit && swift test
```

The scheduling, escalation, quiet hours, unlock and sync rules all live in `NagCore` and are covered
there.

## How it works

```
Packages/NagKit
  NagCore    Plain Swift: models, nag planning, lock rules, unlock requirements,
             shared JSON store, iCloud merge. Fully unit tested.
  NagKit     Apple frameworks: notifications, iCloud sync, and on iOS the
             Screen Time glue (shields, DeviceActivity schedules, NagEngine).
Nag/              iPhone app (SwiftUI)
NagMonitor/       DeviceActivity monitor: wakes Nag in the background
NagShieldConfig/  The screen shown over a blocked app
NagShieldAction/  The buttons on that screen
NagMac/           Mac menu bar app
Config/           xcconfigs, Info.plists, entitlements
```

**Staying persistent with Nag closed.** On iPhone, a nag that's due gets a *repeating* notification
that keeps firing even if Nag never runs again. Future nags are planned along their escalation
curve, within iOS's limit of 64 pending notifications. To change the plan when things shift (a nag
starts, escalation steps up, quiet hours begin, a timed unlock ends), Nag registers DeviceActivity
schedules. iOS runs `NagMonitor` at those moments even when Nag isn't open, and the monitor re-syncs
shields and notifications.

**Locks on iPhone.** Each lock has its own named `ManagedSettingsStore`. Scheduled locks and timed
unlocks are DeviceActivity intervals, so they switch on and off with Nag closed. Tapping "Unlock in
Nag" on a shield sends a notification that opens that lock's unlock screen, because shields can't
open apps directly.

**Locks on Mac.** macOS doesn't offer Screen Time shields to third-party apps, so the Mac app enforces
locks itself. It watches app launches and activations, hides blocked apps (or quits them in strict
mode), and shows a lock panel saying what's left to do. A strict lock also stops Nag from quitting
normally. Turn on *Open at login* so locks survive a restart.

**Keys.** NFC tags are identified by their hardware ID, and codes by their contents. Only a SHA-256
hash is stored. Nag can print a fresh QR code for you, or use any barcode you already own.

**Sync.** Only nags sync, through iCloud key-value storage. Locks and keys are specific to each device
(app selections and NFC tags don't carry across). Edits merge last-writer-wins, except that a
completion is never lost to an older edit from the other device.

## Honest limits

Nag makes avoiding things harder, not impossible. That's deliberate: it's a tool you set up for
yourself.

- iPhone: you can switch off Nag's Screen Time access in Settings, which removes the locks. Strict
  mode stops apps from being deleted, but not that.
- Mac: Force Quit or Activity Monitor can still kill Nag. Open at login brings it back after a
  restart. Blocked apps are hidden rather than covered, and websites aren't blocked on the Mac.
- Emergency unlocks (3 a month by default) are the intended way out. Changing the allowance is
  blocked while a lock is on.
- Repeating notifications fire at a fixed interval. Escalation and quiet-hour changes happen when
  iOS wakes the monitor extension, which is usually on time but not to the second.
- If Screen Time access isn't granted and quiet hours are on, Nag uses one-off notifications only, so
  it never nags at night without a way to stop.
- Walk and key-scan requirements can only be met on the iPhone.
