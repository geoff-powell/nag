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
builds without approval. Shipping through TestFlight needs Apple's approval first; see
[Releasing](#releasing).

### Simulator vs device

Screen Time (choosing apps, shields, DeviceActivity) and NFC only work on a **real iPhone**. Nags,
editing, notifications and the unlock flow work in the simulator, which is fine for UI work.

### Tests

```sh
cd Packages/NagKit && swift test
```

The scheduling, escalation, quiet hours, unlock and sync rules all live in `NagCore` and are covered
there. The Tests workflow runs them and builds both apps on every push to `main`.

`NagUITests` drives the iPhone app end to end in the simulator: creating, editing, completing,
snoozing, reopening, duplicating and deleting nags. The app launches with a seeded throwaway store
(see `Nag/App/UITesting.swift`), so the tests never touch your real nags or iCloud.

```sh
xcodebuild test -scheme Nag -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

To review animations, `scripts/record-ui.sh` records each UI test as an MP4 (60 fps, for frame-by-frame
review) and a GIF in `build/ui-recordings`. Pass test names to record only those.

## Releasing

### iPhone: TestFlight

One-time setup:

1. In [App Store Connect](https://appstoreconnect.apple.com), go to **Apps → + → New App**. Choose
   iOS, pick the bundle ID `com.greenmiststudios.nag`, and give it a name that isn't taken
   (the name can differ from "Nag" on the home screen).
2. [Request Family Controls distribution](https://developer.apple.com/contact/request/family-controls-distribution)
   for all four bundle IDs: the app plus `.monitor`, `.shield-config` and `.shield-action`.
   Apple reviews this by hand and can take a few weeks. **Uploads fail until it's approved.**

Then, for each build:

```sh
scripts/testflight.sh            # archive and upload
scripts/testflight.sh --dry-run  # archive and export locally, no upload
```

Every run gets a new build number automatically. After processing, add testers in App Store
Connect → TestFlight.

### Mac: notarized download

TestFlight for Mac only accepts sandboxed apps, and a sandboxed app can't hide or quit other apps.
So the Mac app ships as a Developer ID–signed, notarized zip attached to a GitHub release.

One-time setup, on the Mac you release from (it must have run NagMac from Xcode once, which
registers it):

```sh
xcrun notarytool store-credentials nag-notary --apple-id YOU@EXAMPLE.COM --team-id EY47F36LGH
```

It asks for an app-specific password, which you create at
[account.apple.com](https://account.apple.com) → Sign-In and Security → App-Specific Passwords.

Then:

```sh
scripts/release-mac.sh            # archive, notarize, staple, create a GitHub release
scripts/release-mac.sh --dry-run  # archive and export only
```

Set `NAG_GITHUB_USER=geoff-powell` if more than one GitHub account is signed in to `gh`.

### Deploying from GitHub Actions

Two workflows:

- **Tests** (`.github/workflows/tests.yml`) runs the unit tests and builds both apps on every push to
  `main` and every pull request.
- **Deploy** (`.github/workflows/deploy.yml`) uploads the iPhone app to TestFlight, notarizes the
  Mac app, and publishes one GitHub release for the deploy. The release is tagged
  `v<version>-<build>`, has the Mac zip attached, and has notes generated from the merged pull
  requests. Both apps share the build number. Deploy runs automatically after every merge to
  `main`, once Tests passes for that commit. You can also start it from **Actions → Deploy → Run
  workflow** (pick iPhone, Mac or both), or push a tag like `v1.0` to deploy both under that tag.
  Manual and tag deploys run the tests first.

CI can't sign in to Xcode, so Deploy needs these repository secrets. Set them once with `gh`
from this folder, signed in as the repo owner (`gh auth switch --user geoff-powell`).

| Secret | What it is |
| --- | --- |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | App Store Connect issuer ID |
| `ASC_KEY_P8_BASE64` | The API key's `.p8` file, base64 encoded |
| `SIGNING_CERTS_P12_BASE64` | Your Apple Development and Developer ID Application certificates in one `.p12`, base64 encoded |
| `SIGNING_CERTS_P12_PASSWORD` | The password you gave that `.p12` |
| `MAC_PROFILE_BASE64` | Developer ID provisioning profile for the Mac app, base64 encoded (Mac deploys only) |

**1. API key.** In [App Store Connect](https://appstoreconnect.apple.com) go to **Users and Access →
Integrations → App Store Connect API → Team Keys → +**. Give it the **Admin** role, which Xcode needs
to manage signing. Download the `.p8` (you only get one chance), then:

```sh
gh secret set ASC_KEY_ID          # paste the Key ID
gh secret set ASC_ISSUER_ID       # paste the Issuer ID shown above the keys list
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set ASC_KEY_P8_BASE64
```

**2. Certificates.** In Xcode, open **Settings → Accounts**, select your team, then **Manage
Certificates → + → Developer ID Application**. In **Keychain Access → My Certificates**, select both
*Apple Development: …* and *Developer ID Application: …*, then **File → Export Items** as a `.p12`
with a password:

```sh
base64 -i Certificates.p12 | gh secret set SIGNING_CERTS_P12_BASE64
gh secret set SIGNING_CERTS_P12_PASSWORD
```

Delete the `.p12` afterwards; it contains your private keys.

**3. Mac provisioning profile.** At [developer.apple.com](https://developer.apple.com/account/resources/profiles/list),
go to **Profiles → +** and choose **Developer ID** (macOS). Pick the App ID
`com.greenmiststudios.nag.mac` and your Developer ID certificate, and name it something like
*Nag Mac Developer ID*. Download it, then:

```sh
base64 -i Nag_Mac_Developer_ID.provisionprofile | gh secret set MAC_PROFILE_BASE64
```

If the App ID isn't listed, run the NagMac scheme from Xcode once on your Mac, which registers it.
The profile expires after a few years. Make a new one and update the secret when it does.

Deploy checks for missing secrets first, on a cheap Linux runner. A platform whose secrets are
missing is skipped and the run fails with their names, but the other platform still ships and gets
its release. iPhone deploys also need the Family Controls distribution approval described above.
Mac deploys don't.

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

## Adding nags from other apps

Other apps can hand Nag a nag in two ways. Both record a **source** (shown on the nag) and, optionally,
the source's **ID** for the item. Sending the same source and ID again updates that nag instead of
adding a duplicate, and a finished one-off nag that's been moved (a rescheduled event, say) nags again.

**Shortcuts and Siri.** The *Create Nag* action takes a title, notes, start, repeat, interval, source,
source ID and link, and adds the nag straight away. That's the bridge to most other apps:

- Calendar: a Shortcuts automation that runs *Find Calendar Events*, then *Create Nag* for each, with
  something stable about the event (its title, say) as the source ID.
- Notes, Safari and anything with a share sheet: a shortcut that shows in the share sheet and passes
  the shared text to *Create Nag*.
- AI assistants: Siri and Apple Intelligence can run the action. On the Mac, an assistant that can run
  shell commands can use `shortcuts run "<your Create Nag shortcut>"`.

**`nag://add` links.** Anything that can open a URL: a link in Notes, a Calendar event's URL field, a
Muse card, a script or an AI assistant. A link opens the editor filled in, so nothing is added until
you tap Save.

```
nag://add?title=Reply+to+Sam&at=2026-10-30T09:00&repeat=weekdays&source=Muse&id=card-42&link=https%3A%2F%2F…
```

| Parameter | Meaning |
|---|---|
| `title` | Required. What to do. |
| `notes` | Extra detail. |
| `at` | When nagging starts: ISO 8601 (`2026-10-30T09:00:00Z`), local (`2026-10-30T09:00`), a date (9 AM) or a time (`17:30`, next time it comes round). |
| `in` | Start after a delay: `30m`, `2h`, `1h30m`, `1d`. Ignored when `at` is set. |
| `repeat` | `once`, `daily`, `weekdays`, `weekly` or `custom`. |
| `times`, `days` | A custom schedule: `times=09:00,21:00&days=mon,wed,fri` (`days` also takes `weekdays`, `weekends`, `daily`). |
| `every` | Minutes between nags. |
| `escalation` | `steady`, `gentle` or `relentless`. |
| `snooze`, `snoozes` | Snooze length in minutes, and how many per occurrence (or `unlimited`). |
| `focus` | `true` or `false`: break through Focus. |
| `source`, `id` | Who sent it, and their ID for the item. |
| `link` | A URL that opens the original item, shown on the nag. |

The parsing and update rules live in NagCore (`NagRequest`, `NagLink`) and are unit tested.

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
- A nag you delete comes back if its source sends the same item again, for example on the next run
  of a Shortcuts automation.
