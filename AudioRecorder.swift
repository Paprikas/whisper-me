import Cocoa
import AVFoundation
import AVFAudio

class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var audioRecorder: AVAudioRecorder?
    private var recordedData = Data()

    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            completion(granted)
        }
    }

    func start() {
        recordedData = Data()

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        // Use a temporary file that AVAudioRecorder appends into; simpler: memory buffer via delegate
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper-me-recording.wav")

        do {
            audioRecorder = try AVAudioRecorder(url: tmpURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
        } catch {
            print("❌ Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stop() -> Data? {
        guard let recorder = audioRecorder, recorder.isRecording else { return nil }
        recorder.stop()
        audioRecorder = nil

        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper-me-recording.wav")
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        return data
    }
}
