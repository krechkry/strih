import SwiftUI

/// First launch (and Settings): which languages you caption, and the one speech model that covers them.
struct LanguageSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var speech = SpeechModels.shared
    @State private var askCellular = false
    @State private var picked: Set<String> = Prefs.languages
    var firstLaunch = false

    private let options: [(String, String, String)] = [("cs", "Čeština", "🇨🇿"), ("sk", "Slovenčina", "🇸🇰"), ("en", "English", "🇬🇧")]

    private var model: SpeechModel { SpeechModel.needed(for: picked) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(firstLaunch ? "Welcome to Bombocut" : "Captions").font(.title2.weight(.heavy))
                Spacer()
                if !firstLaunch {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.body.weight(.bold))
                            .frame(width: 36, height: 36)
                            .background(Theme.panel2, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Which languages do you speak in your videos? Bombocut downloads only the speech model you need. Captions then run on your iPhone, offline.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.muted)

            VStack(spacing: 10) {
                ForEach(options, id: \.0) { o in
                    let on = picked.contains(o.0)
                    Button {
                        if on { if picked.count > 1 { picked.remove(o.0) } } else { picked.insert(o.0) }
                    } label: {
                        HStack(spacing: 12) {
                            Text(o.2).font(.title2)
                            Text(o.1).font(.headline.weight(.bold))
                            Spacer()
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(on ? Theme.accent : Theme.muted)
                        }
                        .padding(.horizontal, 16).frame(height: 58)
                        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(on ? Theme.accent : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }

            modelCard

            Spacer(minLength: 0)

            Button {
                Prefs.languages = picked
                if !speech.isReady(model) && NetworkWatch.shared.onMobileData {
                    askCellular = true
                } else {
                    speech.startDownload(model)
                    dismiss()
                }
            } label: {
                Text(speech.isReady(model) ? "Done" : "Download now")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            if !speech.isReady(model) {
                Button {
                    Prefs.languages = picked
                    dismiss()
                } label: {
                    Text("Later")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(22)
        .background(Theme.panel.ignoresSafeArea())
        .interactiveDismissDisabled(firstLaunch)
        .alert("Download on mobile data?", isPresented: $askCellular) {
            Button("Download anyway") { speech.startDownload(model); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The speech model is about 650 MB. Wi-Fi is better.")
        }
    }

    private var modelCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Speech model: \(model.title)").font(.subheadline.weight(.bold))
                Group {
                    switch speech.state(model) {
                    case .ready: Text("On your iPhone")
                    case .downloading(let f): Text("Downloading \(Int(f * 100)) %")
                    case .failed(let e): Text("Download failed: \(e)")
                    case .missing: Text("\(model.sizeLabel), downloaded once. Wi-Fi recommended.")
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.muted)
            }
            Spacer()
            if case .ready = speech.state(model), !firstLaunch {
                Button(role: .destructive) { speech.delete(model) } label: {
                    Image(systemName: "trash").font(.body.weight(.semibold))
                }
                .tint(.red)
            }
        }
        .padding(16)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
    }
}
