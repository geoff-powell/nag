#!/usr/bin/env bash
# Records each Nag UI test on the iOS simulator, for reviewing animations.
#
# Usage: scripts/record-ui.sh [output-dir] [test-name ...]
#   output-dir  defaults to build/ui-recordings
#   test-name   e.g. testSnoozingFromTheSwipeAction; defaults to every test in NagUITests
#
# Environment:
#   SIMULATOR   simulator name or UDID (default: "iPhone 17 Pro")
#   PAUSE       seconds each test holds after a step (default: 0.8)
#
# Writes <test>.mp4 (full quality) and <test>.gif (small, for sharing) per test. Needs ffmpeg.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

out="${1:-build/ui-recordings}"
shift || true
simulator="${SIMULATOR:-iPhone 17 Pro}"
pause="${PAUSE:-0.8}"
derived="build/ui-derived-data"
mkdir -p "$out"

command -v ffmpeg >/dev/null || { echo "Install ffmpeg first: brew install ffmpeg" >&2; exit 1; }

udid="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if name in (d["name"], d["udid"]):
            print(d["udid"]); raise SystemExit
' "$simulator")"
[[ -n "$udid" ]] || { echo "No simulator named $simulator" >&2; exit 1; }
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
# A clean status bar keeps recordings comparable.
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3

echo "Building for testing on ${simulator}…"
xcodebuild build-for-testing -scheme Nag -destination "id=$udid" -derivedDataPath "$derived" -quiet

tests=("$@")
if [[ ${#tests[@]} -eq 0 ]]; then
    while IFS= read -r name; do tests+=("$name"); done < <(grep -oE 'func (test[A-Za-z0-9]+)\(' NagUITests/NagUITests.swift | sed -E 's/func (test[A-Za-z0-9]+)\(/\1/')
fi

for test in "${tests[@]}"; do
    echo "Recording ${test}…"
    raw="$out/$test.raw.mp4"
    rm -f "$raw"
    xcrun simctl io "$udid" recordVideo --codec h264 --force "$raw" >/dev/null 2>&1 &
    recorder=$!
    sleep 1
    status=0
    TEST_RUNNER_NAG_UI_PAUSE="$pause" xcodebuild test-without-building -scheme Nag -destination "id=$udid" \
        -derivedDataPath "$derived" -only-testing:"NagUITests/NagUITests/$test" -quiet >/dev/null 2>&1 || status=$?
    sleep 0.5
    kill -INT "$recorder"
    wait "$recorder" || true
    [[ $status -eq 0 ]] || echo "  $test failed; keeping the recording anyway" >&2

    # Constant 60 fps for frame-by-frame review; half-size GIF for sharing.
    ffmpeg -loglevel error -y -i "$raw" -vf "fps=60,scale=-2:1280" -c:v libx264 -pix_fmt yuv420p -crf 20 "$out/$test.mp4"
    ffmpeg -loglevel error -y -i "$raw" -vf "fps=30,scale=360:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" "$out/$test.gif"
    rm -f "$raw"
done

xcrun simctl status_bar "$udid" clear
echo "Recordings in $out"
