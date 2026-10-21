import SwiftUI

/// Photos-style drag selection: start on an item, move across the scroll direction to begin, then drag
/// over other items and they all get selected (or all unselected, if the first one was selected).
/// A drag that starts along the scroll direction is left to the scroll view.
struct PaintSelect<ID: Hashable>: ViewModifier {
    let ids: [ID]
    @Binding var selection: Set<ID>
    @Binding var painting: Bool
    let axis: Axis                                  // the scroll direction of the list
    let index: (CGPoint) -> Int?                    // item under a point, in the "paint" coordinate space
    var canSelect: (ID) -> Bool = { _ in true }

    @State private var anchor: Int?
    @State private var rejected = false
    @State private var target = true
    @State private var base: Set<ID> = []

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: "paint")
            .simultaneousGesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .named("paint"))
                    .onChanged { v in
                        if anchor == nil {
                            guard !rejected else { return }
                            let dx = abs(v.translation.width), dy = abs(v.translation.height)
                            let across = axis == .vertical ? dx > dy : dy > dx
                            guard across, let i = index(v.startLocation), i < ids.count, canSelect(ids[i]) else {
                                rejected = true
                                return
                            }
                            anchor = i
                            target = !selection.contains(ids[i])
                            base = selection
                            painting = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        guard let a = anchor, let j = index(v.location), j < ids.count else { return }
                        var s = base
                        for k in min(a, j)...max(a, j) where canSelect(ids[k]) {
                            if target { s.insert(ids[k]) } else { s.remove(ids[k]) }
                        }
                        if s != selection {
                            selection = s
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                    .onEnded { _ in
                        anchor = nil
                        rejected = false
                        painting = false
                    }
            )
    }
}

extension View {
    func paintSelect<ID: Hashable>(ids: [ID], selection: Binding<Set<ID>>, painting: Binding<Bool>, axis: Axis,
                                   canSelect: @escaping (ID) -> Bool = { _ in true },
                                   index: @escaping (CGPoint) -> Int?) -> some View {
        modifier(PaintSelect(ids: ids, selection: selection, painting: painting, axis: axis, index: index, canSelect: canSelect))
    }
}
