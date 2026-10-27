#!/bin/zsh
# Captures README screenshots of the notch on the built-in (notched) display using demo data.
# Run it from an empty desktop (Space) on the MacBook screen so only the wallpaper shows.
#   ./scripts/screenshots.sh            -> docs/screenshots/*.png
set -e
cd "$(dirname "$0")/.."
APP=T3Notch.app
OUT=docs/screenshots
DOMAIN=dev.custom-dock.t3notch
mkdir -p $OUT

# Built-in display geometry in screencapture's (top-left origin, global) coordinates.
read X Y W < <(swift -e '
import AppKit
let all = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
let s = NSScreen.screens.first { CGDisplayIsBuiltin(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value) != 0 }!
print(Int(s.frame.minX), Int(all.maxY - s.frame.maxY), Int(s.frame.width))
' 2>/dev/null)

previous=$(defaults read $DOMAIN displayChoice 2>/dev/null || echo "")
defaults write $DOMAIN displayChoice builtin

shot() { # name, height, extra env...
  local name=$1 height=$2; shift 2
  pkill -x T3Notch 2>/dev/null || true; sleep 1.5
  open --env T3NOTCH_ALLOW_CAPTURE=1 "$@" $APP
  sleep 6
  local width=820
  screencapture -x -R $((X + W / 2 - width / 2)),$Y,$width,$height $OUT/$name.png
  echo "captured $name"
}

shot compact 70 --env T3NOTCH_DEMO=list
shot expanded 520 --env T3NOTCH_DEMO=list --env T3NOTCH_FORCE_EXPANDED=1
shot approval 230 --env T3NOTCH_DEMO=approval
shot question 230 --env T3NOTCH_DEMO=question
shot finished 160 --env T3NOTCH_DEMO=finished

pkill -x T3Notch 2>/dev/null || true; sleep 1
if [[ -n "$previous" ]]; then defaults write $DOMAIN displayChoice "$previous"; else defaults delete $DOMAIN displayChoice; fi
open $APP
echo "done: $OUT"
