# Meme art

The Bombocut identity: real memes traced into one lime color on transparent. Where a meme
shows a real person or someone else's character, a new dumb blob does the same pose.

- `gen.py`: every meme as a flat drawing (white = lime, black = cut out). Makes the stills.
- `layers.py`: the same drawings split into moving parts (arms, hands, eyes, props) with
  their pivots and motion. A part can cut a gap into the parts under it.
- `swiftgen.py`: writes `Bombocut/Editor/MemeArt.swift`, which `MemeView` draws and animates live.
- `animcheck.py`: renders motion frames with the same math as the app and checks that the
  still frame matches the approved art.
- `svg/`: the approved stills.

Change a drawing or a motion in `layers.py` (and `gen.py` for the still), then run `./build.sh`.

In the app: `MemeView(meme: .absoluteCinema)`. `-demo memes` shows the whole cast.
