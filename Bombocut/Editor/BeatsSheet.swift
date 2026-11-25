import SwiftUI

/// Beats: a small panel for the selected sound. Pick which beats are marked (every bar down to 1/16) and see them
/// right away on a piece of the sound (4 bars from the playhead), the same marks the timeline and the snapping use.
struct BeatsSheet: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var cache = BeatCache.shared
    @ObservedObject private var waves = WaveformCache.shared

    private var sound: AudioItem? { model.selectedAudioIndex.map { model.project.audio[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let a = sound {
                strip(a)
                notes(a)
                Text(verbatim: note(a))
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Select a sound first.").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    /// Off, then 1/1 to 1/16 (lime: the one in use).
    private func notes(_ a: AudioItem) -> some View {
        let on = a.beatsOn == true
        let current = a.beatNote ?? 4
        return HStack(spacing: 6) {
            pill(loc("Off"), lit: !on) { model.setBeats(false) }
            ForEach(BeatGrid.notes, id: \.self) { n in
                pill("1/\(n)", lit: on && current == n) { model.setBeatNote(n) }
            }
        }
    }

    private func pill(_ title: String, lit: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(lit ? .black : .white)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(lit ? Theme.accent : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The sound from the bar at (or before) the playhead, 4 bars long, with its marks.
    private func strip(_ a: AudioItem) -> some View {
        let beats = cache.beats(a.file) ?? []
        let sp = max(a.speed, 0.01)
        // where the playhead is in the file (the sound's start when the playhead is outside it)
        let here = a.inPoint + max(0, min(model.currentTime - a.start, a.duration)) * sp
        let gap = beats.count > 1 ? (beats[beats.count - 1] - beats[0]) / Double(beats.count - 1) : 0.5
        let barStart: Double = {
            guard !beats.isEmpty else { return a.inPoint }
            let k = (beats.lastIndex { $0 <= here + 0.01 } ?? 0)
            let bar = k - k % 4
            return max(a.inPoint, beats[bar])
        }()
        let fileEnd = a.inPoint + a.duration * sp
        let length = max(0.5, min(gap * 16, fileEnd - barStart))   // file seconds shown
        return GeometryReader { g in
            let px = g.size.width / CGFloat(length / sp)
            ZStack(alignment: .topLeading) {
                Theme.accent.opacity(0.85)
                if let peaks = waves.peaks(a.file) {
                    WaveformShape(peaks: peaks, from: barStart, length: length).fill(Color.black.opacity(0.55))
                }
                if a.beatsOn == true, !beats.isEmpty {
                    BeatTicks(beats: beats, note: a.beatNote ?? 4, from: barStart, speed: sp, length: length / sp, px: px)
                        .fill(Color.black)
                        .scaleEffect(x: 1, y: 2.2, anchor: .top)   // taller notches here, easier to count
                }
                if model.currentTime >= a.start && model.currentTime <= a.end {
                    let x = CGFloat((here - barStart) / sp) * px
                    if x >= 0 && x <= g.size.width {
                        Rectangle().fill(.white).frame(width: 2).offset(x: x - 1)
                    }
                }
            }
        }
        .frame(height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            if a.beatsOn == true && cache.reading.contains(a.file) {
                ProgressView().tint(.black)
            }
        }
    }

    private func note(_ a: AudioItem) -> String {
        guard a.beatsOn == true else { return loc("Beats are off: no marks, nothing snaps to them.") }
        if cache.reading.contains(a.file) { return loc("Finding the beats…") }
        guard let b = cache.beats(a.file), b.count >= 4 else { return loc("No steady beat found in this sound.") }
        let bpm = 60 * Double(b.count - 1) / max(b.last! - b.first!, 0.01)
        return String(format: loc("%d BPM. Cuts, texts and sounds snap to the marks."), Int(bpm.rounded()))
    }
}
