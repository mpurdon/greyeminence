import Speech
import AVFoundation

/// Manages SFSpeechRecognizer for on-device streaming transcription.
/// Not an actor — audio buffer appending must happen without crossing isolation boundaries.
final class SpeechRecognitionService: @unchecked Sendable {
    let source: String
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var continuation: AsyncStream<TranscriptUpdate>.Continuation?
    private var startTime: TimeInterval = 0
    private var restartCount = 0
    private let requestLock = NSLock()
    private let maxConsecutiveNoSpeech = 30
    private var isStopped = false
    var onDictationDisabled: (@Sendable () -> Void)?

    init(source: String) {
        self.source = source
    }

    struct TranscriptUpdate: Sendable {
        let text: String
        let isFinal: Bool
        let timestamp: TimeInterval
    }

    enum RecognitionError: Error, LocalizedError {
        case notAuthorized
        case recognizerUnavailable
        case alreadyRunning
        case dictationDisabled

        var errorDescription: String? {
            switch self {
            case .notAuthorized: "Speech recognition not authorized"
            case .recognizerUnavailable: "Speech recognizer unavailable for this locale"
            case .alreadyRunning: "Recognition is already running"
            case .dictationDisabled: "Dictation must be enabled for transcription. Go to System Settings > Keyboard > Dictation."
            }
        }
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    @MainActor
    func startRecognition(locale: Locale = .current) throws -> AsyncStream<TranscriptUpdate> {
        guard recognitionTask == nil else {
            throw RecognitionError.alreadyRunning
        }

        guard let speechRecognizer = SFSpeechRecognizer(locale: locale),
              speechRecognizer.isAvailable else {
            throw RecognitionError.recognizerUnavailable
        }

        recognizer = speechRecognizer
        startTime = ProcessInfo.processInfo.systemUptime
        restartCount = 0
        isStopped = false

        let stream = AsyncStream<TranscriptUpdate> { [weak self] continuation in
            self?.continuation = continuation
            continuation.onTermination = { @Sendable _ in }
        }

        createRecognitionTask()
        return stream
    }

    /// Prepare a fresh recognition request so incoming audio buffers are captured immediately.
    private func prepareNewRequest() {
        recognitionTask?.cancel()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        requestLock.lock()
        recognitionRequest = request
        requestLock.unlock()
    }

    /// Start the recognition task on the current request.
    private func startCurrentRecognitionTask() {
        requestLock.lock()
        let request = recognitionRequest
        requestLock.unlock()
        guard let recognizer, let request, continuation != nil, !isStopped else { return }

        let capturedStartTime = startTime
        let src = source

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            guard let result else {
                if let error {
                    let code = (error as NSError).code
                    if code == 201 {
                        LogManager.send("[\(src)] Dictation is disabled — transcription unavailable", category: .transcription, level: .error)
                        self.onDictationDisabled?()
                    } else if code == 1110 {
                        // "No speech detected" — restart with a delay so audio buffers
                        // can accumulate in the new request before the recognizer times out.
                        guard self.continuation != nil, !self.isStopped else { return }
                        self.restartCount += 1
                        let attempt = self.restartCount

                        // Create new request IMMEDIATELY so audio starts
                        // accumulating during the backoff delay (not lost in old request).
                        self.prepareNewRequest()

                        if attempt >= self.maxConsecutiveNoSpeech {
                            // Circuit breaker: too many consecutive failures, cool off
                            LogManager.send("[\(src)] No speech detected \(attempt) times — cooling off for 30s", category: .transcription, level: .warning)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak self] in
                                guard let self, self.continuation != nil, !self.isStopped else { return }
                                self.restartCount = 0
                                LogManager.send("[\(src)] Cooldown complete, resuming speech recognition", category: .transcription)
                                self.startCurrentRecognitionTask()
                            }
                        } else {
                            if attempt <= 5 || attempt % 10 == 0 {
                                LogManager.send("[\(src)] No speech detected, restarting (attempt \(attempt))", category: .transcription, level: .warning)
                            }
                            // Minimum 1.5s delay so the recognizer has enough audio to work with
                            let delay = max(1.5, min(0.5 * Double(attempt), 5.0))
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                                guard let self, self.continuation != nil, !self.isStopped else { return }
                                self.startCurrentRecognitionTask()
                            }
                        }
                    } else if code != 216 && code != 301 { // 216/301 = recognition was canceled (expected)
                        LogManager.send("[\(src)] Speech recognition error (code \(code)): \(error.localizedDescription)", category: .transcription, level: .error)
                    }
                }
                return
            }

            let text = result.bestTranscription.formattedString
            let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            // Only reset restart counter on final results (not partials) to prevent
            // the backoff delay from resetting on every brief partial detection.
            if result.isFinal && hasText {
                self.restartCount = 0
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - capturedStartTime

            let update = TranscriptUpdate(
                text: text,
                isFinal: result.isFinal,
                timestamp: elapsed
            )
            self.continuation?.yield(update)

            if result.isFinal {
                LogManager.send("[\(src)] Recognition session ended (final result\(hasText ? "" : ", empty")), restarting", category: .transcription)
                self.prepareNewRequest()
                DispatchQueue.main.async {
                    self.startCurrentRecognitionTask()
                }
            }
        }
    }

    /// Create (or recreate) the recognition task. Keeps the existing stream continuation.
    private func createRecognitionTask() {
        prepareNewRequest()
        startCurrentRecognitionTask()
    }

    private var hasLoggedFirstBuffer = false

    /// Append audio buffer to the recognition request.
    /// Thread-safe — can be called from any thread (audio callback thread).
    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        if !hasLoggedFirstBuffer {
            hasLoggedFirstBuffer = true
            let fmt = buffer.format
            LogManager.send(
                "[\(source)] First audio buffer: \(Int(fmt.sampleRate))Hz, \(fmt.channelCount)ch, \(buffer.frameLength) frames",
                category: .transcription
            )
        }
        requestLock.lock()
        let request = recognitionRequest
        requestLock.unlock()
        request?.append(buffer)
    }

    func stopRecognition() {
        isStopped = true
        continuation?.finish()
        continuation = nil
        let taskToCancel = recognitionTask
        recognitionTask = nil
        requestLock.lock()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        requestLock.unlock()
        recognizer = nil
        taskToCancel?.cancel()
        hasLoggedFirstBuffer = false
        restartCount = 0
    }
}
