import Foundation

/// Unified application logger: stderr + persistent file (tmp/whisper-me.log),
/// to inspect app execution when launched via Finder/open (where stderr is discarded).
/// File writes are force-flushed to preserve logs across sudden process termination.
enum AppLog {
    private static var cachedHandle: FileHandle?

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        writeToFile(message)
    }

    static func writeToFile(_ message: String) {
        guard let fh = logFile() else { return }
        // Always append to the end of the file.
        fh.seekToEndOfFile()
        fh.write(Data("[\(stamp())] \(message)\n".utf8))
        fh.synchronizeFile()   // Force flush to survive crashes
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
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: Date())
    }
}
