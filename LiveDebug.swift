// Super-debug harness for the Gemini Live API streaming protocol.
// Diagnostic tool specifically for Gemini Live API streaming.
// Builds as a CLI tool: swiftc LiveDebug.swift -o livedebug
// It captures mic audio with AVAudioEngine (same path as the app), OR replays
// a WAV file, sends to Gemini Live BidiGenerateContent and dumps EVERY raw
// server message to stderr. Goal: find the exact wire format that yields
// inputTranscription chunks.

import Foundation
import AVFoundation

// MARK: - Config
var useFile = ProcessInfo.processInfo.arguments.count > 1
let wavPath = "/tmp/whisper-test.wav"
let apiKey: String = {
    if let k = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !k.isEmpty { return k }
    // read from .env
    for line in try! String(contentsOf: URL(fileURLWithPath: ".env")).split(separator: "\n") {
        let p = line.split(separator: "=", maxSplits: 1)
        if p.count == 2, p[0] == "GEMINI_API_KEY" { return String(p[1]) }
    }
    fatalError("no api key")
}()
let model = "gemini-3.5-transcribe-live"

var receivedCount = 0
var sentChunks = 0

func log(_ s: String) {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss.SSS"
    FileHandle.standardError.write(Data("[\(df.string(from: Date()))] \(s)\n".utf8))
}

// MARK: - WebSocket
let session = URLSession(configuration: .default)
let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey)")!
let socket = session.webSocketTask(with: url)

func send(json: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: json)
    socket.send(.data(data)) { err in
        if let err = err { log("SEND ERROR: \(err.localizedDescription)") }
    }
}

func receiveLoop() {
    socket.receive { result in
        switch result {
        case .success(.string(let s)):
            receivedCount += 1
            log("◀ RAW[\(receivedCount)]: \(s.prefix(600))")
            receiveLoop()
        case .success(.data(let d)):
            receivedCount += 1
            log("◀ RAW-BIN[\(receivedCount)]: \(String(data: d.prefix(600), encoding: .utf8) ?? "?")")
            receiveLoop()
        case .success:
            log("◀ unknown message type")
            receiveLoop()
        case .failure(let e):
            log("◀ RECEIVE FAIL: \(e.localizedDescription)")
        }
    }
}

// MARK: - Audio source
let engine = AVAudioEngine()
var converter: AVAudioConverter?

func micTap() throws {
    let input = engine.inputNode
    let inFormat = input.outputFormat(forBus: 0)
    log("mic: \(inFormat.sampleRate)Hz ch=\(inFormat.channelCount) — manual linear SRC")

    input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { buf, _ in
        guard let src = buf.floatChannelData?[0] else { return }
        let inFrames = Int(buf.frameLength)
        let inRate = buf.format.sampleRate
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
        let rms = (sumSq / Double(outFrames)).squareRoot()

        sentChunks += 1
        if sentChunks % 25 == 1 {
            log("▲ chunk #\(sentChunks): \(outFrames) frames rms=\(Int(rms * 1000))")
        }
        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        send(json: ["realtimeInput": ["mediaChunks": [["mimeType": "audio/pcm;rate=16000", "data": data.base64EncodedString()]]]])
    }
    engine.prepare()
    try engine.start()
}

func fileTap() throws {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: wavPath))
    let fileFormat = file.processingFormat
    guard let out16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else { fatalError() }
    converter = AVAudioConverter(from: fileFormat, to: out16)

    let totalFrames = AVAudioFrameCount(file.length)
    guard let fileBuf = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: totalFrames) else { fatalError() }
    try file.read(into: fileBuf)
    log("wav: \(fileFormat.sampleRate)Hz, \(totalFrames) frames")

    // Convert the WHOLE file to PCM int16 16k in ONE pass (SRC needs continuity),
    // then slice the ready pcm into 100ms chunks.
    guard let conv = converter else { return }
    let cap = AVAudioFrameCount(Double(totalFrames) * 16000.0 / fileFormat.sampleRate) + 4096
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: out16, frameCapacity: cap) else { return }
    var fed = false
    var err: NSError?
    let st = conv.convert(to: outBuf, error: &err) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true
        status.pointee = .haveData
        return fileBuf
    }
    guard st != .error, err == nil, outBuf.frameLength > 0 else {
        log("WHOLE-FILE CONVERT FAILED: \(err?.localizedDescription ?? "?") status=\(st.rawValue)")
        exit(1)
    }
    log("converted: \(outBuf.frameLength) frames @16k (\(outBuf.frameLength) / 16000 = \(String(format: "%.2f", Double(outBuf.frameLength)/16000.0))s)")

    let pcm = UnsafeBufferPointer(start: outBuf.int16ChannelData![0], count: Int(outBuf.frameLength))
    let chunkFrames = 1600 // 100ms
    var pos = 0
    let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
        guard pos + chunkFrames <= pcm.count else {
            t.invalidate()
            log("▲ file fully fed (\(pos/1600) chunks); waiting for transcription...")
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                log("─── summary: sent=\(sentChunks) received=\(receivedCount)")
                exit(0)
            }
            return
        }
        let slice = Array(pcm[pos..<pos+chunkFrames])
        pos += chunkFrames
        let data = slice.withUnsafeBufferPointer { Data(buffer: $0) }
        sentChunks += 1
        if sentChunks % 20 == 1 { log("▲ chunk #\(sentChunks) (\(data.count)B)") }
        send(json: ["realtimeInput": ["mediaChunks": [["mimeType": "audio/pcm;rate=16000", "data": data.base64EncodedString()]]]])
    }
    RunLoop.current.add(timer, forMode: .default)
}

// MARK: - Main
socket.resume()
log("connecting \(useFile ? "(file mode: \(wavPath))" : "(mic mode, 10s)")")
receiveLoop()

let setup: [String: Any] = [
    "setup": [
        "model": "models/\(model)",
        "generation_config": ["response_modalities": ["TEXT"]],
        "input_audio_transcription": [:]
    ]
]
send(json: setup)

if useFile {
    try fileTap()
    // run the main RunLoop so the feed timer fires
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 40))
    log("─── done: sent=\(sentChunks) received=\(receivedCount)")
} else {
    try micTap()
    log("● recording 10s — speak now!")
    DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
        log("─── stop: sent=\(sentChunks) received=\(receivedCount)")
        engine.stop()
        exit(0)
    }
    DispatchSemaphore(value: 0).wait()
}
