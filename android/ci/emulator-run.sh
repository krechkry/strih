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
# scrub: playback left the playhead at the end, so swipe the timeline right (back about 1.5 s), then split at the playhead, then undo
adb shell input swipe 300 1960 540 1960 600
sleep 2
adb exec-out screencap -p > $OUT/05b-scrubbed.png
python3 android/ci/tap.py "Split"
sleep 2
adb exec-out screencap -p > $OUT/06-split.png
python3 android/ci/tap.py "Speed" && sleep 2 && adb exec-out screencap -p > $OUT/06b-speed.png
python3 android/ci/tap.py "Curve" && sleep 2 && adb exec-out screencap -p > $OUT/06c-curve.png
python3 android/ci/tap.py "Done"; sleep 1
python3 android/ci/tap.py "Adjust" && sleep 2 && adb exec-out screencap -p > $OUT/06d-adjust.png
python3 android/ci/tap.py "Done"; sleep 1
python3 android/ci/tap.py "Undo"
sleep 2
adb exec-out screencap -p > $OUT/07-undo.png
adb shell "run-as cz.krechler.bombocut cat files/Projects/00000000-0000-0000-0000-00000000A001.json" > $OUT/project-after.json
adb logcat -d -b crash > $OUT/crash.txt || true
adb logcat -d | grep -E "blend input|layer input|Bombocut: clip" | head -40 > $OUT/blend.txt || true
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
# the app's own warnings and errors so far (preview and export), and when the export is stuck: every thread's stack
PID=$(adb shell pidof $APP | tr -d '\r')
adb logcat -d -v threadtime --pid=$PID 2>/dev/null | grep -E " [WEF] |blend input" | head -800 > $OUT/app-log.txt || true
if ! adb shell ls /sdcard/Movies/BOMBOCUT/ 2>/dev/null | grep -q mp4 && [ -n "$PID" ]; then
  adb root > /dev/null 2>&1; sleep 3
  adb shell kill -3 $PID; sleep 4
  T=$(adb shell ls -t /data/anr 2>/dev/null | head -1 | tr -d '\r')
  [ -n "$T" ] && adb shell cat /data/anr/$T > $OUT/threads.txt
  adb unroot > /dev/null 2>&1 || true; sleep 3; adb wait-for-device
fi
F=$(adb shell ls /sdcard/Movies/BOMBOCUT/ | tr -d '\r' | grep mp4 | head -1)
if [ -n "$F" ]; then
  adb pull "/sdcard/Movies/BOMBOCUT/$F" $OUT/export.mp4
  ffprobe -v error -show_entries format=duration:stream=codec_name,width,height,r_frame_rate,duration,nb_frames -of default=nw=1 $OUT/export.mp4 > $OUT/export.txt
  # around the transition (the cut sits in its middle): which source frame shows
  for t in 2.7 2.8 2.87 2.95; do ffmpeg -loglevel error -ss $t -i $OUT/export.mp4 -frames:v 1 $OUT/export-at-$t.png; done
  ffmpeg -loglevel error -ss 1 -i $OUT/export.mp4 -frames:v 1 $OUT/10-export-frame-1s.png
  for t in 1.2 1.5 1.8 2.2; do ffmpeg -loglevel error -ss $t -i $OUT/export.mp4 -frames:v 1 $OUT/10b-export-layer-$t.png; done
  ffmpeg -loglevel error -ss 3.5 -i $OUT/export.mp4 -frames:v 1 $OUT/11-export-frame-3.5s.png
  rm $OUT/export.mp4
else
  echo "no export file" > $OUT/export.txt
fi
cat $OUT/export.txt
# add a text: reopen the project (nothing selected), tap Text, the text panel opens; then pick the sound in its lane
adb shell am force-stop $APP
adb shell am start -W -n $APP/.app.MainActivity
sleep 4
python3 android/ci/tap.py "Z iPhonu"
sleep 4
python3 android/ci/tap.py "Text" || true
sleep 3
adb exec-out screencap -p > $OUT/13-text.png
adb shell input keyevent 4
sleep 1
adb exec-out screencap -p > $OUT/13b-text-closed.png
sleep 1
python3 android/ci/tap.py "Zvuk z videa" || true
sleep 3
adb exec-out screencap -p > $OUT/14-sound.png
adb shell input keyevent 4
sleep 1
python3 android/ci/tap.py "Ahoj lidi" || true
sleep 3
adb exec-out screencap -p > $OUT/15-caption.png
adb shell input swipe 540 2000 540 1300 400
sleep 1
adb exec-out screencap -p > $OUT/15b-caption-style.png
# a second project: the video layer over one clip. Two video decoders: the emulator's software decoders run out at
# three ("Released by resource manager"), so the layer in the first project comes out empty there.
adb shell am force-stop $APP
adb shell rm -f /sdcard/Movies/BOMBOCUT/*.mp4
adb shell am start -W -n $APP/.app.MainActivity
sleep 4
python3 android/ci/tap.py "Vrstva"
sleep 4
python3 android/ci/tap.py "Export"
sleep 2
python3 android/ci/tap.py "Full HD · 30 fps"
for i in $(seq 1 60); do
  sleep 3
  if adb shell ls /sdcard/Movies/BOMBOCUT/ 2>/dev/null | grep -q mp4; then break; fi
done
sleep 3
F=$(adb shell ls /sdcard/Movies/BOMBOCUT/ | tr -d '\r' | grep mp4 | head -1)
if [ -n "$F" ]; then
  adb pull "/sdcard/Movies/BOMBOCUT/$F" $OUT/layer.mp4
  for t in 1.2 1.5 1.8 2.2; do ffmpeg -loglevel error -ss $t -i $OUT/layer.mp4 -frames:v 1 $OUT/16-layer-$t.png; done
  rm $OUT/layer.mp4
else
  adb exec-out screencap -p > $OUT/16-layer-export-stuck.png
fi
# the paywall (debug builds skip it unless asked): a fresh start shows the free week offer
adb shell am force-stop $APP
adb shell run-as $APP rm -f shared_prefs/purchases.xml || true
adb shell am start -W -n $APP/.app.MainActivity --ez paywall true
sleep 4
adb exec-out screencap -p > $OUT/12-paywall.png
adb logcat -d -b crash > $OUT/crash.txt || true
adb logcat -d | grep -E "blend input|layer input|Bombocut: clip" | head -40 > $OUT/blend.txt || true
