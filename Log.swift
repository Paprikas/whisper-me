import Foundation

/// Unified application logger: stderr + persistent file (tmp/whisper-me.log),
/// to inspect app execution when launched via Finder/open (where stderr is discarded).
/// File writes and stderr output run asynchronously on a dedicated serial queue to avoid
/// blocking callers or real-time audio threads with synchronous disk/stream IO.
enum AppLog {
    private static let queue = DispatchQueue(label: "com.whisper-me.log", qos: .utility)
    private static var cachedHandle: FileHandle?
    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    static func log(_ message: String) {
        queue.async {
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            performWriteToFile(message)
        }
    }

    static func writeToFile(_ message: String) {
        queue.async {
            performWriteToFile(message)
        }
    }

    private static func performWriteToFile(_ message: String) {
        guard let fh = logFile() else { return }
        // Always append to the end of the file.
        fh.seekToEndOfFile()
        fh.write(Data("[\(stamp())] \(message)\n".utf8))
    }

    private static func logFile() -> FileHandle? {
        if let cached = cachedHandle { return cached }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper-me.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let fh = try? FileHandle(forWritingTo: url) else { return nil }
        cachedHandle = fh
        return fh
    }

    private static func stamp() -> String {
        dateFormatter.string(from: Date())
    }
}
