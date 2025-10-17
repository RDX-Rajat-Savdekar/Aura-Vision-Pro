//
//  ContentView.swift
//  Aura
//
//  HUD with larger layout and language picker. Translation removed.
//
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var micMonitor: MicrophoneMonitor

    // Tail rendering tuning
    @State private var transcriptTailLines: [String] = []
    private let tailMaxLines: Int = 8 // show more bubbles

    // Sound history (most recent first, up to 3)
    @State private var soundHistory: [String] = []
    @State private var lastClassified: String = ""

    // Debounce transcript updates (~6–7 fps feels fine for text)
    @State private var refreshTask: Task<Void, Never>?
    private let refreshDebounceSeconds: Double = 0.15

    // UI: language
    @State private var showingLanguagePicker: Bool = false

    // Common language choices (identifier -> label)
    private let languageChoices: [(id: String, label: String)] = [
        ("en_US", "English (US)"),
        ("en_GB", "English (UK)"),
        ("hi_IN", "Hindi"),
        ("es_ES", "Spanish"),
        ("fr_FR", "French"),
        ("de_DE", "German"),
        ("ja_JP", "Japanese")
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear.ignoresSafeArea()

            hudPanel(tailLines: transcriptTailLines, history: soundHistory)
                .padding(.bottom, 28)
                .padding(.horizontal, 28)
                .onAppear {
                    transcriptTailLines = makeTailFromUtterancesOrTranscript()
                    if isValidLabel(micMonitor.classifiedSound) {
                        soundHistory = [normalizeLabel(micMonitor.classifiedSound)]
                        lastClassified = soundHistory.first ?? ""
                    }
                }
                .onDisappear {
                    refreshTask?.cancel()
                }
                .onChange(of: micMonitor.utterances) { _, _ in
                    scheduleDebouncedTailUpdateFromUtterances()
                }
                .onChange(of: micMonitor.transcript) { _, _ in
                    scheduleDebouncedTailUpdateFromUtterances()
                }
                .onChange(of: micMonitor.classifiedSound) { _, newLabel in
                    guard isValidLabel(newLabel) else { return }
                    let normalized = normalizeLabel(newLabel)
                    if soundHistory.first != normalized {
                        var newHistory = soundHistory.filter { $0 != normalized }
                        newHistory.insert(normalized, at: 0)
                        if newHistory.count > 3 { newHistory = Array(newHistory.prefix(3)) }
                        soundHistory = newHistory
                    }
                    lastClassified = soundHistory.first ?? ""
                }
        }
        .sheet(isPresented: $showingLanguagePicker) {
            languagePickerSheet(
                title: "Recognition Language",
                current: micMonitor.currentLocaleIdentifier,
                choices: languageChoices
            ) { selected in
                micMonitor.setRecognitionLocale(selected)
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - HUD

    private func hudPanel(tailLines: [String], history: [String]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with language control
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.headline.bold())
                        .foregroundStyle(.tint)
                    Text("Transcript")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Language button shows current recognizer locale
                Button {
                    showingLanguagePicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                        Text(friendlyLocaleLabel(micMonitor.currentLocaleIdentifier))
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }

            // Transcript bubbles
            VStack(alignment: .leading, spacing: 10) {
                ForEach(tailLines, id: \.self) { line in
                    messageBubble(text: line)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 220, alignment: .bottom) // larger transcript area
            .clipped()

            Divider().opacity(0.35)

            // Sound history
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "ear")
                        .font(.headline.bold())
                        .foregroundStyle(.tint)
                    Text("Sound")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    let items = Array(history.prefix(3))
                    ForEach(items.indices, id: \.self) { index in
                        let label = items[index]
                        let isCurrent = index == 0
                        HStack(spacing: 10) {
                            Circle()
                                .fill(isCurrent ? colorForLabel(label) : Color.secondary.opacity(0.4))
                                .frame(width: 12, height: 12)
                            Text(label.isEmpty ? "…" : label)
                                .font(isCurrent ? .headline.weight(.semibold) : .subheadline)
                                .foregroundStyle(isCurrent ? .primary : .secondary)
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 22)
        .frame(maxWidth: 720) // larger panel
        .background(hudBackground())
        .tint(.accentColor)
        .animation(.easeInOut(duration: 0.2), value: tailLines.count)
        .animation(.easeInOut(duration: 0.2), value: history.first)
    }

    // Chat-style bubble (no translation)
    @ViewBuilder
    private func messageBubble(text: String) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground).opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
            )

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func hudBackground() -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.25), radius: 22, x: 0, y: 12)
    }

    // MARK: - Sheets

    @ViewBuilder
    private func languagePickerSheet(
        title: String,
        current: String,
        choices: [(id: String, label: String)],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        NavigationStack {
            List {
                ForEach(choices, id: \.id) { item in
                    HStack {
                        Text(item.label)
                        Spacer()
                        if item.id == current {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelect(item.id)
                        // Dismiss immediately after selection for clear feedback
                        if title.contains("Recognition") {
                            showingLanguagePicker = false
                        }
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        if title.contains("Recognition") {
                            showingLanguagePicker = false
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Helpers

    private func scheduleDebouncedTailUpdateFromUtterances() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(refreshDebounceSeconds * 1_000_000_000))
            let lines = makeTailFromUtterancesOrTranscript()
            transcriptTailLines = lines
        }
    }

    // Crash-safe sentence splitter with abbreviation handling and grouped punctuation.
    private func splitIntoSentences(_ text: String) -> [String] {
        if text.isEmpty { return [] }

        // Lowercased abbreviation list for simple heuristic matching on suffixes.
        let abbreviations: Set<String> = [
            "mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "st.", "vs.",
            "e.g.", "i.e.", "etc.", "cf.", "al.", "fig.", "no.", "vol.", "pp.",
            "u.s.", "u.k.", "u.n.", "ph.d.", "m.d.", "b.sc.", "m.sc."
        ]

        func isAbbreviationSuffix(_ s: String) -> Bool {
            let lower = s.lowercased()
            let maxLen = 6
            let count = lower.count
            let start = lower.index(lower.endIndex, offsetBy: -min(maxLen, count))
            let tail = String(lower[start..<lower.endIndex])
            // Try all suffixes of tail
            var i = tail.startIndex
            while i < tail.endIndex {
                let candidate = String(tail[i..<tail.endIndex])
                if abbreviations.contains(candidate) { return true }
                i = tail.index(after: i)
            }
            return false
        }

        var sentences: [String] = []
        var buffer = ""
        var i = text.startIndex

        func flushBuffer() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sentences.append(trimmed)
            }
            buffer.removeAll(keepingCapacity: true)
        }

        while i < text.endIndex {
            let ch = text[i]
            buffer.append(ch)

            // Ellipsis (single char …) is a terminator
            if ch == "…" {
                flushBuffer()
                i = text.index(after: i)
                continue
            }

            if ch == "." || ch == "!" || ch == "?" {
                // Include grouped punctuation like "?!", "!!!", "..."
                var j = text.index(after: i)
                while j < text.endIndex {
                    let la = text[j]
                    if la == "." || la == "!" || la == "?" {
                        buffer.append(la)
                        j = text.index(after: j)
                    } else {
                        break
                    }
                }

                // If this is a period, check abbreviation suffix safely
                if ch == "." && isAbbreviationSuffix(buffer) {
                    i = j
                    continue
                }

                // Treat as sentence end
                flushBuffer()
                i = j
                continue
            }

            i = text.index(after: i)
        }

        // Any trailing text without terminator — keep as final sentence
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            sentences.append(tail)
        }

        return sentences
    }

    private func makeTailFromUtterancesOrTranscript() -> [String] {
        let uts = micMonitor.utterances
        if !uts.isEmpty {
            // Prefer grammar-based splitting; if an utterance has no terminator, use the utterance boundary
            var allSentences: [String] = []
            for u in uts {
                let parts = splitIntoSentences(u.text)
                if parts.isEmpty {
                    let trimmed = u.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        allSentences.append(trimmed)
                    }
                } else {
                    allSentences.append(contentsOf: parts)
                }
            }

            allSentences = allSentences
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            if allSentences.isEmpty { return ["Listening…"] }
            if allSentences.count <= tailMaxLines { return allSentences }
            return Array(allSentences.suffix(tailMaxLines))
        } else {
            // Fallback: split the legacy transcript text into sentences
            let sentences = splitIntoSentences(micMonitor.transcript)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if sentences.isEmpty { return ["Listening…"] }
            if sentences.count <= tailMaxLines { return sentences }
            return Array(sentences.suffix(tailMaxLines))
        }
    }

    private func isValidLabel(_ label: String) -> Bool {
        !label.isEmpty && label != "..."
    }

    private func normalizeLabel(_ label: String) -> String {
        label.capitalized
    }

    private func colorForLabel(_ label: String) -> Color {
        let lc = label.lowercased()
        if lc.contains("siren") || lc.contains("alarm") || lc.contains("emergency_vehicle") {
            return .red
        } else if lc.contains("doorbell") {
            return .orange
        } else if lc.contains("horn") {
            return .yellow
        } else if lc.contains("speech") || lc == "speech" {
            return .green
        } else {
            return .blue
        }
    }

    // Convert a locale identifier like "en_US" or "en-GB" into a friendly label like "English (US)" or "English (UK)".
    private func friendlyLocaleLabel(_ identifier: String) -> String {
        // Normalize underscores to hyphens for parsing
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")

        // Split into components: language[-script][-region][...]
        let parts = normalized.split(separator: "-", omittingEmptySubsequences: true)
        let languageCode = parts.first.map { String($0) }

        // Region is usually the last 2-letter or 3-digit part; commonly at index 1 or 2.
        var regionCode: String?
        for part in parts.dropFirst() {
            let s = String(part)
            if s.count == 2 && s.uppercased() == s {
                regionCode = s
                break
            }
            if s.count == 3 && CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: s)) {
                regionCode = s
                break
            }
        }

        var languageName: String?
        if let lang = languageCode {
            languageName = Locale.current.localizedString(forLanguageCode: lang)
        }

        if let languageName, let region = regionCode {
            return "\(languageName) (\(region))"
        }
        if let languageName {
            return languageName
        }

        // Fallback to the raw identifier
        return identifier
    }
}

#Preview {
    ContentView()
        .environmentObject(MicrophoneMonitor())
}
