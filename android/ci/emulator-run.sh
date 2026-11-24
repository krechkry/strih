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

# open the first project (rows start below the New project card)
adb shell input tap 540 900
sleep 4
adb exec-out screencap -p > $OUT/03-editor.png
# play: the transport's play button sits at the bottom middle
adb shell input tap 620 2240
sleep 2
adb exec-out screencap -p > $OUT/04-playing-2s.png
sleep 2
adb exec-out screencap -p > $OUT/05-playing-4s.png
adb logcat -d -t 400 | grep -iE "bombocut|AndroidRuntime|FATAL" > $OUT/logcat.txt || true
ls -la $OUT
