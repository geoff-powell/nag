# shellcheck shell=bash
# Shared helpers for the release scripts. Sourced, not run.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

xcconfig_value() {
    awk -F' *= *' -v key="$1" '$1 == key { print $2 }' Config/Signing.xcconfig Config/Base.xcconfig | head -1
}

team_id() {
    local team
    team="$(xcconfig_value DEVELOPMENT_TEAM)"
    if [[ -z "$team" ]]; then
        echo "Set DEVELOPMENT_TEAM in Config/Signing.xcconfig first." >&2
        exit 1
    fi
    echo "$team"
}

marketing_version() {
    xcconfig_value MARKETING_VERSION
}

# Minutes since 2020 in UTC: always increases, fits App Store limits, same for app and extensions.
next_build_number() {
    echo $(( ($(date -u +%s) - 1577836800) / 60 ))
}

# Writes an export options plist. Usage: write_export_options <file> <method> <destination>
write_export_options() {
    local file="$1" method="$2" destination="$3"
    plutil -create xml1 "$file"
    plutil -insert method -string "$method" "$file"
    plutil -insert destination -string "$destination" "$file"
    plutil -insert teamID -string "$(team_id)" "$file"
    plutil -insert signingStyle -string automatic "$file"
    if [[ "$method" == "app-store-connect" ]]; then
        plutil -insert uploadSymbols -bool true "$file"
        plutil -insert manageAppVersionAndBuildNumber -bool false "$file"
    fi
}

# Runs xcodebuild, keeping the full log and printing only errors, warnings and the result.
run_xcodebuild() {
    local log="$1"
    shift
    echo "  xcodebuild $*" | cut -c1-160
    xcodebuild "$@" > "$log" 2>&1 || {
        grep -E "error:|\*\* .* FAILED \*\*" "$log" | sort -u | head -30 >&2
        echo "Failed. Full log: $log" >&2
        return 1
    }
    grep -E "warning: |\*\* .* SUCCEEDED \*\*" "$log" | grep -v appintents | sort -u | head -20 || true
}

require_clean_tree() {
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "Commit or stash your changes first, so the release matches a commit." >&2
        exit 1
    fi
}
