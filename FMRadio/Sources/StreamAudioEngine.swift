import Foundation
import AVFoundation
import AudioToolbox

/// 实时字幕用的旁路音频源。
///
/// 重要：这个类**不播放声音**。声音始终由 AVPlayer 负责；这里只获取同一路
/// 电台流、去掉 ICY metadata、解码为 PCM 后交给 Apple Speech。这样即使某些
/// 流的格式不适合字幕解码，也不会影响正常播放。
final class StreamAudioEngine: NSObject {
    var onStateChange: ((Bool, String?) -> Void)?
    var onPCM: ((AVAudioPCMBuffer) -> Void)?
    var onFallback: (() -> Void)?

    /// 保留字段以兼容现有调用；旁路解码不控制音量。
    var volume: Float = 1.0

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var stopped = true
    private var fallbackSent = false

    private var headerBuffer = Data()
    private var headersDone = false
    private var icyInterval = 0
    private var icyRemaining = 0
    private var didConnect = false

    private var fileStream: AudioFileStreamID?
    private var converter: AudioConverterRef?
    private var inputFormat = AudioStreamBasicDescription()
    private var outputFormat = AudioStreamBasicDescription()
    private var magicCookie: Data?

    private struct Packet { let data: Data; let frames: UInt32 }
    private var packets: [Packet] = []
    private let lock = NSLock()
    private let outputByteSize = 16 * 1024

    // MARK: - Public

    func play(url: URL) {
        stop()
        stopped = false
        fallbackSent = false
        headersDone = false
        didConnect = false
        headerBuffer.removeAll()
        icyInterval = 0
        icyRemaining = 0

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("FMRadio/1.0.3 LiveCaption", forHTTPHeaderField: "User-Agent")
        task = session.dataTask(with: request)
        task?.resume()
        onStateChange?(false, "正在连接字幕音频流…")
    }

    func pause() {
        stop()
    }

    func resume() {
        // 由 AudioPlayer 用当前电台 URL 重新 play(url:) 启动。
    }

    func stop() {
        stopped = true
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        if let fs = fileStream { AudioFileStreamClose(fs) }
        fileStream = nil
        if let c = converter { AudioConverterDispose(c) }
        converter = nil
        magicCookie = nil
        lock.lock(); packets.removeAll(); lock.unlock()
        onStateChange?(false, nil)
    }

