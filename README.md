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

## Stage 1 (this build)

- Projects list, import from Photos (in pick order, original quality) or Files (FX30 footage etc.)
- Edits-style editor: preview on top, fixed center playhead, filmstrip timeline
- Swipe to scrub, pinch to zoom, tap a clip to select
- Trim by dragging the yellow clip edges (preview shows the frame you're on)
- Split at playhead, duplicate, move left/right, delete, per-clip volume, fit/fill
- Canvas: 9:16, 16:9, 1:1, 4:5, 4:3, 3:4, 2.39:1, 21:9 or any custom ratio
- Undo/redo for everything, autosave
- Export: 144p to 4K or any custom resolution, frame rates 12 to 120 or custom, bitrate (auto or manual), H.264 or HEVC, saves straight to Photos plus share sheet
- iPhone HDR footage is converted to standard SDR (HDR export can come later)

## Roadmap

**Stage 2: Speed**
- Constant speed 0.1x to 100x
- Custom speed curve: draggable points on a graph, no presets
- Pitch correction on/off

**Stage 3: Keyframes + effects**
- Keyframes for position, scale, rotation, opacity with easing
- Color adjustments: exposure, contrast, saturation, temperature, tint, highlights, shadows
- Vignette, chromatic aberration, dynamic (animated) grain, all keyframable

**Stage 4: Captions**
- Czech, Slovak, English, transcribed on the phone (WhisperKit, offline)
- First launch asks which caption languages you want and downloads only that model
- 3 built-in templates, plus your own templates with font, colors, outline, box, position, words per line and simple timed animations (pop, fade, slide, word highlight, typewriter)
- Same short-line cutting and Czech typography rules as Titulky

**Stage 5: Stabilization + tracking**
- Stabilization with strength slider and auto crop
- Subject tracking: draw a box around anything, then keep it framed or pin captions/elements to it
