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
| Home/HomeView.swift | home/HomeView.kt | | stub |
| Model/Models.swift | model/Models.kt | | - |
| Model/Look.swift | model/Look.kt | | - |
| Model/Motion.swift | model/Motion.kt | | - |
| Model/Overlay.swift | model/Overlay.kt | | - |
| Model/Anim.swift | model/Anim.kt | | - |
| Model/Audio.swift | model/Audio.kt | | - |
| Model/Captions.swift | model/Captions.kt | | - |
| Model/Stack.swift | model/Stack.kt | | - |
| Model/Filter.swift | model/Filter.kt | | - |
| Model/ChromaKey.swift | model/ChromaKey.kt | | - |
| Model/Pin.swift | model/Pin.kt | | - |
| Model/SafeZone.swift | model/SafeZone.kt | | - |
| Model/FrameGuides.swift | model/FrameGuides.kt | | - |
| Model/Defaults.swift | model/Defaults.kt | | - |
| Model/FontCatalogData.swift | model/FontCatalogData.kt | | - |
| Model/ProjectFile.swift | model/ProjectFile.kt | | - |
| Model/Storage.swift | model/Storage.kt | | - |
| Engine/Beats.swift (BeatDetector) | engine/Beats.kt | | - |
| Engine/Silence.swift | engine/Silence.kt | | - |
| Editor/EditEffort.swift | editor/EditEffort.kt | | - |
| Editor/EditorModel.swift | editor/EditorModel.kt | | - |
| Engine/CompositionBuilder.swift | engine/CompositionBuilder.kt | | - |

## Notes for the JSON contract
- Swift's default JSONEncoder: dates are seconds since 2001-01-01 (Double), UUIDs upper case, CGPoint / CGSize as `[a, b]`, CGRect as `[[x, y], [w, h]]`.
- Decoding is tolerant on iOS (missing keys get defaults): Kotlin uses `ignoreUnknownKeys` and default values the same way.
- Swift `String(format:)` always writes a dot: Kotlin uses `fmt(...)` (Locale.ROOT), never plain `String.format`.
