#!/bin/sh
# Run from macOS Recovery (Utilities > Terminal) before the first desktop boot:
#   sh /Volumes/*/recovery-fix.sh
# Sets Metal's error mode on the installed system's Data volume. Without it,
# iconservicesagent ends repeatedly and the Dock and icons stay blank.
set -eu

found=0
for data in /Volumes/*Data; do
    [ -d "$data/Library/Preferences" ] || continue
    found=1
    prefs="$data/Library/Preferences"
    echo "Applying to: $data"
    defaults write "$prefs/.GlobalPreferences" METAL_ERROR_MODE -int 5
    chmod 644 "$prefs/.GlobalPreferences.plist"
    printf 'METAL_ERROR_MODE = '
    defaults read "$prefs/.GlobalPreferences" METAL_ERROR_MODE
    ls -l "$prefs/.GlobalPreferences.plist"
done

if [ "$found" -eq 0 ]; then
    echo "No installed Data volume found under /Volumes. Install macOS first." >&2
    exit 1
fi
echo "Done. Run 'reboot', then choose the installed macOS entry."