    private func fallback() {
        guard !fallbackSent else { return }
        fallbackSent = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stopped = true
            self.onFallback?()
        }
    }

    // MARK: - Stream data

    private func consume(_ data: Data) {
        if !headersDone {
            headerBuffer.append(data)
            guard let sep = headerBuffer.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) else { return }
            let head = headerBuffer.subdata(in: 0..<sep.lowerBound)
            let body = Data(headerBuffer[sep.upperBound...])
            headerBuffer.removeAll()
            headersDone = true
            parseHeaders(head)
            if !body.isEmpty { consume(body) }
            return
        }

        var bytes = [UInt8](data)
        if icyInterval > 0 {
            while !bytes.isEmpty {
                if icyRemaining == 0 {
                    let length = Int(bytes.remove(at: 0)) * 16
                    icyRemaining = icyInterval
                    if length > 0, bytes.count >= length { bytes.removeFirst(length) }
                    else if length > 0 { bytes.removeAll() }
                } else {
                    let take = min(icyRemaining, bytes.count)
                    bytes.removeFirst(take)
                    icyRemaining -= take
                }
            }
        }
        if !bytes.isEmpty { parse(bytes) }
    }

    private func parseHeaders(_ data: Data) {
        guard let text = String(data: data, encoding: .isoLatin1) else { return }
        for line in text.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if key == "icy-metaint", let n = Int(value), n > 0 {
                icyInterval = n; icyRemaining = n
            }
        }
    }

    private func parse(_ bytes: [UInt8]) {
        if fileStream == nil {
            var fs: AudioFileStreamID?
            let status = bytes.withUnsafeBytes { raw in
                AudioFileStreamOpen(Unmanaged.passUnretained(self).toOpaque(),
                                    propertyListener, packetListener, 0, &fs)
            }
            guard status == noErr, let opened = fs else { fallback(); return }
            fileStream = opened
        }
        guard let fs = fileStream else { return }
        var mutable = bytes
        _ = mutable.withUnsafeMutableBytes { raw in
            AudioFileStreamParseBytes(fs, UInt32(raw.count), raw.baseAddress, [])
        }
    }

    private let propertyListener: AudioFileStream_PropertyListenerProc = { ref, _, property, _ in
        let engine = Unmanaged<StreamAudioEngine>.fromOpaque(ref).takeUnretainedValue()
        engine.handleProperty(property)
    }

    private let packetListener: AudioFileStream_PacketsProc = { ref, byteCount, packetCount, bytes, descriptions in
        let engine = Unmanaged<StreamAudioEngine>.fromOpaque(ref).takeUnretainedValue()
        engine.handlePackets(byteCount: Int(byteCount), packetCount: Int(packetCount), bytes: bytes, descriptions: descriptions)
    }

    private func handleProperty(_ property: AudioFileStreamPropertyID) {
        guard let fs = fileStream else { return }
        if property == kAudioFileStreamProperty_DataFormat {
            var fmt = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            if AudioFileStreamGetProperty(fs, property, &size, &fmt) == noErr {
                inputFormat = fmt
                setupConverterIfNeeded()
            }
        } else if property == kAudioFileStreamProperty_MagicCookieData {
            var size: UInt32 = 0
            guard AudioFileStreamGetPropertyInfo(fs, property, &size, nil) == noErr, size > 0 else { return }
            var cookie = Data(count: Int(size))
            let ok = cookie.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return AudioFileStreamGetProperty(fs, property, &size, base)
            }
            if ok == noErr {
                magicCookie = cookie
                applyMagicCookie()
                setupConverterIfNeeded()
            }
        }
    }

    private func handlePackets(byteCount: Int, packetCount: Int, bytes: UnsafeRawPointer?, descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard let bytes = bytes, byteCount > 0 else { return }
        let base = bytes.assumingMemoryBound(to: UInt8.self)
        var decoded: [Packet] = []

        if packetCount > 0 {
            for i in 0..<packetCount {
                let desc = descriptions?[i]
                let offset = desc.map { Int($0.mStartOffset) } ?? 0
                let length = desc.map { Int($0.mDataByteSize) } ?? byteCount / packetCount
                guard offset >= 0, length > 0, offset + length <= byteCount else { continue }
                decoded.append(Packet(data: Data(bytes: base + offset, count: length),
                                      frames: desc?.mVariableFramesInPacket ?? 0))
            }
        } else {
            decoded.append(Packet(data: Data(bytes: base, count: byteCount), frames: 0))
        }

        lock.lock(); packets.append(contentsOf: decoded); lock.unlock()
        setupConverterIfNeeded()
        drainConverter()
    }

    // MARK: - Decode only (no playback)

    private func setupConverterIfNeeded() {
        guard converter == nil, inputFormat.mSampleRate > 0 else { return }

        var output = AudioStreamBasicDescription()
        output.mSampleRate = 44100
        output.mFormatID = kAudioFormatLinearPCM
        output.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        output.mChannelsPerFrame = 1
        output.mFramesPerPacket = 1
        output.mBytesPerFrame = 4
        output.mBytesPerPacket = 4
        output.mBitsPerChannel = 32
        outputFormat = output

        var conv: AudioConverterRef?
        guard AudioConverterNew(&inputFormat, &outputFormat, &conv) == noErr, let c = conv else {
            fallback()
            return
        }
        converter = c
        applyMagicCookie()

        if !didConnect {
            didConnect = true
            onStateChange?(true, "字幕音频已连接")
        }
    }

    private func applyMagicCookie() {
        guard let c = converter, let cookie = magicCookie, cookie.count > 0 else { return }
        let size = UInt32(cookie.count)
        _ = cookie.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            AudioConverterSetProperty(c, kAudioConverterDecompressionMagicCookie, size,
                                      UnsafeMutableRawPointer(mutating: base))
        }
    }

    private func drainConverter() {
        guard let conv = converter else { return }

        while true {
            let available: Int = { lock.lock(); defer { lock.unlock() }; return packets.count }()
            if available == 0 { return }

            var outputBytes = [UInt8](repeating: 0, count: outputByteSize)
            let produced = outputBytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                var outData = AudioBufferList(mNumberBuffers: 1,
                                              mBuffers: AudioBuffer(mNumberChannels: 1,
                                                                    mDataByteSize: UInt32(outputByteSize),
                                                                    mData: base))
                var outPackets: UInt32 = UInt32(outputByteSize / Int(outputFormat.mBytesPerPacket))
                let status = AudioConverterFillComplexBuffer(conv, inputCallback,
                                                            Unmanaged.passUnretained(self).toOpaque(),
                                                            &outPackets, &outData, nil)
                guard status == noErr else { return 0 }
                return Int(outData.mBuffers.mDataByteSize)
            }

            guard produced > 0 else { return }
            let frames = produced / Int(outputFormat.mBytesPerFrame)
            guard frames > 0,
                  let format = AVAudioFormat(streamDescription: &outputFormat),
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }

            pcm.frameLength = AVAudioFrameCount(frames)
            if let channel = pcm.floatChannelData?.pointee {
                outputBytes.withUnsafeBytes { raw in
                    guard let src = raw.baseAddress else { return }
                    channel.update(from: src.assumingMemoryBound(to: Float.self), count: frames)
                }
            }
            let captured = pcm
            DispatchQueue.main.async { [weak self] in self?.onPCM?(captured) }
        }
    }

    private let inputCallback: AudioConverterComplexInputDataProc = { _, count, data, descriptions, ref in
        guard let ref = ref else { return -1 }
        let engine = Unmanaged<StreamAudioEngine>.fromOpaque(ref).takeUnretainedValue()
        return engine.provide(count: count, data: data, descriptions: descriptions)
    }

    private func provide(count: UnsafeMutablePointer<UInt32>, data: UnsafeMutablePointer<AudioBufferList>, descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {
        lock.lock()
        let available = packets.count
        lock.unlock()
        guard available > 0, let target = data.pointee.mBuffers.mData else {
            count.pointee = 0
            data.pointee.mBuffers.mDataByteSize = 0
            return noErr
        }

        let capacity = Int(data.pointee.mBuffers.mDataByteSize)
        var offset = 0
        var used = 0

        lock.lock()
        while packets.count > 0 {
            let item = packets[0]
            let size = item.data.count
            if used > 0, offset + size > capacity { break }
            packets.removeFirst()
            let copied = item.data.withUnsafeBytes { raw -> Int in
                guard let src = raw.baseAddress else { return 0 }
                memcpy(target.advanced(by: offset), src, size)
                return size
            }
            guard copied > 0 else { continue }
            if let desc = descriptions?.pointee {
                let d = AudioStreamPacketDescription(mStartOffset: Int64(offset),
                                                     mVariableFramesInPacket: item.frames,
                                                     mDataByteSize: UInt32(copied))
                desc[used] = d
            }
            offset += copied
            used += 1
        }
        lock.unlock()

        data.pointee.mBuffers.mDataByteSize = UInt32(offset)
        count.pointee = UInt32(used)
        return noErr
    }
}

extension StreamAudioEngine: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            onStateChange?(false, "字幕音频流返回 HTTP \(http.statusCode)")
            fallback()
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stopped else { return }
        consume(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !stopped else { return }
        if let error = error {
            onStateChange?(false, "字幕音频流中断: \(error.localizedDescription)")
            fallback()
        }
    }
}
