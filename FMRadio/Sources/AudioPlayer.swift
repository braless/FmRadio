import Foundation
import AVFoundation
import MediaPlayer
import Combine

/// Playback engine. Mirrors the original `ZSVRadioPlayer` responsibilities:
/// AVPlayer streaming, AVAudioSession background audio, now-playing info and
/// remote-control (lock screen / headphone) play-pause handling.
final class AudioPlayer: ObservableObject {
    @Published var current: Station?
    @Published var isPlaying = false
    @Published var isBuffering = false
    @Published var errorMessage: String?
    @Published var volume: Float = 1.0 {
        didSet { player?.volume = volume; streamEngine?.volume = volume }
    }
    @Published var captionLines: [CaptionLine] = []
    @Published var captionPartial: String = ""
    @Published var captionStatus: String = ""

    var liveCaptionEnabled = false {
        didSet {
            guard oldValue != liveCaptionEnabled else { return }
            if liveCaptionEnabled {
                if isPlaying, let station = current, let url = URL(string: station.url) {
                    startCaptionFeed(station: station, url: url)
                }
            } else {
                caption.stop()
                streamEngine?.stop()
                streamEngine = nil
                captionLines.removeAll()
                captionPartial = ""
                captionStatus = ""
                publishCaptionState()
            }
        }
    }

    private let caption = LiveCaptionEngine()
    private var streamEngine: StreamAudioEngine?

    /// 全量电台目录，用于上一台/下一台切换；由 ContentView 在目录加载后注入。
    var playlist: [Station] = []

    private var player: AVPlayer?
    private var statusObserver: NSKeyValueObservation?
    private var timeControlObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?

