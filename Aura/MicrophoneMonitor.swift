import Foundation
import AVFoundation
import Accelerate
import Combine
import SoundAnalysis
import Speech

@MainActor
class MicrophoneMonitor: NSObject, ObservableObject {

    // MARK: - Published State
    @Published var audioLevel: Float = 0.0
    @Published var classifiedSound: String = "..."
    @Published var permissionDenied: Bool = false

    // Stereo/azimuth (as before)
    @Published var channelCount: UInt32 = 0
    @Published var azimuthDegrees: Float = 0.0

    // New: Live transcription (full text for compatibility)
    @Published var transcript: String = ""

    // New: Utterance-based segmentation (sentence + pause)
    @Published var utterances: [Utterance] = []

    // Expose current speech locale (e.g., "en_US") for UI
    @Published var currentLocaleIdentifier: String = Locale.current.identifier

    // Optional: user-visible status for speech errors
    @Published var speechStatusMessage: String = ""

    // MARK: - Audio & Analysis
    private var audioEngine: AVAudioEngine?
    private var soundAnalyzer: SNAudioStreamAnalyzer?
    private let analysisQueue = DispatchQueue(label: "com.aura.AnalysisQueue")

    // Speech recognition
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // MARK: - Tuning
    private let bufferSize: AVAudioFrameCount = 1024
    private let minDb: Float = -50.0
    private let maxDb: Float = 0.0

    // Stereo balance -> azimuth mapping
    private let maxAzimuthDegrees: Float = 90.0

    // Classification throttling and hysteresis
    private let classificationUpdateInterval: TimeInterval = 0.25
    private let minConfidence: Double = 0.6
    private let hysteresisDrop: Double = 0.1
    private var lastClassificationTime: TimeInterval = 0
    private var lastClassificationID: String = "..."

    // Utterance building
    // Pause gap that triggers a sentence break (seconds)
    private let pauseThreshold: TimeInterval = 1.1

    // Debug logging
    private let enableUtteranceLogging: Bool = false
    private let enableSpeechLogging: Bool = true

    override init() {
        super.init()
        Task {
            await requestSpeechAuthorization()
            await checkMicrophonePermission()
        }
    }

    deinit {
        Task { @MainActor in
            self.stopMonitoring()
        }
    }

