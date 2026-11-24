#!/bin/bash
# Runs on the CI emulator: puts test clips and an iPhone-format project into the debug app, takes screenshots.
# Output: android/ci/out/*.png (uploaded as the "screens" artifact).
set -x
OUT=android/ci/out
mkdir -p $OUT
APP=cz.krechler.bombocut
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
# let the fresh emulator settle (its launcher can be busy and throw "not responding" over us)
sleep 20
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null
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
# scrub: swipe the timeline left (about 1.5 s at 60 points a second), then split at the playhead, then undo
adb shell input swipe 800 1960 560 1960 600
sleep 2
adb exec-out screencap -p > $OUT/05b-scrubbed.png
python3 android/ci/tap.py "Split"
sleep 2
adb exec-out screencap -p > $OUT/06-split.png
python3 android/ci/tap.py "Speed" && sleep 2 && adb exec-out screencap -p > $OUT/06b-speed.png
python3 android/ci/tap.py "Curve" && sleep 2 && adb exec-out screencap -p > $OUT/06c-curve.png
python3 android/ci/tap.py "Done"; sleep 1
python3 android/ci/tap.py "Undo"
sleep 2
adb exec-out screencap -p > $OUT/07-undo.png
adb shell "run-as cz.krechler.bombocut cat files/Projects/00000000-0000-0000-0000-00000000A001.json" > $OUT/project-after.json
adb logcat -d -b crash > $OUT/crash.txt || true
adb logcat -d | grep -A60 "FATAL EXCEPTION" > $OUT/logcat.txt || true
adb logcat -d | grep -iE "Media3|CompositionPlayer|ExoPlayer|bombocut" | tail -300 > $OUT/media.txt || true
ls -la $OUT

# export Full HD 30 and check the file (its length should be the project's: 3 s + 2.5 s at 2x = 4.25 s)
python3 android/ci/tap.py "Export"
sleep 2
adb exec-out screencap -p > $OUT/08-export-sheet.png
python3 android/ci/tap.py "Full HD · 30 fps"
for i in $(seq 1 60); do
  sleep 3
  if adb shell ls /sdcard/Movies/BOMBOCUT/ 2>/dev/null | grep -q mp4; then break; fi
done
sleep 3
adb exec-out screencap -p > $OUT/09-export-done.png
F=$(adb shell ls /sdcard/Movies/BOMBOCUT/ | tr -d '\r' | grep mp4 | head -1)
if [ -n "$F" ]; then
  adb pull "/sdcard/Movies/BOMBOCUT/$F" $OUT/export.mp4
  ffprobe -v error -show_entries format=duration:stream=codec_name,width,height,r_frame_rate -of default=nw=1 $OUT/export.mp4 > $OUT/export.txt
  ffmpeg -loglevel error -ss 1 -i $OUT/export.mp4 -frames:v 1 $OUT/10-export-frame-1s.png
  ffmpeg -loglevel error -ss 3.5 -i $OUT/export.mp4 -frames:v 1 $OUT/11-export-frame-3.5s.png
  rm $OUT/export.mp4
else
  echo "no export file" > $OUT/export.txt
fi
cat $OUT/export.txt
adb logcat -d -b crash > $OUT/crash.txt || true
