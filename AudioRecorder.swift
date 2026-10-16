import Cocoa
import AVFoundation
import AVFAudio

class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?

    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            completion(granted)
        }
    }

    func start() -> Bool {
        _ = stop()

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-me-\(UUID().uuidString).wav")
        recordingURL = tmpURL

        do {
            audioRecorder = try AVAudioRecorder(url: tmpURL, settings: settings)
            audioRecorder?.delegate = self
            guard audioRecorder?.record() == true else {
                _ = stop()
                return false
            }
            return true
        } catch {
            AppLog.log("❌ Failed to start recording: \(error.localizedDescription)")
            _ = stop()
            return false
        }
    }

    func stop() -> Data? {
        audioRecorder?.stop()
        audioRecorder = nil
        guard let url = recordingURL else { return nil }
        recordingURL = nil
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        return data
    }
}