    init() {
        configureSession()
        setupRemoteCommands()
        caption.onUpdate = { [weak self] lines, partial, status in
            guard let self = self else { return }
            self.captionLines = lines
            self.captionPartial = partial
            self.captionStatus = status
        }
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
        } catch {
            errorMessage = "音频会话配置失败: \(error.localizedDescription)"
        }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.play(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isPlaying { self.pause() } else { self.play() }
            return .success
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            DispatchQueue.main.async { [weak self] in self?.next() }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            DispatchQueue.main.async { [weak self] in self?.previous() }
            return .success
        }
    }

    func play(_ station: Station) {
        if current?.id == station.id { toggle(); return }
        stopEngines(clearNowPlaying: false)
        current = station
        errorMessage = nil
        storeStation(station)
        guard let url = URL(string: station.url) else {
            errorMessage = "无效的电台地址"; return
        }
        // 声音始终由 AVPlayer 负责；字幕是旁路，不能影响播放。
        startAVPlayer(url: url)
        if liveCaptionEnabled {
            startCaptionFeed(station: station, url: url)
        }
        updateNowPlaying()
    }

    private func startAVPlayer(url: URL) {
        let item = AVPlayerItem(url: url)
        statusObserver = item.observe(\.status) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isBuffering = false
                switch item.status {
                case .readyToPlay:
                    self.isPlaying = true
                    self.updateNowPlaying()
                case .failed:
                    self.isPlaying = false
                    self.errorMessage = item.error?.localizedDescription ?? "播放失败"
                case .unknown: break
                @unknown default: break
                }
            }
        }
        player = AVPlayer(playerItem: item)
        player?.volume = volume
        rateObserver = player?.observe(\.rate) { [weak self] p, _ in
            DispatchQueue.main.async { [weak self] in self?.isPlaying = p.rate > 0 }
        }
        isBuffering = true
        player?.play()
    }

    private func startCaptionFeed(station: Station, url: URL) {
        caption.reset()
        caption.start()
        let engine = StreamAudioEngine()
        engine.volume = volume
        engine.onStateChange = { [weak self] _, message in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.current?.id == station.id else { return }
                if let message = message, !message.isEmpty {
                    self.captionStatus = message
                    self.publishCaptionState()
                }
            }
        }
        engine.onPCM = { [weak self] buffer in
            self?.caption.feed(buffer)
        }
        engine.onFallback = { [weak self] in
            guard let self = self else { return }
            self.captionStatus = "当前电台暂不支持实时字幕，播放不受影响"
            self.publishCaptionState()
        }
        streamEngine = engine
        engine.play(url: url)
    }

    private func publishCaptionState() {
        captionLines = captionLines
        captionPartial = captionPartial
        captionStatus = captionStatus
        objectWillChange.send()
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    /// 切换下一台：没有显式目录时按当前台在 playlist 中的位置顺序切换。
    func next() {
        guard !playlist.isEmpty else { return }
        let idx = playlist.firstIndex { $0.id == current?.id } ?? -1
        let next = playlist[(idx + 1) % playlist.count]
        play(next)
    }

    /// 切换上一台：没有显式目录时回到最后一台。
    func previous() {
        guard !playlist.isEmpty else { return }
        let idx = playlist.firstIndex { $0.id == current?.id } ?? -1
        let prevIndex = idx <= 0 ? playlist.count - 1 : idx - 1
        play(playlist[prevIndex])
    }

    func play() {
        guard let player = player else {
            if let s = current { play(s) }
            return
        }
        player.play()
        isPlaying = true
        updateNowPlaying()

        if liveCaptionEnabled, let station = current, let url = URL(string: station.url),
           streamEngine == nil {
            startCaptionFeed(station: station, url: url)
        }
    }

    func pause() {
        player?.pause()
        streamEngine?.pause()
        streamEngine = nil
        caption.stop()
        isPlaying = false
        updateNowPlaying()
    }

    func stop() {
        stopEngines(clearNowPlaying: true)
    }

    private func stopEngines(clearNowPlaying: Bool) {
        statusObserver?.invalidate(); statusObserver = nil
        rateObserver?.invalidate(); rateObserver = nil
        timeControlObserver?.invalidate(); timeControlObserver = nil
        player?.pause()
        player = nil
        caption.stop()
        streamEngine?.stop()
        streamEngine = nil
        if clearNowPlaying {
            current = nil
            isPlaying = false
            isBuffering = false
            captionLines.removeAll()
            captionPartial = ""
            captionStatus = ""
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        } else {
            isPlaying = false
            isBuffering = false
        }
    }

    private func storeStation(_ station: Station) {
        // Store is injected by FMRadioApp; UserDefaults keeps this independent.
        let defaults = UserDefaults.standard
        var ids = defaults.stringArray(forKey: "RADIO_RECENT") ?? []
        ids.removeAll { $0 == station.id }
        ids.insert(station.id, at: 0)
        if ids.count > 30 { ids = Array(ids.prefix(30)) }
        defaults.set(ids, forKey: "RADIO_RECENT")
        defaults.set(station.id, forKey: "LAST_RADIO_STORE")
        NotificationCenter.default.post(name: Notification.Name("FMRadioDidTouchStation"), object: station.id)
    }

    private func updateNowPlaying() {
        guard let s = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: s.name,
            MPMediaItemPropertyArtist: s.desc,
            MPMediaItemPropertyAlbumTitle: s.region,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: 2, // audio
            MPNowPlayingInfoPropertyPlaybackQueueIndex: playlist.firstIndex { $0.id == s.id } ?? 0,
            MPNowPlayingInfoPropertyPlaybackQueueCount: max(playlist.count, 1)
        ]
        if let art = Self.artwork(for: s) ?? UIImage(named: "radio") {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: art.size) { _ in art }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadRemoteArtwork(for: s)
    }

    private static let artworkCache = NSCache<NSString, UIImage>()

    private static func artwork(for station: Station) -> UIImage? {
        guard let value = station.img_url, !value.isEmpty else { return nil }
        return artworkCache.object(forKey: value as NSString)
    }

    private func normalizedArtworkURL(_ value: String) -> URL? {
        if let url = URL(string: value), url.scheme != nil { return url }
        if let url = URL(string: "https://" + value), url.host != nil { return url }
        return URL(string: "http://" + value)
    }

    private func loadRemoteArtwork(for station: Station) {
        guard let value = station.img_url, !value.isEmpty,
              Self.artwork(for: station) == nil,
              let url = normalizedArtworkURL(value) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            Self.artworkCache.setObject(image, forKey: value as NSString)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.current?.id == station.id else { return }
                self.updateNowPlaying()
            }
        }.resume()
    }
}
