#!/bin/bash
# Runs on the CI emulator: puts test clips and an iPhone-format project into the debug app, takes screenshots.
# Output: android/ci/out/*.png (uploaded as the "screens" artifact).
set -x
OUT=android/ci/out
mkdir -p $OUT
APP=cz.krechler.bombocut
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
adb shell pm grant $APP android.permission.POST_NOTIFICATIONS 2>/dev/null || true

# the app makes its folders on first start
adb shell am start -W -n $APP/.app.MainActivity
sleep 4
adb exec-out screencap -p > $OUT/01-home-empty.png
adb shell am force-stop $APP

# test clips and a project (the same JSON shape the iPhone app writes)
for f in android/ci/media/*.mp4; do
  n=$(basename $f)
  adb push $f /data/local/tmp/$n
  adb shell "run-as $APP sh -c 'mkdir -p files/Media files/Projects && cp /data/local/tmp/$n files/Media/$n'"
done
for f in android/ci/projects/*.json; do
  n=$(basename $f)
  adb push $f /data/local/tmp/$n
  adb shell "run-as $APP sh -c 'cp /data/local/tmp/$n files/Projects/$n'"
done
adb shell "run-as $APP ls -la files/Media files/Projects"

adb shell am start -W -n $APP/.app.MainActivity
sleep 5
adb exec-out screencap -p > $OUT/02-home.png

# open the project from the iPhone
python3 android/ci/tap.py "Z iPhonu"
sleep 4
adb exec-out screencap -p > $OUT/03-editor.png
python3 android/ci/tap.py "Play"
sleep 2
adb exec-out screencap -p > $OUT/04-playing-2s.png
sleep 2
adb exec-out screencap -p > $OUT/05-playing-4s.png
python3 android/ci/tap.py "Pause" || true
# split at the playhead, then undo
python3 android/ci/tap.py "Split"
sleep 2
adb exec-out screencap -p > $OUT/06-split.png
python3 android/ci/tap.py "Undo"
sleep 2
adb exec-out screencap -p > $OUT/07-undo.png
adb shell "run-as cz.krechler.bombocut cat files/Projects/00000000-0000-0000-0000-00000000A001.json" > $OUT/project-after.json
adb logcat -d -b crash > $OUT/crash.txt || true
adb logcat -d | grep -A60 "FATAL EXCEPTION" > $OUT/logcat.txt || true
adb logcat -d | grep -iE "Media3|CompositionPlayer|ExoPlayer|bombocut" | tail -200 > $OUT/media.txt || true
ls -la $OUT
