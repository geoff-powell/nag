#!/usr/bin/env bash
# Archives the iPhone app and uploads it to App Store Connect for TestFlight.
#
#   scripts/testflight.sh             archive and upload
#   scripts/testflight.sh --dry-run   archive and export locally, without uploading
#
# Needs: your Apple ID in Xcode > Settings > Accounts, the app created in App Store Connect, and
# Apple's approval of the Family Controls (Distribution) capability for the app and its extensions.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"

destination=upload
if [[ "${1:-}" == "--dry-run" ]]; then
    destination="export"
fi

build_dir="$repo_root/build/ios"
archive="$build_dir/Nag.xcarchive"
rm -rf "$build_dir"
mkdir -p "$build_dir"

[[ "$destination" == upload ]] && require_clean_tree
build_number="$(next_build_number)"
echo "Archiving Nag $(marketing_version) ($build_number) for iPhone…"
run_xcodebuild "$build_dir/archive.log" \
    -project Nag.xcodeproj -scheme Nag -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" \
    -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$build_number" \
    archive

write_export_options "$build_dir/ExportOptions.plist" app-store-connect "$destination"
if [[ "$destination" == upload ]]; then
    echo "Uploading to App Store Connect…"
else
    echo "Exporting for App Store Connect (dry run, not uploading)…"
fi
run_xcodebuild "$build_dir/export.log" \
    -exportArchive -archivePath "$archive" -exportPath "$build_dir/export" \
    -exportOptionsPlist "$build_dir/ExportOptions.plist" -allowProvisioningUpdates

if [[ "$destination" == upload ]]; then
    echo "Uploaded build $build_number. It appears in App Store Connect > TestFlight after processing (usually 5–30 minutes)."
else
    echo "Dry run OK: $build_dir/export"
fi