    // MARK: - Permissions
    private func requestSpeechAuthorization() async {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { auth in
                continuation.resume(returning: auth)
            }
        }
        switch status {
        case .authorized:
            // Initialize recognizer with system default locale
            let recognizer = SFSpeechRecognizer()
            self.speechRecognizer = recognizer
            self.currentLocaleIdentifier = recognizer?.locale.identifier ?? Locale.current.identifier
            if enableUtteranceLogging {
                print("Speech: authorized, recognizer locale: \(self.speechRecognizer?.locale.identifier ?? "default")")
            }
        case .denied, .restricted, .notDetermined:
            if enableUtteranceLogging { print("Speech: not authorized (\(status))") }
            self.speechStatusMessage = "Speech not authorized: \(status)"
        @unknown default:
            if enableUtteranceLogging { print("Speech: unknown authorization status") }
            self.speechStatusMessage = "Speech authorization unknown"
        }
    }

    private func checkMicrophonePermission() async {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            guard let self else { return }
            Task { @MainActor in
                if granted {
                    self.startMonitoring()
                } else {
                    self.permissionDenied = true
                    self.speechStatusMessage = "Microphone permission denied"
                }
            }
        }
    }

    // MARK: - Start / Stop
    private func startMonitoring() {
        let engine = AVAudioEngine()
        audioEngine = engine

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            print("Failed to set up audio session: \(error.localizedDescription)")
            self.speechStatusMessage = "Audio session error: \(error.localizedDescription)"
            return
        }

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.channelCount > 0 else { return }

        // Publish and log mono/stereo
        channelCount = recordingFormat.channelCount
        if enableUtteranceLogging {
            print("MicrophoneMonitor: Input channels = \(channelCount)")
        }

        // Sound analysis setup
        let analyzer = SNAudioStreamAnalyzer(format: recordingFormat)
        soundAnalyzer = analyzer

        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            try analyzer.add(request, withObserver: self)
        } catch {
            print("Unable to add sound analysis request: \(error.localizedDescription)")
        }

        // Prepare speech recognition request/task (if authorized and available)
        setupRecognitionTask(using: recordingFormat)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: recordingFormat) { [weak self] (buffer, time) in
            guard let self = self else { return }

            // Feed the speech recognition request
            if let req = self.recognitionRequest {
                req.append(buffer)
            }

            // Per-channel RMS calculation
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            let strideCount = buffer.stride

            var perChannelRMS: [Float] = []
            for ch in 0..<Int(recordingFormat.channelCount) {
                let base = channelData.advanced(by: ch).pointee
                let samples = stride(from: 0, to: frameCount, by: strideCount).map { base[$0] }
                let rms = vDSP.rootMeanSquare(samples)
                perChannelRMS.append(rms)
            }

            // Overall level
            if let overallRMS = perChannelRMS.max(), overallRMS > 0 {
                let decibels = 20 * log10(overallRMS)
                let normalizedLevel = self.normalize(decibels)
                Task { @MainActor in
                    self.audioLevel = normalizedLevel
                }
            }

            // Stereo balance -> azimuth
            var newAzimuth: Float = 0.0
            if perChannelRMS.count >= 2 {
                let left = perChannelRMS[0]
                let right = perChannelRMS[1]
                let sum = left + right
                if sum > 0 {
                    let balance = (right - left) / sum
                    let clamped = max(-1.0, min(1.0, balance))
                    newAzimuth = clamped * self.maxAzimuthDegrees
                }
            } else {
                newAzimuth = 0.0
            }

            Task { @MainActor in
                self.azimuthDegrees = newAzimuth
            }

            // Feed analyzer (background)
            self.analysisQueue.async {
                self.soundAnalyzer?.analyze(buffer, atAudioFramePosition: time.sampleTime)
            }
        }

        do {
            try engine.start()
        } catch {
            print("Error starting audio engine: \(error.localizedDescription)")
            self.speechStatusMessage = "Engine start error: \(error.localizedDescription)"
        }
    }

    private func setupRecognitionTask(using format: AVAudioFormat) {
        guard let recognizer = speechRecognizer else {
            print("Speech recognizer is not initialized.")
            self.speechStatusMessage = "Speech recognizer not initialized"
            return
        }

        guard recognizer.isAvailable else {
            print("Speech recognizer for \(recognizer.locale.identifier) is currently unavailable.")
            self.speechStatusMessage = "Recognizer unavailable for \(recognizer.locale.identifier)"
            return
        }

        // Tear down any previous request/task
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        let req = SFSpeechAudioBufferRecognitionRequest()
        // Strict on-device policy
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        recognitionRequest = req

        if enableSpeechLogging {
            print("Starting recognition with locale: \(recognizer.locale.identifier) (on-device: \(req.requiresOnDeviceRecognition))")
        }

        // Clear status on restart
        self.speechStatusMessage = ""

        recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            Task { @MainActor in
                if let result = result {
                    self.transcript = result.bestTranscription.formattedString
                    self.updateUtterances(with: result)
                }
                if let error = error {
                    if self.enableSpeechLogging {
                        print("Speech recognition error: \(error.localizedDescription)")
                    }
                    let nserr = error as NSError
                    // kAFAssistantErrorDomain Code=603 indicates cancellation often due to policy/model issues.
                    // We enforce on-device only; do not fallback to network.
                    self.speechStatusMessage = self.friendlySpeechError(for: nserr, locale: self.currentLocaleIdentifier)
                }
            }
        }
    }

    func stopMonitoring() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning {
                engine.stop()
            }
        }

        soundAnalyzer = nil

        // End speech recognition properly
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [])
        } catch {
            // Not fatal
        }

        audioEngine = nil
    }

    // MARK: - Language switching

    func setRecognitionLocale(_ localeIdentifier: String) {
        // If it's already set, skip
        if currentLocaleIdentifier == localeIdentifier { return }

        let newLocale = Locale(identifier: localeIdentifier)
        guard let newRecognizer = SFSpeechRecognizer(locale: newLocale) else {
            print("Unsupported or invalid locale: \(localeIdentifier)")
            self.speechStatusMessage = "Unsupported locale: \(localeIdentifier)"
            return
        }

        // Availability can change dynamically; we log but proceed.
        if !newRecognizer.isAvailable {
            print("Recognizer for \(localeIdentifier) is not currently available.")
        }

        // Update state
        speechRecognizer = newRecognizer
        currentLocaleIdentifier = newRecognizer.locale.identifier

        if let engine = audioEngine {
            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            // Restart only the recognition request/task
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil

            print("Switching recognition locale to: \(currentLocaleIdentifier)")
            setupRecognitionTask(using: recordingFormat)
        } else {
            print("Locale set to \(currentLocaleIdentifier). Recognition will start with this locale when monitoring starts.")
        }
    }

    // MARK: - Helpers
    private func normalize(_ decibels: Float) -> Float {
        if decibels < minDb { return 0.0 }
        if decibels > maxDb { return 1.0 }
        return (decibels - minDb) / (maxDb - minDb)
    }

    private func shouldUpdateClassification(to newID: String, confidence: Double, at time: TimeInterval) -> Bool {
        guard confidence >= minConfidence || (newID == lastClassificationID && confidence >= (minConfidence - hysteresisDrop)) else {
            return false
        }
        if time - lastClassificationTime < classificationUpdateInterval, newID == lastClassificationID {
            return false
        }
        return true
    }

    private func applyClassification(_ id: String, confidence: Double, at time: TimeInterval) {
        lastClassificationID = id
        lastClassificationTime = time
        classifiedSound = id.capitalized
    }

    // Provide a concise, user-oriented message for common speech failures.
    private func friendlySpeechError(for error: NSError, locale: String) -> String {
        // Common assistant domain cancel error (often “requires on-device” or policy issues)
        if error.domain == "kAFAssistantErrorDomain" || error.domain.contains("kAFAssistantErrorDomain") {
            return "Speech canceled for \(locale). Ensure on-device dictation for this language is installed."
        }
        // NSURLErrorDomain or network issues won't be used since we enforce on-device, but keep a generic message.
        if error.domain == NSURLErrorDomain {
            return "Network error. On-device recognition required for \(locale)."
        }
        // SFSpeechRecognizerErrorDomain or others
        return "Speech error (\(locale)): \(error.localizedDescription)"
    }

    // MARK: - Utterance building from Speech segments
    private func updateUtterances(with result: SFSpeechRecognitionResult) {
        let segments = result.bestTranscription.segments

        if enableUtteranceLogging {
            print("— updateUtterances — segments: \(segments.count), isFinal: \(result.isFinal), pauseThreshold: \(pauseThreshold)s")
        }

        // Stateless rebuild from segments each callback.
        var newUtterances: [Utterance] = []
        var currentText = ""
        var currentStart: TimeInterval? = nil
        var lastEnd: TimeInterval? = nil
        var lastGap: TimeInterval = 0

        func closeCurrent(endTime: TimeInterval, reason: String) {
            guard let start = currentStart else { return }
            let trimmed = currentText.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                if enableUtteranceLogging { print("  close skipped (empty) due to \(reason)") }
                currentText = ""
                currentStart = nil
                lastEnd = endTime
                return
            }
            newUtterances.append(Utterance(text: trimmed, startTime: start, endTime: endTime))
            if enableUtteranceLogging {
                let dur = endTime - start
                print("  close [\(reason)] text: \"\(trimmed)\" start: \(String(format: "%.2f", start)) end: \(String(format: "%.2f", endTime)) dur: \(String(format: "%.2f", dur))")
            }
            currentText = ""
            currentStart = nil
            lastEnd = endTime
        }

        for (idx, seg) in segments.enumerated() {
            let word = seg.substring
            let start = seg.timestamp
            let end = start + seg.duration

            if enableUtteranceLogging {
                print("  seg[\(idx)] \"\(word)\" start: \(String(format: "%.2f", start)) end: \(String(format: "%.2f", end)) dur: \(String(format: "%.2f", seg.duration))")
            }

            if currentStart == nil {
                currentStart = start
                if enableUtteranceLogging {
                    print("    start new sentence at \(String(format: "%.2f", start))")
                }
            }

            if let prevEnd = lastEnd {
                let gap = start - prevEnd
                lastGap = gap
                if gap > pauseThreshold {
                    if enableUtteranceLogging {
                        print("    gap: \(String(format: "%.2f", gap))s > \(pauseThreshold)s → close at prevEnd")
                    }
                    closeCurrent(endTime: prevEnd, reason: "pause-gap")
                    // After closing, start a new one at this segment
                    if currentStart == nil {
                        currentStart = start
                        if enableUtteranceLogging {
                            print("    start new sentence after pause at \(String(format: "%.2f", start))")
                        }
                    }
                }
            }

            // Append word with space
            if currentText.isEmpty {
                currentText = word
            } else {
                currentText += " " + word
            }

            let isLast = (idx == segments.count - 1)

            if endsWithSentenceTerminator(currentText) {
                if enableUtteranceLogging { print("    punctuation terminator detected → close at end") }
                closeCurrent(endTime: end, reason: "punctuation")
            } else if isLast {
                if result.isFinal {
                    if enableUtteranceLogging { print("    result.isFinal → close at end") }
                    closeCurrent(endTime: end, reason: "final")
                } else {
                    lastEnd = end
                }
            } else {
                lastEnd = end
            }
        }

        if enableUtteranceLogging {
            print("— publish — closed utterances: \(newUtterances.count), lastGapSeen: \(String(format: "%.2f", lastGap))s\n")
        }

        // Publish only the closed utterances derived from current best transcription.
        self.utterances = newUtterances
    }

    private func endsWithSentenceTerminator(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return last == "." || last == "!" || last == "?"
    }
}

// MARK: - SNResultsObserving
extension MicrophoneMonitor: SNResultsObserving {
    nonisolated func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult,
              let top = result.classifications.first else { return }

        let now = CACurrentMediaTime()
        let newID = top.identifier
        let confidence = top.confidence

        Task { @MainActor in
            if self.shouldUpdateClassification(to: newID, confidence: confidence, at: now) {
                self.applyClassification(newID, confidence: confidence, at: now)
            }
        }
    }

    nonisolated func request(_ request: SNRequest, didFailWithError error: Error) {
        print("Sound analysis failed: \(error.localizedDescription)")
    }

    nonisolated func requestDidComplete(_ request: SNRequest) {
        // Optional
    }
}
