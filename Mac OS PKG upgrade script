#!/bin/sh
set -eu
 
PATH=/usr/bin:/bin:/usr/sbin:/sbin
URL="https://swcdn.apple.com/…/InstallAssistant.pkg"  # <-- put the FULL URL here, no ellipsis
PKG="InstallAssistant.pkg"
 
TMP_DIR="/tmp/tahoe_installer.$$"
mkdir -p "$TMP_DIR"
 
# Ensure macOS
if uname -s | grep -q Darwin; then :; else
  echo "This script must run on macOS" >&2
  exit 1
fi
 
# Pre-auth sudo (will prompt)
sudo -v
 
# 1) Download the pkg
curl -L --fail --silent --show-error -o "$TMP_DIR/$PKG" "$URL"
 
# 2) Install silently and auto-accept EULA by feeding 'A'
printf 'A\n' | sudo /usr/sbin/installer -pkg "$TMP_DIR/$PKG" -target /
 
# 3) Clean up the pkg and temp dir
rm -f "$TMP_DIR/$PKG"
rmdir "$TMP_DIR" 2>/dev/null || true
 
# 4) Verify installer app exists
if [ ! -d "/Applications/Install macOS Tahoe.app" ]; then
  echo "Expected installer app not found at /Applications/Install macOS Tahoe.app" >&2
  exit 1
fi
 
# 5) Kick off startosinstall; reads password from stdin (no newline)
printf %s "FULLYTOKENIZEDUSERACCOUNTpasswordGOESHERE" | sudo "/Applications/Install macOS Tahoe.app/Contents/Resources/startosinstall" \
  --agreetolicense \
  --nointeraction \
  --forcequitapps \
  --rebootdelay 15 \
  --user "FULLYTOKENIZEDUSERACCOUNTnameGOESHERE" \
  --stdinpass
