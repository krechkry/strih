import SwiftUI

/// What a longer job is doing right now, as a checklist: one row per step (or per clip), each waiting, working
/// (with its progress when known), done or failed, with a short line saying exactly what is happening
/// ("Downloading from iCloud · 40 %", "Copying · 120 MB", "Converting · 60 %"). Shown by `WorkStepsView`.
@MainActor
final class WorkSteps: ObservableObject, Identifiable {
    enum State: Equatable {
        case waiting
        case working(Double?)
        case done
        case failed
    }

    struct Step: Identifiable, Equatable {
        let id: Int
        var title: String
        var detail: String?
        var state: State
    }

    let id = UUID()
    @Published var title: String
    @Published private(set) var steps: [Step]

    init(title: String, steps: [String]) {
        self.title = title
        self.steps = steps.enumerated().map { Step(id: $0.offset, title: $0.element, detail: nil, state: .waiting) }
    }

    /// Adds a step at the end (for jobs that learn their steps as they go); returns its index.
    @discardableResult
    func add(_ title: String) -> Int {
        steps.append(Step(id: steps.count, title: title, detail: nil, state: .waiting))
        return steps.count - 1
    }

    func rename(_ i: Int, _ title: String) {
        guard steps.indices.contains(i) else { return }
        steps[i].title = title
    }

    /// Step `i` is being worked on: what exactly, and how far (nil: not known).
    func working(_ i: Int, _ detail: String? = nil, progress: Double? = nil) {
        guard steps.indices.contains(i) else { return }
        steps[i].state = .working(progress.map { min(max($0, 0), 1) })
        if let detail { steps[i].detail = detail }
    }

    func done(_ i: Int, _ detail: String? = nil) {
        guard steps.indices.contains(i) else { return }
        steps[i].state = .done
        steps[i].detail = detail
    }

    func failed(_ i: Int, _ detail: String? = nil) {
        guard steps.indices.contains(i) else { return }
        steps[i].state = .failed
        steps[i].detail = detail
    }

    /// From any thread.
    nonisolated func update(_ i: Int, _ detail: String?, progress: Double?) {
        Task { @MainActor in self.working(i, detail, progress: progress) }
    }

    var finished: Int { steps.filter { $0.state == .done || $0.state == .failed }.count }

    // MARK: The waiting game (importing a new project, `ImportWaitView`)

    /// The ball game is on (the job took longer than 10 s).
    @Published var playing = false
    /// The ball went into the card ("the island").
    @Published private(set) var landed = false
    private var landing: CheckedContinuation<Void, Never>?

    /// Nothing waits any more and at most one step is still working: the card lights up for the last shot.
    var nearEnd: Bool {
        !steps.contains { $0.state == .waiting }
            && steps.filter { if case .working = $0.state { return true } else { return false } }.count <= 1
    }

    func land() {
        landed = true
        landing?.resume()
        landing = nil
    }

    /// The job is done: with the game on, waits until the ball goes into the card (or the card is tapped).
    func waitForLanding() async {
        guard playing, !landed else { return }
        await withCheckedContinuation { landing = $0 }
    }
}

/// The checklist card: a title with "2 of 5", then the steps, the one being worked on spinning (or a ring filling
/// up), finished ones ticked in lime, failed ones crossed in red. Long lists show 3 rows around the current one.
struct WorkStepsView: View {
    @ObservedObject var work: WorkSteps
    var cancel: (() -> Void)? = nil
    /// Just the rows, no card (inside a screen that has its own title, like Export).
    var compact = false

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(work.steps) { s in row(s) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            card
        }
    }

    /// A note under the rows ("Keep BOMBOCUT open…").
    var note: String? = nil
    /// Lit up in lime: the ball can go in (the waiting game).
    var lit = false

    private static let rowHeight: CGFloat = 46

    /// A solid block: at most 3 rows, the one being worked on in the middle, the last finished one above it and
    /// the next one below. Nothing to scroll; the rows slide up as the job moves on.
    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(loc(work.title)).font(.headline.weight(.bold))
                Spacer(minLength: 8)
                if work.steps.count > 1 {
                    Text(String(format: loc("%lld of %lld"), work.finished, work.steps.count))
                        .font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(Theme.muted)
                        .contentTransition(.numericText())
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(slots, id: \.self) { k in
                    Group {
                        if work.steps.indices.contains(k) { row(work.steps[k]) } else { Color.clear }
                    }
                    .frame(height: Self.rowHeight, alignment: .top)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .move(edge: .top).combined(with: .opacity)))
                }
            }
            .frame(height: Self.rowHeight * CGFloat(min(3, max(work.steps.count, 1))), alignment: .top)
            .clipped()
            .animation(.snappy(duration: 0.35), value: focus)
            if let note {
                Text(note)
                    .font(.footnote.weight(.semibold)).foregroundStyle(lit ? Theme.accent : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            if let cancel {
                Button(action: cancel) {
                    Text("Cancel").font(.subheadline.weight(.bold)).foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Theme.panel2, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(maxWidth: 340)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
        .background(Theme.accent.opacity(work.landed ? 0.35 : 0), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(lit ? Theme.accent : Theme.line, lineWidth: lit ? 2 : 1))
        .shadow(color: lit ? Theme.accent.opacity(0.55) : .black.opacity(0.4), radius: lit ? 26 : 20, y: lit ? 0 : 6)
        .animation(.easeInOut(duration: 0.3), value: lit)
        .animation(.easeOut(duration: 0.4), value: work.landed)
        .padding(24)
    }

    /// The row in the middle: the one being worked on, else the next waiting one, else the last.
    private var focus: Int {
        if let c = current { return c }
        if let w = work.steps.firstIndex(where: { $0.state == .waiting }) { return w }
        return max(work.steps.count - 1, 0)
    }

    /// Which rows show (an index outside the steps is an empty row, so the block keeps its size).
    private var slots: [Int] {
        work.steps.count <= 3 ? Array(work.steps.indices) : [focus - 1, focus, focus + 1]
    }

    private var current: Int? {
        work.steps.first { if case .working = $0.state { return true } else { return false } }?.id
    }

    private func row(_ s: WorkSteps.Step) -> some View {
        HStack(alignment: .top, spacing: 12) {
            mark(s.state).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(loc(s.title))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(s.state == .waiting ? Theme.muted : .white)
                    .lineLimit(1)
                if let d = s.detail {
                    Text(d)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(s.state == .failed ? Color.red : Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func mark(_ state: WorkSteps.State) -> some View {
        switch state {
        case .waiting:
            Circle().strokeBorder(Theme.muted.opacity(0.5), lineWidth: 2)
        case .working(let p?):
            ZStack {
                Circle().stroke(Theme.panel2, lineWidth: 3)
                Circle().trim(from: 0, to: max(p, 0.03))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: p)
            }
            .padding(1.5)
        case .working(nil):
            ProgressView().tint(Theme.accent).scaleEffect(0.8)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.accent)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.red)
        }
    }
}

enum WorkText {
    /// "120 MB", "1.4 GB"
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// While a file is being written: its size so far, every 0.3 s, until the returned task is cancelled.
    static func watch(_ url: URL, _ report: @escaping @Sendable (Int64) -> Void) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if let n = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber, n.int64Value > 0 {
                    report(n.int64Value)
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}

extension WorkText {
    /// "3840 × 2160", for a finished clip row.
    static func clipInfo(_ size: CGSize?) -> String? {
        guard let s = size, s.width > 0 else { return nil }
        return "\(Int(s.width)) × \(Int(s.height))"
    }
}
