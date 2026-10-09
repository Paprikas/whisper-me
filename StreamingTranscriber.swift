import Foundation
import AVFoundation

// Streaming transcription via the Gemini Live API over WebSocket.
//
// This path is dedicated to Gemini (the only provider supporting Live API).
// For other providers, AppDelegate routes directly to batch mode.
//
// Wire protocol (verified against v1beta BidiGenerateContent):
//   1. client → {"setup": {model, generation_config, input_audio_transcription: {}}}
//   2. server → {"setupComplete": {}}
//   3. client → {"realtimeInput": {"mediaChunks": [{"mimeType": "audio/pcm;rate=16000", "data": <b64 int16 mono 16k>]}}}
//   4. server → {"serverContent": {"interimInputTranscription": {"text": ...}}}   (progressive)
//              {"serverContent": {"inputTranscription": {"text": ...}}}           (final, after end-of-audio)
//
// CRITICAL: AVAudioConverter with sample-rate conversion must be fed continuously
// (tap → one persistent converter; do NOT create a new input buffer per call and
// never reset the converter between taps) — otherwise it goes dry after chunk 1.
// The mic tap here keeps ONE converter alive for the whole session and converts
// every incoming buffer in a single .haveData step, which works because tap
// buffers arrive in continuous real time.

final class StreamingTranscriber: NSObject {

    /// Progressive transcription while speaking (full utterance so far).
    var onInterim: ((String) -> Void)?
    /// Final chunk committed (arrives after audioStreamEnd or VAD silence).
    var onFinal: ((String) -> Void)?
    /// Called on unrecoverable errors (connection/setup failure).
    var onError: ((String) -> Void)?

    private(set) var isRunning = false
    /// Authoritative session transcript (segment model — see SessionTranscript).
    var text: String { transcript.text }

    /// Committed finals + overlay of current interim segment.
    /// Gemini final replaces the current segment rather than appending.
    private var transcript = SessionTranscript()

    private var socket: URLSessionWebSocketTask?
    private var audioEngine: AVAudioEngine?

    private let apiKey: String

    var model: String

    /// Audio chunks accumulated before setupComplete is received.
    /// The server drops realtimeInput sent prior to handshake confirmation.
    private let bufferLock = NSLock()
    private var pendingAudio: [Data] = []
    private var setupComplete = false

    /// stop() completion callback invoked when the server commits the final chunk.
    private var stopCompletion: ((String) -> Void)?
    private var stopTimeout: DispatchWorkItem?

    /// Timeout waiting for setupComplete handshake.
    private static let setupTimeoutSeconds: TimeInterval = 5.0
    private var setupTimeout: DispatchWorkItem?

    /// Cap on pre-handshake buffered audio chunks.
    private static let maxPendingChunks = 150

    init(apiKey: String, model: String = "gemini-3.5-transcribe-live") {
        self.apiKey = apiKey
        self.model = model
        super.init()
    }

    // MARK: - Session lifecycle

    /// Builds the WebSocket task with properly escaped query parameters.
    private func makeSocket() -> URLSessionWebSocketTask? {
        guard let url = WSURL.make(apiKey: apiKey) else { return nil }
        return URLSession(configuration: .default).webSocketTask(with: url)
    }

