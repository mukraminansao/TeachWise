#!/usr/bin/env bash
# Android smoke test (run by .github/workflows/android.yml inside the emulator job).
# Installs the APK, opens TeachWise, skips the intro, signs in with the demo student account and
# checks that the dashboard opens and the app never crashes. Screenshots go to smoke/.
set -u
APK="$1"
PKG=com.teachwise.app
OUT=smoke
mkdir -p "$OUT"
step=0

shot() { step=$((step + 1)); adb exec-out screencap -p > "$OUT/$(printf '%02d' $step)-$1.png"; }
ui() { adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; adb shell cat /sdcard/ui.xml 2>/dev/null; }
# Tap the centre of the first element whose text or content-desc contains $1. Returns 1 if not on screen.
tap() {
  local b
  b=$(ui | tr '>' '\n' | grep -F -e "text=\"$1" -e "content-desc=\"$1" | head -1 | grep -o 'bounds="[^"]*"')
  [ -n "$b" ] || return 1
  read -r x1 y1 x2 y2 <<<"$(echo "$b" | grep -o '[0-9]\+' | tr '\n' ' ')"
  adb shell input tap $(((x1 + x2) / 2)) $(((y1 + y2) / 2))
}
alive() { adb shell pidof "$PKG" >/dev/null; }
# Print the words on screen (text and accessibility labels) to the job log.
screen() {
  echo "--- on screen ($1), $(adb shell wm size | tr -d '\r'):"
  ui | tr '>' '\n' | grep -e 'text="[^"]' -e 'content-desc="[^"]' \
    | sed -E 's/.*(text="[^"]*").*(content-desc="[^"]*").*(bounds="[^"]*").*/    \1 \2 \3/' | head -80
}
# Scroll the page down by about half a screen.
scroll_down() {
  local w h
  read -r w h <<<"$(adb shell wm size | grep -o '[0-9]\+x[0-9]\+' | tail -1 | tr 'x' ' ')"
  adb shell input swipe $((w / 2)) $((h * 7 / 10)) $((w / 2)) $((h * 3 / 10)) 400
}
fail() {
  echo "::error::$1"; shot failed; screen "when it failed"
  adb logcat -d > "$OUT/logcat.txt"
  echo "--- app log (errors and React Native):"; grep -E "ReactNativeJS|FATAL EXCEPTION|AndroidRuntime: (Process|java)" "$OUT/logcat.txt" | tail -30
  exit 1
}

adb install -r "$APK" || fail "the APK did not install"
adb logcat -c
adb shell am start -W -n "$PKG/.MainActivity" || fail "the app did not open"

# Up to 90 s: skip the intro if it shows, then wait for the sign-in screen's demo buttons.
signed=0
for i in $(seq 1 45); do
  sleep 2
  [ "$i" = 3 ] && { shot first-screen; screen "first screen"; }
  alive || fail "the app closed on start"
  tap "Skip intro" && { sleep 1; continue; }
  if ui | grep -q 'Sign in as the demo Student'; then
    shot sign-in
    tap "Sign in as the demo Student"
    signed=1
    break
  fi
  scroll_down   # the demo buttons are below the sign-in form
done
[ "$signed" = 1 ] || fail "the sign-in screen with the demo accounts never appeared"

# Up to 90 s for the student dashboard (the demo server may be slow to answer).
ok=0
for i in $(seq 1 45); do
  sleep 2
  alive || fail "the app closed after signing in"
  dump=$(ui)
  if echo "$dump" | grep -q -e 'Could not sign in' -e 'Hindi makapag-sign in'; then fail "sign-in failed: the app showed an error"; fi
  if echo "$dump" | grep -q -e 'text="Dashboard"' -e 'Your classes to evaluate' -e 'No evaluation period is open yet'; then ok=1; break; fi
done
shot after-sign-in
screen "after signing in"
[ "$ok" = 1 ] || fail "the student dashboard did not appear after signing in"

# Scroll a little and make sure it is still running.
scroll_down
sleep 3
shot scrolled
alive || fail "the app closed while scrolling"

adb logcat -d > "$OUT/logcat.txt"
if grep -q "FATAL EXCEPTION" "$OUT/logcat.txt"; then fail "a crash was logged"; fi
if grep -E "ReactNativeJS.*(Error|Exception)" "$OUT/logcat.txt" | grep -v -i "network request failed" | head -5 | grep -q .; then
  grep -E "ReactNativeJS.*(Error|Exception)" "$OUT/logcat.txt" | head -5
  fail "JavaScript errors were logged"
fi
echo "Android smoke test passed: opened, signed in as the demo student, dashboard shown, no crashes."
