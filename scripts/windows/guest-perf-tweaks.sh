#!/bin/sh
# Guest tweaks for the Reims vGPU VM. Safe to rerun.
#   Normal macOS Terminal:  sh guest-perf-tweaks.sh
#   macOS Recovery Terminal: sh /Volumes/<share>/guest-perf-tweaks.sh
# Sets METAL_ERROR_MODE=5 system-wide (required; without it iconservicesagent
# keeps ending and the Dock stays blank) and, on a running system, trims UI
# animations. In measurements the animation tweaks changed little
# (avg 9.3 -> 9.7 fps during Mission Control), so they are optional comfort.
set -eu

set_metal() {
    prefs="$1"
    defaults write "$prefs/.GlobalPreferences" METAL_ERROR_MODE -int 5
    chmod 644 "$prefs/.GlobalPreferences.plist"
    printf 'METAL_ERROR_MODE = '
    defaults read "$prefs/.GlobalPreferences" METAL_ERROR_MODE
}

if [ -d /Volumes ] && ls -d /Volumes/*Data >/dev/null 2>&1 && [ ! -d /Users/Shared ]; then
    # Recovery: patch the installed Data volume(s).
    for data in /Volumes/*Data; do
        [ -d "$data/Library/Preferences" ] || continue
        echo "Recovery mode, applying to: $data"
        set_metal "$data/Library/Preferences"
    done
    echo "Done. Run 'reboot', then choose the installed macOS entry."
    exit 0
fi

# Running macOS.
if [ "$(id -u)" -eq 0 ]; then
    set_metal /Library/Preferences
else
    echo "Setting METAL_ERROR_MODE needs root; you may be asked for your password."
    sudo defaults write /Library/Preferences/.GlobalPreferences METAL_ERROR_MODE -int 5
    sudo chmod 644 /Library/Preferences/.GlobalPreferences.plist
fi

if [ "$(id -u)" -ne 0 ]; then
    defaults write com.apple.dock expose-animation-duration -float 0.1
    defaults write com.apple.dock launchanim -bool false
    defaults write com.apple.dock mru-spaces -bool false
    defaults write com.apple.dock springboard-show-duration -float 0
    defaults write com.apple.dock springboard-hide-duration -float 0
    defaults write com.apple.dock workspaces-swoosh-animation-off -bool true
    defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false
    defaults write NSGlobalDomain NSWindowResizeTime -float 0.001
    killall Dock SystemUIServer 2>/dev/null || true
fi
echo "Done. Reboot the guest for METAL_ERROR_MODE to take effect."
