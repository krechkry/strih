import SwiftUI

/// Crop of the selected clip, Stack or picture / video layer, in tabs: Rectangle (drag the lime edges on the
/// preview; softness, rounded corners), Ellipse (drag it, its handles or pinch on the preview) and Curve (tap the
/// video to add points, drag them). Ellipse and Curve have a soft edge and can keep the outside instead. It works
/// on the picture itself (before stabilization, tracking and masks).
struct CropSheet: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.editsCrop {
                let c = model.editedCrop ?? CropRect()
                HStack {
                    Text("Crop").font(.title3.weight(.heavy))
                    Spacer()
                    Button { reset(c) } label: {
                        Image(systemName: "arrow.counterclockwise").font(.subheadline.weight(.bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 36, height: 36)
                            .background(Theme.panel2, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(loc("Reset"))
                }
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
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
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

    /// Reset: the shape being edited starts over (the others stay as they are).
    private func reset(_ c: CropRect) {
        var n = c
        switch c.kind {
        case .rect: model.setCrop(nil); return
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
