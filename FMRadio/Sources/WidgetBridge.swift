import Foundation
import SwiftUI
import WidgetKit

struct WidgetBridgeView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var catalog: CatalogStore
    @Environment(\.scenePhase) private var scenePhase

    private static let artworkCache = NSCache<NSString, NSData>()

    var body: some View {
        let _ = store.themeColor
        let _ = catalog.selectedSourceID
        EmptyView()
            .onAppear {
                WidgetCommandHandler.shared.configure(player: player, store: store, catalog: catalog)
                WidgetCommandHandler.shared.installObserver()
                WidgetCommandHandler.shared.consumePendingCommand()
                refresh()
            }
            .onChange(of: scenePhase) { _ in
                WidgetCommandHandler.shared.consumePendingCommand()
                self.refresh()
            }
            .onReceive(player.objectWillChange) { _ in scheduleRefresh() }
            .onReceive(store.objectWillChange) { _ in scheduleRefresh() }
            .onReceive(catalog.objectWillChange) { _ in scheduleRefresh() }
    }

    private func scheduleRefresh() {
        DispatchQueue.main.async { self.refresh() }
    }

    private func refresh() {
        WidgetShared.saveTheme(store.themeColor)
        let current = player.current
        let snapshot = WidgetSnapshot(
            current: current.map { widgetStation($0, includeArtwork: true) },
            isPlaying: player.isPlaying,
            theme: store.themeColor,
            recents: store.recents.prefix(4).compactMap { station(for: $0) }.map { widgetStation($0, includeArtwork: false) },
            favorites: store.favorites.prefix(8).compactMap { station(for: $0) }.map { widgetStation($0, includeArtwork: false) },
            updatedAt: Date()
        )
        snapshot.save()
        WidgetShared.savePlaylist(catalog.visibleStations.map {
            WidgetPlaylistItem(id: $0.id, name: $0.name, desc: $0.desc, region: $0.region, url: $0.url, img_url: $0.img_url)
        })
        WidgetShared.reloadWidget()
        if let current = current { preloadArtwork(for: current) }
    }

    private func station(for id: String) -> Station? {
        catalog.station(id: id) ?? catalog.visibleStations.first { $0.id == id }
    }

    private func widgetStation(_ station: Station, includeArtwork: Bool) -> WidgetStation {
        let data = includeArtwork ? station.img_url.flatMap { Self.artworkCache.object(forKey: $0 as NSString) as Data? } : nil
        return WidgetStation(
            id: station.id,
            name: station.name,
            desc: station.desc,
            region: station.region,
            artworkData: data
        )
    }

    private func preloadArtwork(for station: Station) {
        guard let value = station.img_url, !value.isEmpty,
              Self.artworkCache.object(forKey: value as NSString) == nil,
              let url = normalizedURL(value) else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let image = UIImage(data: data), let prepared = Self.compressedArtwork(image) else { return }
            Self.artworkCache.setObject(prepared as NSData, forKey: value as NSString)
            DispatchQueue.main.async { self.refresh() }
        }.resume()
    }

    private func normalizedURL(_ value: String) -> URL? {
        if let url = URL(string: value), url.scheme != nil { return url }
        if let url = URL(string: "https://" + value), url.host != nil { return url }
        return URL(string: "http://" + value)
    }

    private static func compressedArtwork(_ image: UIImage) -> Data? {
        guard image.size.width > 0, image.size.height > 0 else { return image.jpegData(compressionQuality: 0.82) }
        let maxSide: CGFloat = 720
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.82)
    }
}

/// Main-app side command handler. Widget intents write a command to App Group and post a
/// Darwin notification; this handler reads it and controls the existing player in place.
private final class WidgetCommandHandler {
    static let shared = WidgetCommandHandler()

    private weak var player: AudioPlayer?
    private weak var store: Store?
    private weak var catalog: CatalogStore?
    private var observer: WidgetCommandObserver?
    private var installed = false

    func configure(player: AudioPlayer, store: Store, catalog: CatalogStore) {
        self.player = player
        self.store = store
        self.catalog = catalog
    }

    func installObserver() {
        guard !installed else { return }
        installed = true
        observer = WidgetCommandObserver { [weak self] in
            self?.consumePendingCommand()
        }
    }

    func consumePendingCommand() {
        guard let cmd = WidgetShared.consumeCommand() else { return }
        apply(cmd)
    }

    private func apply(_ cmd: WidgetCommand) {
        DispatchQueue.main.async {
            guard let player = self.player, let catalog = self.catalog, let store = self.store else { return }
            if cmd.at < Date().timeIntervalSince1970 - 3600 { return }
            player.playlist = catalog.visibleStations
            switch cmd.action {
            case "toggle":
                player.toggle()
            case "next":
                player.next()
            case "previous":
                player.previous()
            case "play":
                guard let id = cmd.stationID,
                      let s = catalog.station(id: id) ?? catalog.visibleStations.first(where: { $0.id == id }) else { return }
                player.play(s)
                store.touch(s)
            default:
                break
            }
        }
    }
}

/// Darwin notification observer kept as a class so it stays alive for the app session.
private final class WidgetCommandObserver {
    private let callback: () -> Void
    private let center = CFNotificationCenterGetDarwinNotifyCenter()

    init(callback: @escaping () -> Void) {
        self.callback = callback
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<WidgetCommandObserver>.fromOpaque(observer).takeUnretainedValue()
                me.callback()
            },
            WidgetShared.commandNotification as CFString,
            nil,
            .deliverImmediately
        )
    }
    deinit {
        CFNotificationCenterRemoveObserver(center, Unmanaged.passUnretained(self).toOpaque(), nil, nil)
    }
}
