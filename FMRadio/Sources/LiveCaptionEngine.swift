import Foundation
import AVFoundation
import Speech

/// 一条已经识别完成的字幕。只保留最近若干条，避免长时间播放占用内存。
struct CaptionLine: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// Apple Speech 实时字幕引擎。
/// 只接收解码后的 PCM，不访问麦克风，也不读取网络。
final class LiveCaptionEngine {
    /// 主线程回调：已完成字幕、当前临时结果、状态文本。
    var onUpdate: (([CaptionLine], String, String) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var isRunning = false
    private var pendingStart = false
    private var preferOnDevice = true
    private var didFallback = false

    private(set) var lines: [CaptionLine] = []
    private(set) var partialText: String = ""
    private(set) var status: String = ""

    func requestAuthorizationIfNeeded() {
        SFSpeechRecognizer.requestAuthorization { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.pendingStart {
                    self.pendingStart = false
                    if granted == .authorized {
                        self.start()
                    } else {
                        self.setStatus("语音识别未授权，请在系统设置中开启")
                    }
                }
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            pendingStart = true
            requestAuthorizationIfNeeded()
            setStatus("等待语音识别授权…")
            return
        case .denied, .restricted:
            setStatus("语音识别未授权，请在系统设置中开启")
            return
        case .authorized:
            break
        @unknown default:
            break
        }
        isRunning = true
        didFallback = false
        preferOnDevice = true
        beginTask()
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let request = request else { return }
        request.append(buffer)
    }

    func stop() {
        pendingStart = false
        isRunning = false
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        partialText = ""
        setStatus("")
    }

    func reset() {
        stop()
        lines.removeAll()
        publish()
    }

    private func beginTask() {
        guard isRunning else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) else {
            fallbackOrFail("当前设备不支持中文语音识别")
            return
        }
        if !recognizer.isAvailable {
            fallbackOrFail("语音识别器暂不可用")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 13.0, *) {
            request.requiresOnDeviceRecognition = preferOnDevice
        }

        self.recognizer = recognizer
        self.request = request
        setStatus(preferOnDevice ? "本地识别中…" : "识别中…")

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                self?.handle(result: result, error: error)
            }
        }
    }

    private func fallbackOrFail(_ message: String) {
        if preferOnDevice && !didFallback {
            didFallback = true
            preferOnDevice = false
            task = nil
            request = nil
            beginTask()
            return
        }
        setStatus(message)
        isRunning = false
        publish()
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        guard isRunning else { return }

        if let result = result {
            let text = result.bestTranscription.formattedString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            partialText = text
            publish()

            if result.isFinal {
                if !text.isEmpty {
                    lines.append(CaptionLine(text: text))
                    if lines.count > 8 { lines.removeFirst(lines.count - 8) }
                }
                partialText = ""
                publish()
                task = nil
                request = nil
                beginTask()
                return
            }
        }

        if let error = error {
            if preferOnDevice && !didFallback {
                didFallback = true
                preferOnDevice = false
                task = nil
                request = nil
                beginTask()
                return
            }
            let text = error.localizedDescription
            if text.localizedCaseInsensitiveContains("no speech detected") {
                setStatus("未检测到可识别语音（纯音乐或信号较弱时可能没有字幕）")
            } else {
                setStatus("识别失败：\(text)")
            }
            // 不把语音识别失败当作播放错误；AVPlayer 仍在正常出声。
            isRunning = false
            publish()
        }
    }

    private func setStatus(_ text: String) {
        status = text
        publish()
    }

    private func publish() {
        onUpdate?(lines, partialText, status)
    }
}
