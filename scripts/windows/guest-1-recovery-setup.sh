#!/bin/sh
# STEP 1 - run once from macOS Recovery, after macOS is installed and before
# its first desktop boot:
#   Recovery > Utilities > Terminal:   sh /Volumes/REIMSTOOLS/1-recovery-setup.sh
# (the tools disk is the volume that contains this file; `sh /Volumes/*/1-recovery-setup.sh` also works)
#
# Sets METAL_ERROR_MODE=5 on the installed system's Data volume. Without it
# iconservicesagent keeps ending and the desktop has no Dock and blank icons.
# Safe to rerun.
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
done

if [ "$found" -eq 0 ]; then
    echo "No installed Data volume found under /Volumes. Install macOS first." >&2
    exit 1
fi
echo "Done. Run 'reboot', then choose the installed macOS entry."
