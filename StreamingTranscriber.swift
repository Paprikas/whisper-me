import Foundation
import AVFoundation

/// Minimal transport boundary for lifecycle regression tests without network/mic.
protocol LiveSocket: AnyObject {
    func resume()
    @preconcurrency func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void)
    @preconcurrency func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: LiveSocket {}

/// All session state and callbacks are confined to the main queue. The audio tap
/// only converts its own buffer, then hands immutable PCM data to that queue.
final class StreamingTranscriber: NSObject {
    var onInterim: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var isRunning = false
    private(set) var didFail = false
    var text: String { transcript.text }
    private var transcript = SessionTranscript()
    private var socket: LiveSocket?
    private let makeSocket: (URL) -> LiveSocket
    private let audioStarter: (() throws -> Void)?
    private let audioCallbacks: DispatchGroup
    private var finalQuietTimeout: DispatchWorkItem?
    private var sessionID = UUID()
    private var audioEngine: AVAudioEngine?
    private let apiKey: String
    var model: String
    private var pendingAudio: [Data] = []
    private var setupComplete = false
    private var stopping = false
    private var endSignaled = false
    private var stopCompletion: ((String) -> Void)?
    private var stopTimeout: DispatchWorkItem?
    private var setupTimeout: DispatchWorkItem?
    private var trailingCapture: DispatchWorkItem?
    private static let maxPendingChunks = 150

    init(apiKey: String, model: String = "gemini-3.5-transcribe-live",
         makeSocket: @escaping (URL) -> LiveSocket = { URLSession.shared.webSocketTask(with: $0) },
         audioStarter: (() throws -> Void)? = nil,
         audioCallbacks: DispatchGroup = DispatchGroup()) {
        self.apiKey = apiKey
        self.model = model
        self.makeSocket = makeSocket
        self.audioStarter = audioStarter
        self.audioCallbacks = audioCallbacks
        super.init()
    }

    func start() throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isRunning, socket == nil else { return }
        guard !apiKey.isEmpty, let url = WSURL.make(apiKey: apiKey) else {
            throw TranscriptionError.missingAPIKey(provider: .gemini)
        }
        transcript = SessionTranscript()
        sessionID = UUID()
        didFail = false
        pendingAudio.removeAll()
        setupComplete = false
        stopping = false
        endSignaled = false
        let ws = makeSocket(url)
        socket = ws
        isRunning = true
        ws.resume()
        receiveLoop(ws)

