#!/bin/bash

# Xcode Cloud post-clone script
# Runs after the repo is cloned, before SPM dependency resolution.
# Ensures Git uses HTTPS (not SSH/git://) so Xcode Cloud can reach
# public GitHub packages without needing stored credentials.

set -e

echo "==> ci_post_clone.sh: Configuring Git for SPM dependency resolution..."

# Force git:// URLs to use HTTPS — Xcode Cloud has no SSH keys available
git config --global url."https://github.com/".insteadOf "git://github.com/"

# Tell Xcode to use Package.resolved exactly as committed rather than
# re-resolving, which prevents network timeouts and version drift on CI.
defaults write com.apple.dt.Xcode IDEPackageOnlyUseVersionsFromResolvedFile -bool YES

echo "==> ci_post_clone.sh: Done."
