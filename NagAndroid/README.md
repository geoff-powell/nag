# Nag for Android

Nag uses Compose Multiplatform and Material 3, with dynamic color on Android 12 and later. The phone layout opens a nag in its own screen. Wider windows show the list beside the selected nag.

## Build and run

Use JDK 21 and the Android SDK with platform 36. Set `ANDROID_HOME` or configure the SDK path in Android Studio. Open `NagAndroid` in Android Studio, or run the following from that directory.

```sh
./gradlew :core:jvmTest :app:lintDebug :app:assembleDebug
./gradlew :app:installDebug
adb shell am start -n dev.nag.android/.MainActivity
```

On Windows, use `gradlew.bat`. The app supports Android 8.0 (API 26) and later.

Android’s version name comes from `MARKETING_VERSION` in [Config/Base.xcconfig](../Config/Base.xcconfig), the same source as iOS and macOS. For Android uploads, pass an increasing Android build number with `-PnagAndroidVersionCode=123`. Local builds default to 1.

Open **Settings** to give Nag notification access. On Android 12 and later, allow exact alarms there if you want precise timing. Android may delay reminders when exact alarms are unavailable, and its idle-mode limits still apply. Quiet hours defer delivery until the local end time. Android restores reminder scheduling after reboot and package updates.

Add **Nag** from the launcher’s widget picker to see up to three open nags. Tap a title to open the nag. The Android share sheet can send text to Nag or share a nag as a `nag://add` link.

To check background actions, create a nag due now, return to the launcher, and tap **Snooze**, **Start**, or **Done** on its notification. Reopen the app and check the updated task. Use separate due nags to check each action.

## UX parity

The Android list follows the Now, Coming up, Done, and Archived sections used on iOS and macOS. A snoozed or started nag stays in Now. Completing a repeat advances its schedule. The completed occurrence stays in Done for the local day unless the next occurrence is already due.

Android uses checkboxes for completion and reopening, a snackbar for in-app Undo, and a More menu for archive, restore, duplicate, and delete. The editor uses Material 3 date and time pickers, and the in-app Snooze menu offers 5 minutes, 15 minutes, and 1 hour. The notification Snooze action uses the nag's configured duration.

## Shared core and iOS gaps

- `core/src/commonMain` owns recurrence, completion, work sessions, snooze limits, escalation and quiet hours. The app and notification receiver use those same rules. The module currently builds a JVM target for Android and its tests. Swift and .NET integration and cross-client conformance remain part of [issue #41](https://github.com/geoff-powell/nag/issues/41).
- Android keeps nags and quiet hours on the device. iCloud sync, NFC/QR proof, and step-count unlocks are outside the Android scope.
- Android accepts the Nag list, editor, detail and add routes, including source/ID updates. The lock and unlock routes open the Locks screen. The scan route shows an availability message. Android uses notification settings in place of the iOS Focus override and has no AlarmKit equivalent in this implementation.
- The custom schedule editor supports independent weekdays for each time. Nag links can carry one weekday set, so sharing a schedule with different weekdays for different times is unavailable. Android has in-app completion undo and archiving. Live Activities, Shortcuts, and the Apple completion history are unavailable.
- Recurrence uses local wall-clock time. The Kotlin date-time library chooses the earlier instant for an ambiguous local time and shifts nonexistent times forward by the DST gap. Cross-client DST parity still needs fixtures.

## App locks

| Android mechanism | What it supports and what constrains it |
| --- | --- |
| UsageStats | User-granted usage access can reveal usage events. It gives Nag no API to suspend another app. Usage history is sensitive and would need a clearly disclosed purpose. [Android UsageStatsManager](https://developer.android.com/reference/android/app/usage/UsageStatsManager) |
| Application overlay | A user-granted draw-over-other-apps permission can cover parts of another app with a Nag window. Android restricts overlay interaction, and apps can hide overlays. The overlay itself supplies no package suspension. Any implementation must meet Play's deceptive behavior rules. [Android overlay permission](https://developer.android.com/reference/android/Manifest.permission#SYSTEM_ALERT_WINDOW) · [Play deceptive behavior policy](https://support.google.com/googleplay/android-developer/answer/17006354) |
| Accessibility service | A user-enabled service can observe window changes and perform limited UI actions. Play requires narrower APIs where available, a declaration, and prominent disclosure and affirmative consent for apps outside the accessibility-tool designation. Play also restricts bypassing security controls and preventing users from disabling or uninstalling apps. [Play AccessibilityService policy](https://support.google.com/googleplay/android-developer/answer/10964491) |

On personal phones, **Locks** opens Android Settings and explains how to pause apps in Digital Wellbeing’s Focus mode. The user turns Focus mode on and off in system settings.

For managed devices and profiles where Nag is already provisioned as owner, **Managed app lock** suspends the selected apps for the current Android user. Choose **Turn off lock** to restore them. Android exempts some system apps, and a work-profile lock covers only apps in that profile. An active lock keeps its restoration list across restarts. This is a manual lock. Apple’s automatic schedules and nag-based unlock requirements remain platform gaps. [Android package suspension API](https://developer.android.com/reference/android/app/admin/DevicePolicyManager#setPackagesSuspended(android.content.ComponentName,%20java.lang.String%5B%5D,%20boolean))

To test device-owner mode, install the APK on a disposable emulator with no accounts or other users, then run `adb shell dpm set-device-owner dev.nag.android/.NagDeviceAdmin`. In Nag, select a nonessential app under **Locks**, turn on the lock, and confirm that Android blocks the app launch. Turn off the lock and confirm it opens again.