    /// Sets up the handshake timeout.
    private func armSetupTimeout() {
        bufferLock.lock()
        setupTimeout?.cancel()
        let setupItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            var stillPending = false
            self.bufferLock.lock()
            stillPending = !self.setupComplete
            self.bufferLock.unlock()
            if stillPending, self.isRunning {
                self.reportError("Handshake not completed within \(Int(Self.setupTimeoutSeconds))s — network issue or invalid API key")
            }
        }
        setupTimeout = setupItem
        bufferLock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.setupTimeoutSeconds, execute: setupItem)
    }

    func start() throws {
        guard !isRunning else { return }
        guard !apiKey.isEmpty else {
            throw NSError(domain: "WhisperMe", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "API key is not configured"])
        }

        transcript = SessionTranscript()
        bufferLock.lock()
        pendingAudio.removeAll()
        setupComplete = false
        bufferLock.unlock()
        guard let ws = makeSocket() else {
            reportError("Failed to build WebSocket URL (check API key)")
            return
        }
        socket = ws
        ws.resume()
        receiveLoop()

        // Handshake timeout: fallback to batch if setupComplete does not arrive.
        armSetupTimeout()

        let setup: [String: Any] = [
            "setup": [
                "model": "models/\(model)",
                "generation_config": ["response_modalities": ["TEXT"]],
                "input_audio_transcription": [:]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: setup)
        log("→ setup (\(data.count)B)")
        ws.send(.data(data)) { [weak self] error in
            if let error = error {
                self?.reportError("setup send: \(error.localizedDescription)")
            }
        }

        try startAudio()
        isRunning = true
    }

    /// Trailing capture window: capture a bit more audio after stop
    /// so the end of the phrase is not dropped when removing the tap.
    private static let trailingCaptureSeconds: TimeInterval = 0.35

    /// Asynchronous stop: records trailing audio, sends silence to drain decoder,
    /// then signals audioStreamEnd and awaits the final committed chunk.
    func stop(timeout: TimeInterval = 2.0, completion: ((String) -> Void)? = nil) {
        log("⏹ stop() called (isRunning=\(isRunning), text.isEmpty=\(text.isEmpty))")
        guard isRunning else {
            completion?(text)
            return
        }
        guard stopCompletion == nil else { return } // ignore duplicate stop calls
        bufferLock.lock()
        guard stopCompletion == nil else {
            bufferLock.unlock()
            return
        }
        stopCompletion = completion
        bufferLock.unlock()

        // 1) Trailing capture: continue running tap briefly.
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.trailingCaptureSeconds) { [weak self] in
            self?.teardownAndSignalEnd(timeout: timeout)
        }
    }

    private func teardownAndSignalEnd(timeout: TimeInterval) {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        isRunning = false

        guard let ws = socket else {
            finishStop()
            return
        }
        // 2) Silence: drains decoder to commit trailing words.
        sendSilence(seconds: 0.3)
        // 3) End of audio signal: server delivers final chunk.
        let end: [String: Any] = ["realtimeInput": ["audioStreamEnd": true]]
        if let data = try? JSONSerialization.data(withJSONObject: end) {
            ws.send(.data(data)) { _ in }
        }
        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.finishStop()
        }
        bufferLock.lock()
        stopTimeout = timeoutItem
        bufferLock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
    }

    /// Sends silence PCM data through the standard sendAudioChunk pipeline.
    private func sendSilence(seconds: Double) {
        let zeros = [Int16](repeating: 0, count: Int(16000 * seconds))
        let data = zeros.withUnsafeBufferPointer { Data(buffer: $0) }
        sendAudioChunk(data)
    }

    /// Closes session and delivers accumulated transcript to completion.
    private func finishStop() {
        bufferLock.lock()
        guard stopCompletion != nil else {
            bufferLock.unlock()
            return
        }
        stopTimeout?.cancel()
        stopTimeout = nil
        let finalText = text
        let ws = socket
        socket = nil
        let completion = stopCompletion
        stopCompletion = nil
        bufferLock.unlock()

        ws?.cancel(with: .goingAway, reason: nil)
        completion?(finalText)
    }

    // MARK: - Audio capture

    private func startAudio() throws {
        let engine = AVAudioEngine()
        audioEngine = engine
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        log("mic: \(inFormat.sampleRate)Hz ch=\(inFormat.channelCount)")

        // Tap at native format, then resample manually. (AVAudioConverter used
        // per-tap-buffer goes dry after the first buffer; installTap rejects a
        // non-native int16 format outright. Manual linear SRC avoids both.)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
            guard let self = self, self.isRunning else { return }
            self.convertAndSend(buf)
        }
        engine.prepare()
        try engine.start()
    }

    /// Linear-interpolation resampler to PCM int16 mono 16 kHz.
    private func convertAndSend(_ inBuf: AVAudioPCMBuffer) {
        guard let src = inBuf.floatChannelData?[0] else { return }
        let inFrames = Int(inBuf.frameLength)
        let inRate = inBuf.format.sampleRate
        guard inFrames > 0, inRate > 0 else { return }

        let outRate = 16000.0
        let outFrames = max(1, Int((Double(inFrames) * outRate / inRate).rounded(.up)))
        var out = [Int16](repeating: 0, count: outFrames)
        let ratio = inRate / outRate

        var sumSq = 0.0
        for i in 0..<outFrames {
            let srcPos = Double(i) * ratio
            let i0 = min(Int(srcPos), inFrames - 1)
            let i1 = min(i0 + 1, inFrames - 1)
            let frac = srcPos - Double(i0)
            let sample = src[i0] + (src[i1] - src[i0]) * Float(frac)
            let clamped = max(-1.0, min(1.0, sample))
            out[i] = Int16(clamped * Float(Int16.max))
            sumSq += Double(clamped * clamped)
        }

        // Log level roughly once a second to spot dead-mic issues.
        logCounter += 1
        if logCounter % (Int(inRate / Double(inFrames)) + 1) == 1 {
            let rms = (sumSq / Double(outFrames)).squareRoot()
            log("♪ level rms=\(Int(rms * 1000)) frames=\(inFrames)")
        }

        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }

        // Buffer audio until setupComplete is received from server.
        bufferLock.lock()
        if !setupComplete {
            if pendingAudio.count >= Self.maxPendingChunks {
                bufferLock.unlock()
                reportError("Pre-handshake audio buffer overflow — handshake not received")
                return
            }
            pendingAudio.append(data)
            bufferLock.unlock()
            return
        }
        bufferLock.unlock()
        sendAudioChunk(data)
    }

    private func sendAudioChunk(_ data: Data) {
        let chunk: [String: Any] = [
            "realtimeInput": ["mediaChunks": [
                ["mimeType": "audio/pcm;rate=16000", "data": data.base64EncodedString()]
            ]]
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: chunk) else { return }
        socket?.send(.data(payload)) { _ in }
    }

    /// Flushes audio buffered prior to handshake confirmation.
    private func flushPendingAudio() {
        bufferLock.lock()
        setupComplete = true
        setupTimeout?.cancel()
        setupTimeout = nil
        let buffered = pendingAudio
        pendingAudio.removeAll()
        bufferLock.unlock()
        log("✓ flushing \(buffered.count) buffered chunk(s) from before setupComplete")
        for data in buffered {
            sendAudioChunk(data)
        }
    }

    private var logCounter = 0

    // MARK: - Receive

    private func receiveLoop() {
        socket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let msg):
                self.handle(msg)
                if self.socket != nil { self.receiveLoop() }
            case .failure(let e):
                if self.isRunning {
                    self.log("✗ websocket dropped: \(e.localizedDescription) — reconnecting")
                    self.reconnect()
                }
            }
        }
    }

    /// Live API sessions have a server-side time limit; when the socket drops
    /// mid-session we transparently reconnect and continue transcription.
    private func reconnect() {
        guard isRunning else { return }
        socket?.cancel(with: .abnormalClosure, reason: nil)
        socket = nil
        // New connection = new handshake: buffer incoming audio until setupComplete arrives.
        bufferLock.lock()
        setupComplete = false
        bufferLock.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.isRunning else { return }
            do {
                try self.restartAudioAndSocket()
                self.log("✓ reconnected")
            } catch {
                self.reportError("reconnect: \(error.localizedDescription)")
            }
        }
    }

    private func restartAudioAndSocket() throws {
        guard let ws = makeSocket() else {
            throw NSError(domain: "WhisperMe", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to construct WebSocket URL"])
        }
        socket = ws
        ws.resume()
        receiveLoop()
        armSetupTimeout()

        let setup: [String: Any] = [
            "setup": [
                "model": "models/\(model)",
                "generation_config": ["response_modalities": ["TEXT"]],
                "input_audio_transcription": [:]
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: setup) {
            ws.send(.data(data)) { _ in }
        }

        // Reinstall audio tap (old engine was torn down with the dead socket)
        try startAudio()
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        var raw: String
        switch message {
        case .string(let s): raw = s
        case .data(let d): raw = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("✗ unparseable: \(raw.prefix(200))")
            return
        }

        if json["setupComplete"] != nil {
            log("✓ setupComplete")
            flushPendingAudio()
            return
        }

        if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
            reportError("Gemini: \(msg)")
            return
        }

        guard let sc = json["serverContent"] as? [String: Any] else { return }

        // Final committed chunk (after audioStreamEnd / silence VAD)
        if let t = sc["inputTranscription"] as? [String: Any],
           let chunk = t["text"] as? String, !chunk.isEmpty {
            log("✓ final chunk: \(chunk)")
            transcript.onFinal(chunk)
            onFinal?(chunk)
            // If waiting for stop completion, finalize without waiting for timeout.
            var shouldFinish = false
            bufferLock.lock()
            shouldFinish = stopCompletion != nil
            bufferLock.unlock()
            if shouldFinish {
                finishStop()
            }
            return
        }
        // Progressive interim (arrives while speaking)
        if let t = sc["interimInputTranscription"] as? [String: Any],
           let chunk = t["text"] as? String, !chunk.isEmpty {
            transcript.onInterim(chunk)   // interim = current segment, not entire session
            onInterim?(chunk)
        }
    }

    // MARK: - Errors / logging

    private func reportError(_ message: String) {
        log("✗ ERROR: \(message)")
        onError?(message)
        stop()
    }

    private func log(_ message: String) {
        AppLog.log("[Live] \(message)")
    }
}