        let timeout = DispatchWorkItem { [weak self, weak ws] in
            guard let self, let ws, self.socket === ws, !self.setupComplete else { return }
            self.reportError("Live handshake timed out — check network and API key")
        }
        setupTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)

        let config = Self.audioTranscriptionConfig(for: SettingsManager.shared.cleaningMode)
        let setup: [String: Any] = ["setup": [
            "model": "models/\(model)",
            "generation_config": ["response_modalities": ["TEXT"]],
            "input_audio_transcription": config
        ]]
        do {
            send(try JSONSerialization.data(withJSONObject: setup), on: ws)
            if let audioStarter { try audioStarter() }
            else { try startAudio() }
        } catch {
            cancel()
            throw error
        }
    }

    static func audioTranscriptionConfig(for mode: CleaningMode) -> [String: Any] {
        mode.usesNativeCleanup ? ["mode": "SMART"] : [:]
    }

    /// Capture a short trailing window, then await final transcription or a deadline.
    func stop(timeout: TimeInterval = 2, completion: ((String) -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard socket != nil else { completion?(text); return }
        guard !stopping else { return }
        stopping = true
        stopCompletion = completion
        let item = DispatchWorkItem { [weak self] in self?.signalEnd(timeout: timeout) }
        trailingCapture = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    /// Immediate, idempotent teardown, including failed starts and stale callbacks.
    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        setupTimeout?.cancel()
        stopTimeout?.cancel()
        trailingCapture?.cancel()
        finalQuietTimeout?.cancel()
        finalQuietTimeout = nil
        setupTimeout = nil
        stopTimeout = nil
        trailingCapture = nil
        isRunning = false
        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        let ws = socket
        socket = nil
        ws?.cancel(with: .goingAway, reason: nil)
        pendingAudio.removeAll()
        stopCompletion = nil
        stopping = false
    }

    private func signalEnd(timeout: TimeInterval) {
        guard socket != nil, stopping else { return }
        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        let id = sessionID
        // Every in-flight tap enqueues its PCM before leaving this group. The
        // notify is therefore ordered AFTER those deliveries on the main queue.
        audioCallbacks.notify(queue: .main) { [weak self] in
            guard let self, self.sessionID == id, self.socket != nil, self.stopping else { return }
            self.completeAudioEnd(timeout: timeout)
        }
    }

    private func completeAudioEnd(timeout: TimeInterval) {
        isRunning = false
        // A stop before handshake must not flush speech after audioStreamEnd.
        guard setupComplete else { reportError("Live stopped before handshake completed"); return }
        sendAudioChunk(Data(repeating: 0, count: 9600))
        endSignaled = true
        if let ws = socket,
           let end = try? JSONSerialization.data(withJSONObject: ["realtimeInput": ["audioStreamEnd": true]]) {
            send(end, on: ws)
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.transcript.segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.reportError("Live final transcription timed out")
            } else {
                self.finishStop()
            }
        }
        stopTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    private func finishStop() {
        guard stopping else { return }
        let completion = stopCompletion
        let result = text
        cancel()
        completion?(result)
    }

    private func startAudio() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "WhisperMe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }
        let id = sessionID
        let callbacks = audioCallbacks
        audioEngine = engine
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            callbacks.enter()
            defer { callbacks.leave() }
            guard let data = Self.pcmData(buffer) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning, self.sessionID == id else { return }
                if self.setupComplete {
                    self.sendAudioChunk(data)
                } else if self.pendingAudio.count < Self.maxPendingChunks {
                    self.pendingAudio.append(data)
                } else {
                    self.reportError("Pre-handshake audio buffer overflow")
                }
            }
        }
        engine.prepare()
        try engine.start()
    }

    /// Preserve the existing per-buffer linear PCM conversion. The tap never
    /// touches session state or performs network/AX IPC.
    private static func pcmData(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let src = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        guard frames > 0, rate > 0 else { return nil }
        let count = max(1, Int((Double(frames) * 16000 / rate).rounded(.up)))
        var output = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let position = Double(i) * rate / 16000
            let low = min(Int(position), frames - 1)
            let high = min(low + 1, frames - 1)
            let sample = src[low] + (src[high] - src[low]) * Float(position - Double(low))
            output[i] = Int16(max(-1, min(1, sample)) * Float(Int16.max))
        }
        return output.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func sendAudioChunk(_ data: Data) {
        guard let ws = socket,
              let payload = try? JSONSerialization.data(withJSONObject: ["realtimeInput": ["mediaChunks": [
                ["mimeType": "audio/pcm;rate=16000", "data": data.base64EncodedString()]
              ]]]) else { return }
        send(payload, on: ws)
    }

    private func send(_ data: Data, on ws: LiveSocket) {
        ws.send(.data(data)) { [weak self, weak ws] error in
            guard let error else { return }
            DispatchQueue.main.async {
                guard let self, let ws, self.socket === ws else { return }
                self.reportError("Live send failed: \(error.localizedDescription)")
            }
        }
    }

    private func receiveLoop(_ ws: LiveSocket) {
        ws.receive { [weak self, weak ws] result in
            DispatchQueue.main.async {
                guard let self, let ws, self.socket === ws else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    if self.socket === ws { self.receiveLoop(ws) }
                case .failure(let error):
                    // Reconnecting loses audio at the boundary and may duplicate segments.
                    // Recover from the complete backup WAV instead of silently dropping words.
                    self.reportError("Live connection lost: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let string): data = Data(string.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            reportError("Invalid Live response")
            return
        }
        if json["setupComplete"] != nil {
            setupComplete = true
            setupTimeout?.cancel()
            let buffered = pendingAudio
            pendingAudio.removeAll()
            buffered.forEach(sendAudioChunk)
        }
        if let error = json["error"] as? [String: Any] {
            reportError(error["message"] as? String ?? "Live API error")
            return
        }
        guard let content = json["serverContent"] as? [String: Any] else { return }
        if let final = content["inputTranscription"] as? [String: Any],
           let chunk = final["text"] as? String, !chunk.isEmpty {
            transcript.onFinal(chunk)
            onFinal?(chunk)
            if endSignaled {
                // Transcribe finalizes through inputTranscription, not necessarily
                // turnComplete. Briefly coalesce any already-in-flight segments.
                finalQuietTimeout?.cancel()
                let id = sessionID
                let item = DispatchWorkItem { [weak self] in
                    guard let self, self.sessionID == id, self.stopping,
                          self.transcript.segment.isEmpty else { return }
                    self.finishStop()
                }
                finalQuietTimeout = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
            }
        }
        if let interim = content["interimInputTranscription"] as? [String: Any],
                  let chunk = interim["text"] as? String, !chunk.isEmpty {
            finalQuietTimeout?.cancel()
            finalQuietTimeout = nil
            transcript.onInterim(chunk)
            onInterim?(chunk)
        }
        if endSignaled, content["turnComplete"] as? Bool == true { finishStop() }
    }

    private func reportError(_ message: String) {
        didFail = true
        let completion = stopCompletion
        let result = text
        let wasStopping = stopping
        cancel()
        AppLog.log("[Live] \(message)")
        if wasStopping { completion?(result) }
        else { onError?(message) }
    }
}
