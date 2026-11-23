import SwiftUI

// MARK: Chroma key (Mask panel)

extension EditorModel {
    /// The chroma key of what the Mask panel works on: the selected layer, Stack or clip.
    var editedKey: ChromaKey? {
        if let oi = selectedOverlayIndex { return project.overlays[oi].isMedia ? project.overlays[oi].key : nil }
        if let k = selectedStackIndex { return project.stacks[k].key }
        if let i = selectedIndex { return project.clips[i].key }
        return nil
    }

    /// The id the matte view and the outline go by.
    private var keyTarget: UUID? { selectedOverlayID ?? selectedStackID ?? selectedClipID }

    /// Off (nil), or on with a screen color: green / blue presets or a picked one. Settings stay when the color
    /// changes. One undo step.
    func setKey(_ color: RGBA?) {
        mutateLook { p in
            func change(_ k: inout ChromaKey?) {
                guard let color else { k = nil; return }
                var n = k ?? ChromaKey()
                n.color = color
                k = n
            }
            if let oi = selectedOverlayIndex, p.overlays[oi].isMedia { change(&p.overlays[oi].key) }
            else if let k = selectedStackIndex { change(&p.stacks[k].key) }
            else if let i = selectedIndex { change(&p.clips[i].key) }
        }
        if color == nil && keyMatteOn { keyMatteOn = false }
        // the subject mask outline would hide what the key does
        maskOutlineHidden = true
    }

    /// Live change (sliders); pair with liveEditBegan / liveEditEnded.
    func editKey(_ change: (inout ChromaKey) -> Void) {
        if let oi = selectedOverlayIndex {
            guard var k = project.overlays[oi].key else { return }
            change(&k)
            project.overlays[oi].key = k
        } else if let s = selectedStackIndex {
            guard var k = project.stacks[s].key else { return }
            change(&k)
            project.stacks[s].key = k
        } else if let i = selectedIndex {
            guard var k = project.clips[i].key else { return }
            change(&k)
            project.clips[i].key = k
        } else { return }
        publishLook()
    }

    /// The eyedropper for the key color: every key is off in the preview while picking, so the screen itself
    /// shows (with the key on, the finger would land on what is behind it).
    func pickKeyColor() {
        LookStore.shared.bypassKey = true
        refreshFrame()
        startEyedropper { [weak self] c in
            self?.setKey(RGBA(r: c.r, g: c.g, b: c.b))
        }
    }

    func updateKeyMatte() {
        let id = keyMatteOn ? keyTarget : nil
        guard LookStore.shared.keyMatte != id else { return }
        LookStore.shared.keyMatte = id
        refreshFrame()
    }
}
