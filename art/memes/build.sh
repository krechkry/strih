#!/bin/bash
# Rebuild the meme art: the still SVG/PNGs and the app's Bombocut/Editor/MemeArt.swift.
# Needs: python3 with  pip install cairosvg fonttools brotli opencv-python-headless pillow numpy
#        npm (only the first time, to fetch the two fonts)
set -e
cd "$(dirname "$0")"
if [ ! -d fonts ]; then
  mkdir -p fonts && cd fonts
  npm pack -q @fontsource/inter@5.3.0 @fontsource/abril-fatface@5.3.0 >/dev/null
  for t in *.tgz; do mkdir -p "${t%.tgz}" && tar xzf "$t" -C "${t%.tgz}"; done
  cd ..
fi
python3 gen.py stills                 # stills/*.svg + 1440 px transparent PNGs
cp stills/*.svg svg/
python3 layers.py memes.json          # the moving parts
python3 swiftgen.py memes.json ../../Bombocut/Editor/MemeArt.swift
python3 animcheck.py memes.json check stills   # check/frames.png + still-frame parity
echo "Done. Look at check/frames.png, then build the app."
