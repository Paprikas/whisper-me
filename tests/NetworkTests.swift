import Foundation

/// All HTTP is intercepted: these regressions require no API key or network.
final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        do {
            let (status, body) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@main
struct NetworkTests {
    static var passed = 0
    static var failed = 0
    static func check(_ value: Bool, _ name: String) {
        if value { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
    }
    static func run(model: String = "gemini-3.1-flash-lite", handler: @escaping (URLRequest) throws -> (Int, Data)) -> Result<String, Error> {
        StubProtocol.requests = []
        StubProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = GeminiTranscriber(session: session)
        let done = DispatchSemaphore(value: 0)
        var result: Result<String, Error>!
        client.transcribe(apiKey: "test-key-not-a-secret", model: model, audioData: Data([0, 1])) {
            result = $0
            done.signal()
        }
        guard done.wait(timeout: .now() + 5) == .success else {
            print("FAIL: transcription timed out")
            exit(1)
        }
        return result
    }
    static func json(_ string: String) -> Data { Data(string.utf8) }
    static func isFailure(_ result: Result<String, Error>) -> Bool {
        if case .failure = result { return true }
        return false
    }
    static func main() {
        let result = run { _ in
            (200, json(#"{"candidates":[{"content":{"parts":[{"text":"private reasoning","thought":true},{"text":"Hello "},{"text":"world"}]}}]}"#))
        }
        check((try? result.get()) == "Hello world", "join text parts and exclude thought parts")
        let request = StubProtocol.requests[0]
        check(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key-not-a-secret", "auth header present")
        check(request.url?.query == nil, "API key absent from generateContent URL")

        let interactions = run(model: "gemini-3.5-transcribe") { _ in
            (200, json(#"{"steps":[{"content":[{"text":"One "},{"text":"two"}]}]}"#))
        }
        check((try? interactions.get()) == "One two", "Interactions preserves all text parts")
        check(StubProtocol.requests.count == 1, "valid Interactions response does not retry")

        let html = run { _ in (503, json("<html>Unavailable</html>")) }
        if case .failure(let error) = html, case TranscriptionError.http(let status, _) = error {
            check(status == 503, "HTML error retains HTTP status")
        } else { check(false, "HTML error classified as HTTP") }

        let unauthorized = run { _ in (401, json(#"{"error":{"message":"Denied"}}"#)) }
        if case .failure(let error) = unauthorized, case TranscriptionError.http(let status, let message) = error {
            check(status == 401 && message == "Denied", "JSON HTTP error preserves status and message")
        } else { check(false, "JSON error classified as HTTP") }

        check(isFailure(run { _ in (200, json("{}")) }), "unknown response is not successful silence")
        check(isFailure(run { _ in (200, json("[]")) }), "non-object response rejected")
        check(isFailure(run { _ in (200, json(#"{"candidates":[{}]}"#)) }), "malformed candidate is not successful silence")
        check(isFailure(run { _ in (200, json("not JSON")) }), "malformed JSON rejected")
        check(isFailure(run { _ in (200, json(#"{"error":{"message":"Quota"}}"#)) }), "API error inside HTTP 200 rejected")
        check(isFailure(run { _ in throw URLError(.notConnectedToInternet) }), "transport failure propagated")
        let silent = run { _ in (200, json(#"{"candidates":[]}"#)) }
        check((try? silent.get()) == "", "explicit empty candidate list is silence")

        let recovered = run(model: "gemini-3.5-transcribe") { request in
            if request.url!.path.contains("interactions") { return (200, json("{}")) }
            return (200, json(#"{"candidates":[{"content":{"parts":[{"text":"Recovered"}]}}]}"#))
        }
        check((try? recovered.get()) == "Recovered", "invalid Interactions response triggers batch model fallback")
        check(StubProtocol.requests.count == 2, "fallback performs exactly one additional request")
        let live = StreamingTranscriber(apiKey: "")
        var unexpectedError = false
        live.onError = { _ in unexpectedError = true }
        do {
            try live.start()
            check(false, "Live start without a key throws")
        } catch {
            check(error is TranscriptionError, "Live start without a key throws a typed error")
        }
        live.cancel()
        live.cancel()
        check(!live.isRunning && !unexpectedError, "failed Live start and repeated cancellation leave no running session")
        var stopCalls = 0
        live.stop { text in
            stopCalls += 1
            check(text.isEmpty, "stop of inactive Live session has empty transcript")
        }
        check(stopCalls == 1, "inactive Live stop completes exactly once")
        do { try LiveRegressionTests.run(check: check) }
        catch { check(false, "unexpected mocked Live error: \(error)") }
        print("\(passed) HTTP/lifecycle checks passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
