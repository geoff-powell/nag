#!/usr/bin/env bash
# Changes the app version (MARKETING_VERSION in Config/Base.xcconfig) shared by every target.
# The build number isn't stored: the release scripts pick a new one for every upload.
#
#   scripts/bump-version.sh patch   1.2   -> 1.2.1
#   scripts/bump-version.sh minor   1.2.1 -> 1.3
#   scripts/bump-version.sh major   1.2.1 -> 2.0
#   scripts/bump-version.sh 1.4.2   set it exactly
#
# Prints the new version. Doesn't commit.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"

usage() {
    echo "Usage: scripts/bump-version.sh <major|minor|patch|X.Y[.Z]>" >&2
    exit 2
}

# App Store versions are one to three dot-separated integers.
version_pattern='^[0-9]+(\.[0-9]+){0,2}$'

[[ $# -eq 1 ]] || usage
current="$(marketing_version)"
if [[ ! "$current" =~ $version_pattern ]]; then
    echo "Config/Base.xcconfig has MARKETING_VERSION '$current', which isn't X.Y[.Z]." >&2
    exit 1
fi

IFS=. read -r major minor patch <<< "$current"
minor="${minor:-0}"
patch="${patch:-0}"

case "$1" in
    major) new="$((major + 1)).0" ;;
    minor) new="$major.$((minor + 1))" ;;
    patch) new="$major.$minor.$((patch + 1))" ;;
    *)
        [[ "$1" =~ $version_pattern ]] || usage
        new="$1"
        ;;
esac

if [[ "$new" == "$current" ]]; then
    echo "The version is already $current." >&2
    exit 1
fi

file=Config/Base.xcconfig
tmp="$(mktemp)"
awk -v version="$new" '/^MARKETING_VERSION *=/ { $0 = "MARKETING_VERSION = " version } { print }' "$file" > "$tmp"
# Copy back rather than mv, so the file keeps its permissions.
cat "$tmp" > "$file"
rm -f "$tmp"
[[ "$(marketing_version)" == "$new" ]] || { echo "Couldn't update $file." >&2; exit 1; }
echo "$new"
