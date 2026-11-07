#!/bin/sh
# Builds the NagRules XCFramework and runs the Swift consumer against it (#41 spike).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
kmp="$here/../.."
(cd "$kmp" && ./gradlew --console=plain -q :nag-rules:assembleNagRulesReleaseXCFramework)
# SwiftPM binary targets must live inside the package.
rm -rf "$here/NagRules.xcframework"
cp -R "$kmp/nag-rules/build/XCFrameworks/release/NagRules.xcframework" "$here/NagRules.xcframework"
swift run --package-path "$here" -c release NagRulesConsumer
