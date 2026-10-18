#!/bin/sh
# STEP 2 - run from the installed macOS (Terminal), as your normal user:
#   sh /Volumes/REIMSTOOLS/2-macos-optimize.sh
#
# 1. Sets METAL_ERROR_MODE=5 system-wide (asks for your password). This is the
#    same required fix as step 1, so it also repairs a VM that skipped Recovery.
# 2. Trims animations in your account. Measured effect is small (Mission
#    Control 9.3 -> 9.7 fps), so this is optional comfort.
# Reduce Transparency and Reduce Motion cannot be set from a script; turn them
# on in System Settings > Accessibility > Display (see the manual).
# Safe to rerun. Reboot afterwards.
set -eu

if [ -d /Volumes ] && [ ! -d /Users/Shared ]; then
    echo "This looks like macOS Recovery. Run 1-recovery-setup.sh there instead." >&2
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    defaults write /Library/Preferences/.GlobalPreferences METAL_ERROR_MODE -int 5
    chmod 644 /Library/Preferences/.GlobalPreferences.plist
    echo "Run this script as your normal user to apply the animation settings too."
    exit 0
fi

echo "Setting METAL_ERROR_MODE needs root; you may be asked for your password."
sudo defaults write /Library/Preferences/.GlobalPreferences METAL_ERROR_MODE -int 5
sudo chmod 644 /Library/Preferences/.GlobalPreferences.plist

defaults write com.apple.dock expose-animation-duration -float 0.1
defaults write com.apple.dock launchanim -bool false
defaults write com.apple.dock mru-spaces -bool false
defaults write com.apple.dock springboard-show-duration -float 0
defaults write com.apple.dock springboard-hide-duration -float 0
defaults write com.apple.dock workspaces-swoosh-animation-off -bool true
defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false
defaults write NSGlobalDomain NSWindowResizeTime -float 0.001
killall Dock SystemUIServer 2>/dev/null || true
echo "Done. Reboot the guest for METAL_ERROR_MODE to take effect."
