#!/bin/bash
# Runs on the CI emulator: the speech model and a spoken Czech clip into the debug app, a project with that clip,
# then the Captions panel's Generate captions; the words it heard end up in words.txt.
set -x
OUT=android/ci/out-captions
mkdir -p $OUT
APP=cz.krechler.bombocut
M=parakeet-ultra-int8-1
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
sleep 20
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null
adb shell am start -W -n $APP/.app.MainActivity
sleep 4
adb shell am force-stop $APP

# the model, as if downloaded (the app checks sizes; ".checked" says the hashes were checked)
adb shell "run-as $APP mkdir -p files/Models/$M"
for f in encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx tokens.txt; do
  adb push ~/model/$f /data/local/tmp/$f > /dev/null
  adb shell "run-as $APP cp /data/local/tmp/$f files/Models/$M/$f" && adb shell rm /data/local/tmp/$f
done
adb shell "run-as $APP sh -c 'echo $M > files/Models/$M/.checked'"
adb shell "run-as $APP ls -la files/Models/$M"

# the clip and a project with it (the iPhone's project.json shape)
adb push android/ci/speech/speech.mp4 /data/local/tmp/speech.mp4
adb shell "run-as $APP sh -c 'mkdir -p files/Media files/Projects && cp /data/local/tmp/speech.mp4 files/Media/speech.mp4'"
D=$(ffprobe -v error -show_entries format=duration -of csv=p=0 android/ci/speech/speech.mp4)
cat > /tmp/p.json <<JSON
{"id":"00000000-0000-0000-0000-00000000A0C1","name":"Titulky test","created":785000000,"modified":785000000,
 "canvas":{"ratioW":9,"ratioH":16},
 "clips":[{"id":"00000000-0000-0000-0000-00000000B0C1","mediaFile":"speech.mp4","sourceDuration":$D,"inPoint":0,"outPoint":$D,
           "volume":1,"fill":false,"speed":1,"pitchCorrect":true}],
 "captionTracks":[],"overlays":[],"audio":[]}
JSON
adb push /tmp/p.json /data/local/tmp/p.json
adb shell "run-as $APP cp /data/local/tmp/p.json files/Projects/00000000-0000-0000-0000-00000000A0C1.json"

adb shell am start -W -n $APP/.app.MainActivity
sleep 5
python3 android/ci/tap.py "Titulky test"
sleep 5
adb exec-out screencap -p > $OUT/01-editor.png
python3 android/ci/tap.py "Titulky" || python3 android/ci/tap.py "Captions"
sleep 3
adb exec-out screencap -p > $OUT/02-panel.png
python3 android/ci/tap.py "Vytvořit titulky" || python3 android/ci/tap.py "Generate captions"
START=$(date +%s)
for i in $(seq 1 100); do
  sleep 6
  [ $i = 2 ] && adb exec-out screencap -p > $OUT/03-working.png
  adb shell "run-as $APP cat files/Projects/00000000-0000-0000-0000-00000000A0C1.json" > $OUT/project.json
  if grep -q '"words":\[{' $OUT/project.json; then break; fi
done
echo "seconds: $(( $(date +%s) - START ))" > $OUT/time.txt
sleep 2
adb exec-out screencap -p > $OUT/04-done.png
python3 - <<PY > $OUT/words.txt
import json
p=json.load(open("$OUT/project.json"))
for t in p.get("captionTracks", []):
    print(" ".join(w["text"] for w in t["words"]))
    for w in t["words"]: print(f'{w["start"]:.2f}-{w["end"]:.2f} {w["text"]}')
    print("lines:", [c["text"] for c in t["cues"]])
PY
cat $OUT/words.txt $OUT/time.txt
adb logcat -d | grep -iE "Bombocut|sherpa|onnx" | tail -120 > $OUT/log.txt || true
adb logcat -d -b crash > $OUT/crash.txt || true
