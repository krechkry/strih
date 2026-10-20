# Bombocut

A no-nonsense iPhone video editor. Edits-style layout, CapCut-grade speed retiming, on-device Czech/Slovak/English captions, full export control. No AI gimmicks, no filter packs.

Target: iPhone 16 Pro, iOS 18+.

## Build it (on the Mac, ~10 min the first time)

1. Install **Xcode** from the App Store, open it once and let it install the iOS components.
2. Install XcodeGen: `brew install xcodegen`
3. Unzip, then in Terminal:
   ```
   cd strih   # (the repo folder)
   xcodegen
   open Bombocut.xcodeproj
   ```
4. Xcode → Settings → Accounts → add your Apple ID.
5. Click the **Bombocut** target → Signing & Capabilities → pick your Team. If the bundle id is taken, change `cz.krechler.bombocut` to anything unique.
6. Plug in the iPhone. On the phone: Settings → Privacy & Security → **Developer Mode** → on (it restarts).
7. Pick the iPhone at the top of Xcode and press ▶ Run.
8. First launch only: on the phone, Settings → General → VPN & Device Management → trust your developer profile.

With a free Apple ID the app stops opening after 7 days; just press Run again. A paid developer account ($99/yr) removes that and enables TestFlight.

The code was written without access to a Mac, so the first build may show a few compile errors. Paste them back to Claude and they'll get fixed.

## Updating (after the one-time setup)

```
~/strih/update.sh      # pulls the newest code, regenerates the project, keeps your signing team
```
Then press ▶ in Xcode.

## What's in it

**Editing**
- Projects list, import from Photos (pick order, original quality) or Files
- Edits-style editor: preview on top, fixed center playhead, filmstrip timeline, pinch to zoom
- Ripple trim like DaVinci trim mode: clips stay glued, two-up trim viewer, +/− badge, cut/added band
- Split, duplicate, delete, volume, fit/fill, undo/redo, autosave
- Hold a clip and slide it to reorder (the strip zooms out so the neighbours are visible); captions travel with their footage
- Tap a clip the playhead isn't on and the playhead jumps to its nearest edge
- Canvas: 9:16, 4:5, 1:1, 4:3, 16:9, 2.39:1 (labelled presets)

**Preview**
- Drag / pinch / twist the clip under the playhead around your fingers, with snapping (center, edges, 100%, fill, straight angles); zooming far past the canvas is fine
- Double-tap for fullscreen: tap = play/pause, double-tap = exit, no UI while playing (for screen recording)

**Speed**
- Constant 0.1x to 100x, custom curve with draggable points (no presets), keep pitch on/off per clip
- Curve: tap the line to add a point, drag anywhere else to scrub, points snap to the playhead, play loops the selected clip

**Keyframes + effects**
- Exposure, contrast, saturation, temperature, tint, highlights, shadows, vignette, chromatic aberration, animated grain, opacity
- Keyframes for all of that plus move/scale/rotate, smooth or linear easing; diamonds on the timeline

**Captions (on device)**
- Czech, Slovak, English with WhisperKit; first launch asks which languages and downloads only the needed model
- Model warms up in the background when the app opens
- Word timings (checked against Whisper's segment times, repaired when they drift), Titulky line cutting (no dangling Czech prepositions), editable text
- Templates: Clean, Punch, Box + your own; animations: fade, pop, slide up, word highlight, word by word, typewriter

**Stabilize + track**
- Stabilization from measured camera shake, strength slider, automatic zoom to hide edges
- Tap or roughly box a subject: the phone finds the person / object and draws a box you can move and resize, then tracks forward and backward through the clip, re-finding the subject if it gets lost; keep it centered or in place (auto reframe 16:9 → 9:16)

**Export**
- 144p to 4K or any custom size, 12 to 120 fps or custom, auto or manual bitrate, H.264 / HEVC, straight to Photos
