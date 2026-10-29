import Foundation

/// Settings > Defaults: how new things start out (each can still be changed one by one in the editor).
enum Defaults {
    private static var store: UserDefaults { .standard }

    /// Length of a new transition between clips (seconds).
    static var transitionLength: Double {
        get { store.object(forKey: "defTransition") as? Double ?? 0.5 }
        set { store.set(newValue, forKey: "defTransition") }
    }

    /// How long an imported photo is held (seconds).
    static var stillLength: Double {
        get { store.object(forKey: "defStill") as? Double ?? StillVideo.defaultDuration }
        set { store.set(newValue, forKey: "defStill") }
    }

    /// Length of a new text or picture on the layers lane (seconds).
    static var layerLength: Double {
        get { store.object(forKey: "defLayer") as? Double ?? 3 }
        set { store.set(newValue, forKey: "defLayer") }
    }

    /// New clips fill the frame (cropping the edges) instead of fitting inside it.
    static var fillNewClips: Bool {
        get { store.bool(forKey: "defFill") }
        set { store.set(newValue, forKey: "defFill") }
    }

    /// The clip quick menu (tap a selected clip again): actions from the clip toolbar, in order.
    static var quickActions: [QuickAction] {
        get {
            guard let s = store.string(forKey: "quickActions") else { return QuickAction.standard }
            return s.split(separator: ",").compactMap { QuickAction(rawValue: String($0)) }
        }
        set { store.set(newValue.map(\.rawValue).joined(separator: ","), forKey: "quickActions") }
    }
}

/// One tool of the clip toolbar, for the quick menu.
enum QuickAction: String, CaseIterable, Identifiable {
    case split, adjust, speed, slip, crop, autoZoom, captions, track, mask, stabilize, motionBlur
    case transition, freeze, reverse, fill, duplicate, copyAsOverlay, soundFromVideo, speech, volume, delete

    var id: String { rawValue }
    static let standard: [QuickAction] = [.transition, .volume, .duplicate, .copyAsOverlay, .delete]
    static let most = 5

    var icon: String {
        switch self {
        case .split: return "scissors"
        case .adjust: return "slider.horizontal.3"
        case .speed: return "speedometer"
        case .slip: return "arrow.left.and.line.vertical.and.arrow.right"
        case .crop: return "crop"
        case .autoZoom: return "plus.magnifyingglass"
        case .captions: return "captions.bubble"
        case .track: return "scope"
        case .mask: return "person.crop.rectangle"
        case .stabilize: return "gyroscope"
        case .motionBlur: return "wind"
        case .transition: return "arrow.left.and.right.square"
        case .freeze: return "snowflake"
        case .reverse: return "backward"
        case .fill: return "arrow.up.left.and.arrow.down.right"
        case .duplicate: return "plus.square.on.square"
        case .copyAsOverlay: return "square.on.square.dashed"
        case .soundFromVideo: return "waveform.badge.plus"
        case .speech: return "person.wave.2"
        case .volume: return "speaker.wave.2"
        case .delete: return "trash"
        }
    }

    var title: String {
        switch self {
        case .split: return "Split"
        case .adjust: return "Adjust"
        case .speed: return "Speed"
        case .slip: return "Slip"
        case .crop: return "Crop"
        case .autoZoom: return "AutoZoom"
        case .captions: return "Captions"
        case .track: return "Track"
        case .mask: return "Mask"
        case .stabilize: return "Stabilize"
        case .motionBlur: return "Motion blur"
        case .transition: return "Transition"
        case .freeze: return "Freeze"
        case .reverse: return "Reverse"
        case .fill: return "Fill"
        case .duplicate: return "Duplicate"
        case .copyAsOverlay: return "Copy as overlay"
        case .soundFromVideo: return "Sound from video"
        case .speech: return "Speech"
        case .volume: return "Volume"
        case .delete: return "Delete"
        }
    }

    /// Only in the full (Pro) interface, like on the toolbar.
    var pro: Bool {
        switch self {
        case .adjust, .autoZoom, .track, .mask, .stabilize, .motionBlur, .transition, .copyAsOverlay, .soundFromVideo: return true
        default: return false
        }
    }

    /// Works on held pictures (photos, freeze frames) too.
    var forStills: Bool {
        switch self {
        case .captions, .stabilize, .motionBlur, .freeze, .reverse, .soundFromVideo, .speech, .volume, .slip: return false
        default: return true
        }
    }
}
