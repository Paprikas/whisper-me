import Foundation

/// In-memory WebSocket; no microphone, credentials, or provider requests.
private final class StubLiveSocket: LiveSocket {
    var receiver: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    var onEnd: (() -> Void)?
    var cancelled = false
    var sent: [[String: Any]] = []
    private var pending: [URLSessionWebSocketTask.Message] = []

    func resume() { cancelled = false }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelled = true
        receiver = nil
    }
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        let data: Data
        switch message {
        case .data(let bytes): data = bytes
        case .string(let text): data = Data(text.utf8)
        @unknown default: completionHandler(URLError(.badServerResponse)); return
        }
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        sent.append(payload)
        completionHandler(nil)
        if payload["setup"] != nil { emit(["setupComplete": [:]]) }
        if (payload["realtimeInput"] as? [String: Any])?["audioStreamEnd"] as? Bool == true { onEnd?() }
    }
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        receiver = completionHandler
        flush()
    }
    func emit(_ payload: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        pending.append(.data(data))
        flush()
    }
    private func flush() {
        guard let callback = receiver, !pending.isEmpty else { return }
        receiver = nil
        callback(.success(pending.removeFirst()))
    }
}

enum LiveRegressionTests {
    private static func wait(_ timeout: TimeInterval = 3, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    static func run(check: (Bool, String) -> Void) throws {
        check(TextInjector.resultOfAXWrite(.success) == .inserted, "successful AX write never falls back to paste")
        check(TextInjector.resultOfAXWrite(.cannotComplete) == .blocked, "ambiguous AX timeout never duplicates a write")
        check(TextInjector.resultOfAXWrite(.attributeUnsupported) == .paste, "unsupported AX write allows clipboard fallback")

        var blank = APIKeyDraft(value: "")
        check(blank.valueToSave == nil, "unchanged empty key does not create a Keychain override")
        blank.value = "  test-key  "
        check(blank.valueToSave == "test-key", "explicit key edit is normalized and saved")
        var existing = APIKeyDraft(value: "env-key")
        check(existing.valueToSave == nil, "unrelated Save leaves environment credentials alone")
        existing.value = ""
        check(existing.valueToSave == "", "explicit deletion still suppresses environment fallback")
        existing.value = " env-key \n"
        check(existing.valueToSave == nil, "reverted key edit is not persisted")
        check(StreamingTranscriber.audioTranscriptionConfig(for: .smart)["mode"] as? String == "SMART", "native Live smart mode uses documented enum spelling")
        check(StreamingTranscriber.audioTranscriptionConfig(for: .manual).isEmpty, "manual cleanup does not request native cleanup")

        // Final transcription events suffice; conversational turnComplete is optional.
        let socket = StubLiveSocket()
        let live = StreamingTranscriber(apiKey: "fake-key", makeSocket: { _ in socket }, audioStarter: {})
        var interimEvents: [String] = []
        live.onInterim = { interimEvents.append($0) }
        try live.start()
        check(wait { socket.receiver != nil }, "Live handshake completes on main queue")
        socket.onEnd = {
            socket.emit(["serverContent": ["inputTranscription": ["text": "One"], "interimInputTranscription": ["text": "tw"]]])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                socket.emit(["serverContent": ["inputTranscription": ["text": "two"]]])
            }
        }
        var completions = 0
        var output = ""
        let began = Date()
        live.stop { completions += 1; output = $0 }
        check(wait { completions > 0 }, "Live stop completes without turnComplete")
        check(Date().timeIntervalSince(began) < 1.8, "final Live result does not wait for full two-second deadline")
        check(output == "One two" && completions == 1 && socket.cancelled, "stop coalesces finals and tears down exactly once")
        check(interimEvents == ["tw"], "combined final and interim event preserves next segment")
        live.cancel()

        // A partial hypothesis at the deadline must trigger WAV recovery, not success.
        let delayed = StubLiveSocket()
        let incomplete = StreamingTranscriber(apiKey: "fake-key", makeSocket: { _ in delayed }, audioStarter: {})
        try incomplete.start()
        check(wait { delayed.receiver != nil }, "second mocked handshake completes")
        delayed.onEnd = { delayed.emit(["serverContent": ["interimInputTranscription": ["text": "unfinished"]]]) }
        var deadlineCalls = 0
        var errors = 0
        incomplete.onError = { _ in errors += 1 }
        incomplete.stop(timeout: 0.08) { _ in deadlineCalls += 1 }
        check(wait { deadlineCalls == 1 }, "unfinished Live stop completes on deadline")
        check(incomplete.didFail && errors == 0 && !incomplete.isRunning, "deadline marks partial result failed for batch recovery")

        // Main-queue end marker waits until an in-flight audio callback has delivered.
        let group = DispatchGroup()
        let trailing = StubLiveSocket()
        let draining = StreamingTranscriber(apiKey: "fake-key", makeSocket: { _ in trailing }, audioStarter: {}, audioCallbacks: group)
        try draining.start()
        check(wait { trailing.receiver != nil }, "drain test handshake completes")
        group.enter()
        var audioDelivered = false
        var endFollowedAudio = false
        trailing.onEnd = {
            endFollowedAudio = audioDelivered
            trailing.emit(["serverContent": ["inputTranscription": ["text": "tail"]]])
        }
        var drainDone = false
        draining.stop { _ in drainDone = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            audioDelivered = true
            group.leave()
        }
        check(wait { drainDone }, "stop waits for audio drain and final response")
        check(endFollowedAudio, "audioStreamEnd is queued after outstanding audio delivery")

        // A cancelled receive cannot contaminate a restarted recording.
        let old = StubLiveSocket()
        let fresh = StubLiveSocket()
        var starts = 0
        let restarted = StreamingTranscriber(apiKey: "fake-key", makeSocket: { _ in
            starts += 1
            return starts == 1 ? old : fresh
        }, audioStarter: {})
        try restarted.start()
        check(wait { old.receiver != nil }, "old session reaches receive loop")
        let stale = old.receiver
        var cancelledStopCalls = 0
        restarted.stop { _ in cancelledStopCalls += 1 }
        restarted.cancel()
        try restarted.start()
        stale?(.success(.string(#"{"serverContent":{"inputTranscription":{"text":"stale"}}}"#)))
        let settle = Date().addingTimeInterval(0.45)
        _ = wait { Date() >= settle }
        check(restarted.isRunning && restarted.text.isEmpty && cancelledStopCalls == 0, "stale receive and stop timer cannot affect restarted session")
        restarted.cancel()

        let failed = StubLiveSocket()
        let failedStart = StreamingTranscriber(apiKey: "fake-key", makeSocket: { _ in failed }, audioStarter: { throw URLError(.unknown) })
        do {
            try failedStart.start()
            check(false, "audio start failure is thrown")
        } catch {
            check(failed.cancelled && !failedStart.isRunning, "audio start failure cancels already-opened socket")
        }
    }
}
