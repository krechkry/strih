# BOMBOCUT Android: port ledger

The iPhone app is the reference. Every Swift file gets a row: its Kotlin twin, the iOS commit the Kotlin
matches, and its status. When an iOS file changes after that commit, `git diff <commit> -- <swift file>`
is what the Android twin still needs. Plan: `strih/android-plan.md` (Project doc).

iOS base: ad3827a (1.3 with Beats, Remove silence, the speed-curve fix).

Status: 1:1 = same logic, parity-tested where a fixture exists. rework = Android machinery, same model.
stub = placeholder. - = not started.

| Swift | Kotlin | iOS commit | Status |
|---|---|---|---|
| App/BombocutApp.swift (Theme, Fmt, loc) | app/BombocutApp.kt | ad3827a | 1:1 (Fmt tested) |
| Model/Languages.swift (AppLanguage) | app/AppLanguage.kt | ad3827a | rework (reads the xcstrings asset) |
| Model/Languages.swift (CaptionLanguage) | model/Languages.kt | a28b16c | 1:1 (the 25 languages) |
| Engine/Speech.swift (Transcriber, SpeechEngine) | engine/Transcriber.kt | a28b16c | `words` 1:1; rework: Transformer 16 kHz mono export, sherpa-onnx (Parakeet Ultra int8), ~20 s pieces cut at quiet spots; not yet: SpellCheck, typed names, one line heard again |
| Engine/ModelDownload.swift + SpeechModels | engine/SpeechModel.kt | a28b16c | rework: HTTPS Range resume, size + SHA-256 per file; not yet: Storage screen, pause button, mobile-data question |
| Editor/CaptionsSheet.swift (generate page) | editor/CaptionsSheet.kt | a28b16c | rework: language, Generate / Generate again / New captions track, phases, cancel; not yet: pick clips, names, translation |
| Home/HomeView.swift | home/HomeView.kt | ad3827a | partly: list, sort, new project, rename, delete (not yet: share / .bbc, iCloud rows, trial pill, import game) |
| Model/Models.swift | model/Models.kt + model/Project.kt | ad3827a | 1:1 (parity: timing.json, projects.json) |
| Model/Look.swift | model/Look.kt | ad3827a | 1:1 data + math (LookState for the compositor comes with the look engine) |
| Model/Motion.swift | model/Motion.kt | ad3827a | 1:1 |
| Model/Overlay.swift | model/Overlay.kt + Project.kt (rows) | ad3827a | 1:1 except placeNewOverlay / moveOverlay, remapOverlays (with Captions remap) |
| Model/Anim.swift | model/Anim.kt | ad3827a | 1:1 |
| Model/Audio.swift | model/Audio.kt | ad3827a | Fade, AudioItem 1:1; extractRetimed / sound engine: rework |
| Model/Captions.swift | model/Captions.kt + Color.kt | ad3827a | data only; CaptionCutter, split / merge / restyle, locate / timeline / remap: next |
| Model/Stack.swift | model/Stack.kt + Project.kt | ad3827a | 1:1 |
| Model/Filter.swift | model/Filter.kt | ad3827a | stored types 1:1; FilterLibrary / LUT formulas with the look engine |
| Model/ChromaKey.swift | model/ChromaKey.kt | ad3827a | 1:1 |
| Model/Pin.swift | model/Pin.kt | ad3827a | stored types; PinPath math with tracking |
| Model/SafeZone.swift | model/SafeZone.kt | | - |
| Model/FrameGuides.swift | model/FrameGuides.kt | | - |
| Model/Defaults.swift | model/Defaults.kt + app/PrefsSettings.kt | ad3827a | 1:1 (QuickAction with the editor) |
| Model/FontCatalogData.swift | model/FontCatalogData.kt | | - |
| Model/ProjectFile.swift | model/ProjectFile.kt | | - |
| Model/Storage.swift | model/Storage.kt | ad3827a | rework: same folders and JSON; photos as clips (StillVideo) not yet |
| Engine/SpeechCleanup.swift (SpeechFX) | model/Speech.kt | ad3827a | stored settings 1:1; engine: rework |
| Engine/Beats.swift (BeatDetector) | engine/Beats.kt | | - |
| Engine/Silence.swift | engine/Silence.kt | | - |
| Editor/EditEffort.swift | editor/EditEffort.kt | | - |
| Editor/EditorModel.swift | editor/EditorModel.kt | ad3827a | part 1: undo / redo, split, delete, duplicate, move, ripple trim, speed, volume, adjust |
| Engine/CompositionBuilder.swift | engine/CompositionBuilder.kt | ad3827a | rework on Media3: clips, speed curves, pitch, volume / fades, fit / fill, sound items (audio sequences), transitions as A / B rolls through the compositor (every iOS shape, handles, sound crossfade; Pop on top via roll choice), video layers as their own compositor inputs (placement, keyframes, in / out animations, speed / curve, volume); video inputs never use Media3 gaps (black filler clip); not yet: video layers' look / crop / mask / blend mode / z-order among picture and text layers, motion blur in transitions |
| Engine/EffectsRenderer.swift (color) | engine/LookMath.kt + LookLut.kt | ad3827a | 1:1 math as a 33-point LUT: exposure, contrast, saturation, temperature, tint, shadows, highlights match colors.json within 3 levels (4 for white balance) |
| Engine/CaptionRenderer.swift + OverlayRenderer text | engine/TextRenderer.kt + TextLayer.kt | ad3827a | rework on Canvas: size, wrap, box, outline, shadow, keyframes, in / out animations, caption fade / pop / slide; not yet: app fonts, per-word animations, pinned texts |
| Model/Captions.swift CaptionCutter, absorbEdits, restyle | model/CaptionCutter.kt | ad3827a | 1:1, captions.json parity (130 cuts, wraps, edit-then-recut) |
| Engine/Silence.swift | engine/Silence.kt | ad3827a | 1:1 math + MediaCodec loudness, silence.json parity |
| Engine/Beats.swift BeatDetector, BeatCache | engine/BeatDetector.kt | ad3827a | 1:1 (plain FFT), beats.json parity |
| Model/ProjectFile.swift (.bbc) | model/ProjectFile.kt | ad3827a | open + share (format 1, everything inside); fonts / LUTs / light files not yet |
| App/Purchases.swift + PaywallView | app/Purchases.kt + home/Paywall.kt | ad3827a | rework on Play Billing 8.3: trial kept on the phone (Play trials are subscription-only), one-time product cz.krechler.bombocut.full |

## Notes for the JSON contract
- Swift's default JSONEncoder: dates are seconds since 2001-01-01 (Double), UUIDs upper case, CGPoint / CGSize as `[a, b]`, CGRect as `[[x, y], [w, h]]`.
- Decoding is tolerant on iOS (missing keys get defaults): Kotlin uses `ignoreUnknownKeys` and default values the same way.
- Swift `String(format:)` always writes a dot: Kotlin uses `fmt(...)` (Locale.ROOT), never plain `String.format`.

## Decode tolerance (known difference)
iOS reads many nested values with `try?` (a broken value becomes nil, the project still opens). kotlinx.serialization
fails the whole project on a broken nested value. Fine for files iOS wrote; revisit if a real project fails to open.
