import SwiftUI

/// What a key on a hardware keyboard (iPad Magic Keyboard, any Bluetooth keyboard) does in the editor.
enum EditorKey {
    case play
    case frame(Int)          // one frame back / forward
    case second(Int)         // one second back / forward
    case cut(Int)            // to the previous / next cut
    case start, end
    case undo, redo
    case split, duplicate, delete
    case keyframe
    case done                // Return: finish what is open (a panel, slipping, picking, the selection)
    case close               // Escape: back out of it
    case zoom(Int)           // timeline in / out
    case export, fullscreen
}

/// The open editor's keys, handed to the app's menus (iPad menu bar, the list that shows when ⌘ is held).
struct EditorKeys {
    /// Off while typing or while something covers the editor (export, the gallery).
    var enabled: Bool
    var hasClips: Bool
    var canUndo: Bool
    var canRedo: Bool
    var canSplit: Bool
    var canDuplicate: Bool
    var canDelete: Bool
    var canKeyframe: Bool
    let run: (EditorKey) -> Void
}

private struct EditorKeysKey: FocusedValueKey {
    typealias Value = EditorKeys
}

extension FocusedValues {
    var editorKeys: EditorKeys? {
        get { self[EditorKeysKey.self] }
        set { self[EditorKeysKey.self] = newValue }
    }
}

/// The editor's menus and keyboard shortcuts. On iPad they show in the menu bar and in the list that appears
/// while ⌘ is held; the keys work on iPhone too with a keyboard connected.
struct EditorCommands: Commands {
    @FocusedValue(\.editorKeys) private var keys

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            item("Undo", "z", .command, .undo, keys?.canUndo)
            item("Redo", "z", [.command, .shift], .redo, keys?.canRedo)
        }
        CommandGroup(after: .undoRedo) {
            Divider()
            item("Split", "b", .command, .split, keys?.canSplit)
            item("Duplicate", "d", .command, .duplicate, keys?.canDuplicate)
            item("Delete", .delete, [], .delete, keys?.canDelete)
            item("Add or delete keyframe", "k", .command, .keyframe, keys?.canKeyframe)
        }
        CommandGroup(after: .importExport) {
            item("Export", "e", .command, .export, keys?.hasClips)
        }
        CommandMenu(loc("Playback")) {
            item("Play / Pause", .space, [], .play, keys?.hasClips)
            Divider()
            item("Previous frame", .leftArrow, [], .frame(-1), keys?.hasClips)
            item("Next frame", .rightArrow, [], .frame(1), keys?.hasClips)
            item("Back 1 second", .leftArrow, .shift, .second(-1), keys?.hasClips)
            item("Forward 1 second", .rightArrow, .shift, .second(1), keys?.hasClips)
            item("Previous cut", .upArrow, [], .cut(-1), keys?.hasClips)
            item("Next cut", .downArrow, [], .cut(1), keys?.hasClips)
            item("Go to start", .home, [], .start, keys?.hasClips)
            item("Go to end", .end, [], .end, keys?.hasClips)
            Divider()
            item("Zoom timeline in", "=", .command, .zoom(1), keys?.hasClips)
            item("Zoom timeline out", "-", .command, .zoom(-1), keys?.hasClips)
            item("Full screen", "f", [], .fullscreen, keys?.hasClips)
            Divider()
            item("Done", .return, [], .done, true)
            item("Close", .escape, [], .close, true)
        }
    }

    private func item(_ title: String, _ key: KeyEquivalent, _ mods: EventModifiers, _ k: EditorKey,
                      _ can: Bool?) -> some View {
        // in the app's language (set in Settings), like the rest of the UI
        Button(loc(title)) { keys?.run(k) }
            .keyboardShortcut(key, modifiers: mods)
            .disabled(!(keys?.enabled ?? false) || !(can ?? false))
    }
}
