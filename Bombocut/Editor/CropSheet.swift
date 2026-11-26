import SwiftUI

/// The Transform panel of the selected clip, Stack or picture / video layer, in three tabs:
/// Transform (position, scale, stretch, rotation, anchor point, mirror; the same values the fingers on the preview
/// change), Crop (Rectangle: drag the lime edges on the preview, softness, rounded corners; Ellipse: drag it, its
/// handles or pinch; Curve: tap the video to add points, drag them; Ellipse and Curve have a soft edge and can keep
/// the outside instead; the crop works on the picture itself, before stabilization, tracking and masks) and 3D
/// (the whole picture turned as a card, after crop and the flat placement). Mirror is stored with the crop and
/// flips the picture as it is placed, so the crop stays on the same footage.
struct CropSheet: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.editsTransform {
                let c = model.editedCrop ?? CropRect()
                // text layers have no picture to crop: Transform and 3D only
                let crops = model.editsCrop
                let tab: TransformTab = !crops && model.transformTab == .crop ? .transform : model.transformTab
                HStack(spacing: 6) {
                    panelTab("Transform", .transform, shown: tab)
                    if crops { panelTab("Crop", .crop, shown: tab) }
                    panelTab("3D", .threeD, shown: tab)
                    Spacer(minLength: 4)
                    Button { reset(c, tab) } label: {
                        Image(systemName: "arrow.counterclockwise").font(.subheadline.weight(.bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 36, height: 36)
                            .background(Theme.panel2, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(loc("Reset this tab"))
                }
                switch tab {
                case .transform:
                    TransformTabView(model: model)
                case .crop:
                    cropTab(c)
                case .threeD:
                    ThreeDTabView(model: model)
                }
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        // a text layer opened while the Crop tab was the last one: it starts on Transform (texts have no crop)
        .onAppear { if !model.editsCrop && model.transformTab == .crop { model.transformTab = .transform } }
    }

    /// Transform | Crop | 3D, the app's tab capsules (lime and bold when picked).
    private func panelTab(_ title: String, _ tab: TransformTab, shown: TransformTab) -> some View {
        let on = shown == tab
        return Button {
            guard !on else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            model.transformTab = tab
        } label: {
            Text(loc(title)).font(.subheadline.weight(on ? .heavy : .bold))
                .foregroundStyle(on ? .black : .white)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 13).frame(height: 36)
                .background(on ? Theme.accent : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func cropTab(_ c: CropRect) -> some View {
        tabs(c)
        switch c.kind {
        case .rect:
            hint("Drag the lime edges on the preview, or inside the frame to move it.")
            slider("Softness", c.softness) { v in model.editCrop { $0.softness = v } }
            slider("Rounded corners", c.radius) { v in model.editCrop { $0.radius = v } }
        case .ellipse:
            hint("Drag the ellipse to move it, its lime handles or two fingers to size it.")
            shapeControls(c)
        case .curve:
            hint(c.points.count < 3 ? "Tap the video to add points around what you want to keep."
                                    : "Tap to add points, drag them to adjust, double tap one to remove it. Drag inside to move it all.")
            shapeControls(c)
        }
        if model.selectedStackIndex == nil && model.selectedOverlayIndex == nil { ApplyRow(model: model, kind: .crop) }
    }

    private func tabs(_ c: CropRect) -> some View {
        HStack(spacing: 6) {
            tab("Rectangle", "rectangle", .rect, c)
            tab("Ellipse", "circle", .ellipse, c)
            tab("Curve", "scribble", .curve, c)
        }
    }

    private func tab(_ title: String, _ icon: String, _ kind: CropKind, _ c: CropRect) -> some View {
        let on = c.kind == kind
        return Button {
            guard !on else { return }
            var n = c
            n.kind = kind
            model.setCropShape(n)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold))
                Text(loc(title)).font(.subheadline.weight(.bold))
            }
            .foregroundStyle(on ? .black : .white)
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(on ? Theme.accent : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func shapeControls(_ c: CropRect) -> some View {
        slider("Feather", c.feather) { v in model.editCrop { $0.feather = v } }
        OnOffRow(title: "Invert", subtitle: "Keep the outside instead.", isOn: c.invert) { v in
            var n = c
            n.invert = v
            model.setCropShape(n)
        }
    }

    /// Reset: what the tab shows goes back (Transform: the flat placement, 3D: the turn, Crop: the shape being
    /// edited starts over, the others stay as they are). The mirror stays.
    private func reset(_ c: CropRect, _ tab: TransformTab) {
        switch tab {
        case .transform:
            model.setTransform { t in
                let keep = t
                t = ClipTransform()
                t.tiltX = keep.tiltX; t.tiltY = keep.tiltY; t.roll = keep.roll
                t.perspective = keep.perspective; t.depth = keep.depth; t.hideBack = keep.hideBack
            }
            return
        case .threeD:
            model.setTransform { t in
                t.tiltX = 0; t.tiltY = 0; t.roll = 0; t.perspective = 0.5; t.depth = 0; t.hideBack = false
            }
            return
        case .crop:
            break
        }
        var n = c
        switch c.kind {
        case .rect:
            // the shape starts over, the mirror stays
            var m = CropRect()
            m.flipX = c.flipX
            m.flipY = c.flipY
            model.setCrop(m)
            return
        case .ellipse: n.ellipse = nil
        case .curve: n.points = []
        }
        n.feather = 0
        n.invert = false
        model.setCropShape(n)
    }

    private func hint(_ s: String) -> some View {
        Text(loc(s))
            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func slider(_ title: String, _ value: Double, _ set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                Spacer()
                Text(verbatim: "\(Int((value * 100).rounded()))").font(.subheadline.weight(.bold).monospacedDigit())
                    .doubleTapNumberReset { model.liveEditBegan(); set(0); model.liveEditEnded() }
            }
            BSlider(value: Binding(get: { value }, set: set), in: 0...1,
                    onEditingChanged: { e in if e { model.liveEditBegan() } else { model.liveEditEnded() } })
                .doubleTapReset { model.liveEditBegan(); set(0); model.liveEditEnded() }
        }
    }
}
