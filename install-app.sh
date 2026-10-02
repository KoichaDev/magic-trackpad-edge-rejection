#!/bin/sh
set -eu
cd "$(dirname "$0")"
source_app="$PWD/build/TrackpadEdges.app"
destination="${1:-/Applications}"
target="$destination/TrackpadEdges.app"
if [ ! -d "$source_app" ]; then
    printf '%s\n' 'Build the app first with: sh build-app.sh' >&2
    exit 1
fi
codesign --verify --strict "$source_app"
if [ -e "$target" ]; then
    target_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$target/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$target_identifier" != 'dev.koicha.trackpad-edges' ]; then
        printf '%s\n' "Refusing to replace a different app at $target" >&2
        exit 1
    fi
    if /usr/sbin/lsof -t "$target/Contents/MacOS/TrackpadEdges" >/dev/null 2>&1; then
        printf '%s\n' 'Quit the installed Trackpad Edges app before updating it.' >&2
        exit 1
    fi
fi
mkdir -p "$destination"
staging="$(mktemp -d "${TMPDIR:-/tmp}/trackpad-edges-install.XXXXXX")"
# Retain the previous bundle for rollback; it can be recovered from this temp folder.
trap 'if [ -d "$staging/previous.app" ] && [ ! -e "$target" ]; then mv "$staging/previous.app" "$target"; fi' EXIT
/usr/bin/ditto "$source_app" "$staging/TrackpadEdges.app"
codesign --verify --strict "$staging/TrackpadEdges.app"
if [ -e "$target" ]; then mv "$target" "$staging/previous.app"; fi
mv "$staging/TrackpadEdges.app" "$target"
touch "$target"
launch_services_register="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$launch_services_register" ]; then "$launch_services_register" -f "$target"; fi
printf 'Installed: %s\n' "$target"
if [ -d "$staging/previous.app" ]; then printf 'Previous app saved: %s\n' "$staging/previous.app"; fi
