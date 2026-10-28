#!/usr/bin/env bash
# Builds the Mac app with Developer ID, notarizes it, and publishes it as a GitHub release.
#
#   scripts/release-mac.sh             archive, notarize, staple, publish a GitHub release
#   scripts/release-mac.sh --dry-run   archive and export only
#
# Run on a Mac that's registered in your developer account (Xcode does this the first time you run
# NagMac from it). One-time setup for notarizing, with an app-specific password from
# account.apple.com:
#
#   xcrun notarytool store-credentials nag-notary --apple-id YOU@EXAMPLE.COM --team-id <TEAM ID>
#
# Environment:
#   NAG_NOTARY_PROFILE  keychain profile from store-credentials (default: nag-notary)
#   NAG_GITHUB_USER     gh account to publish with, if several are signed in
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"

dry_run=false
if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=true
fi
notary_profile="${NAG_NOTARY_PROFILE:-nag-notary}"

build_dir="$repo_root/build/mac"
archive="$build_dir/Nag.xcarchive"
rm -rf "$build_dir"
mkdir -p "$build_dir"

$dry_run || require_clean_tree
version="$(marketing_version)"
build_number="$(next_build_number)"
echo "Archiving Nag $version ($build_number) for Mac…"
run_xcodebuild "$build_dir/archive.log" \
    -project Nag.xcodeproj -scheme NagMac -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$archive" \
    -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$build_number" \
    archive

echo "Exporting with Developer ID…"
write_export_options "$build_dir/ExportOptions.plist" developer-id export
run_xcodebuild "$build_dir/export.log" \
    -exportArchive -archivePath "$archive" -exportPath "$build_dir/export" \
    -exportOptionsPlist "$build_dir/ExportOptions.plist" -allowProvisioningUpdates
app="$build_dir/export/Nag.app"

if $dry_run; then
    echo "Dry run OK: $app"
    exit 0
fi

echo "Notarizing (usually a few minutes)…"
ditto -c -k --keepParent "$app" "$build_dir/Nag-notarize.zip"
xcrun notarytool submit "$build_dir/Nag-notarize.zip" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app"
spctl --assess --type execute --verbose "$app"

zip="$build_dir/Nag-$version-$build_number.zip"
ditto -c -k --keepParent "$app" "$zip"

if [[ -n "${NAG_GITHUB_USER:-}" ]]; then
    GH_TOKEN="$(gh auth token --user "$NAG_GITHUB_USER")"
    export GH_TOKEN
fi
tag="mac-v$version-$build_number"
echo "Publishing GitHub release $tag…"
gh release create "$tag" "$zip" \
    --target "$(git rev-parse HEAD)" \
    --title "Nag for Mac $version ($build_number)" \
    --notes "Download the zip, unzip it, and move Nag to Applications. Signed with Developer ID and notarized by Apple."
echo "Released $tag."
