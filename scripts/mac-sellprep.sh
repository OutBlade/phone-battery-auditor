#!/bin/bash
# Battery health and sell-readiness for the Mac this runs on (macOS 12+).
# Read-only, except --reset, which opens Apple's own "Erase All Content and Settings".
# Usage: bash scripts/mac-sellprep.sh [--reset]

set -u
bat=$(ioreg -rn AppleSmartBattery 2>/dev/null)
val() { echo "$bat" | awk -F'= ' -v k="\"$1\"" '$0 ~ k" =" {print $2; exit}'; }

echo "== $(sysctl -n hw.model)  /  $(sw_vers -productName) $(sw_vers -productVersion)"
system_profiler SPHardwareDataType | grep -E "Model Name|Chip|Processor Name|Memory|Serial Number"
diskutil info / | grep -E "Disk Size|Volume Free Space" | head -2

if [ -n "$bat" ]; then
  design=$(val DesignCapacity); cycles=$(val CycleCount)
  # Apple silicon: NominalChargeCapacity / AppleRawMaxCapacity are mAh.
  # Intel: MaxCapacity is mAh (on Apple silicon it is a 0-100 percentage, so ignore small values).
  raw=$(val NominalChargeCapacity)
  [ -z "$raw" ] && raw=$(val AppleRawMaxCapacity)
  if [ -z "$raw" ]; then
    mc=$(val MaxCapacity)
    [ -n "$mc" ] && [ "$mc" -gt 100 ] && raw=$mc
  fi
  if [ -n "$design" ] && [ -n "$raw" ] && [ "$design" -gt 0 ]; then
    health=$(awk -v a="$raw" -v b="$design" 'BEGIN{printf "%.1f", a/b*100}')
  fi
  echo "Battery: maximum capacity ${health:-unknown}% (${raw:-?} of ${design:-?} mAh), ${cycles:-?} cycles"
  system_profiler SPPowerDataType | grep -E "Condition" | head -1
else
  echo "Battery: none (desktop Mac)"
fi

echo
echo "== Before selling"
if nvram -x -p 2>/dev/null | grep -q fmm-mobileme-token-FMM; then
  echo "BLOCKER: Find My Mac is ON. Erase All Content and Settings turns it off (needs your Apple ID password)."
else
  echo "Find My Mac: off"
fi
echo "Move first: files (Time Machine), passwords/2FA, licenses (Adobe, Microsoft Office: sign out)."

if [ "${1:-}" = "--reset" ]; then
  read -r -p "Type ERASE to open Erase All Content and Settings (anything else cancels): " a
  if [ "$a" = "ERASE" ]; then
    if [ -d "/System/Library/CoreServices/Erase Assistant.app" ]; then
      open "/System/Library/CoreServices/Erase Assistant.app"
    else
      open "x-apple.systempreferences:com.apple.Transfer-Reset-Settings.extension"
    fi
    echo "Follow the dialog. Nothing is erased until you confirm there."
  else
    echo "Cancelled."
  fi
fi
