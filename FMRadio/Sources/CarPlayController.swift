import Foundation
import UIKit
import MediaPlayer
import CarPlay

/// CarPlay 模板场景代理。Info.plist 中的 CPTemplateApplicationSceneSessionRoleApplication
/// 会指向这个类；只有带 com.apple.developer.carplay-audio entitlement 的签名包才会真正出现在车机。
@available(iOS 14.0, *)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        CarPlayController.shared.connect(interfaceController)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController) {
        CarPlayController.shared.disconnect(interfaceController)
    }
}

/// CarPlay 音频入口：根目录 / 最近 / 收藏 / 地区 / 全部电台，并复用现有 AudioPlayer 播放。
@available(iOS 14.0, *)
final class CarPlayController {
    static let shared = CarPlayController()

    private weak var player: AudioPlayer?
    private weak var store: Store?
    private weak var catalog: CatalogStore?
    private weak var interfaceController: CPInterfaceController?
    private var rootTemplate: CPListTemplate?
    private let imageCache = NSCache<NSString, UIImage>()

    private init() {}

    func configure(player: AudioPlayer, store: Store, catalog: CatalogStore) {
        self.player = player
        self.store = store
        self.catalog = catalog
        player.playlist = catalog.visibleStations
    }

    func connect(_ controller: CPInterfaceController) {
        interfaceController = controller
        CPNowPlayingTemplate.shared.isUpNextButtonEnabled = false
        rebuildRoot()
    }

    func disconnect(_ controller: CPInterfaceController) {
        if interfaceController === controller {
            interfaceController = nil
            rootTemplate = nil
        }
    }

    /// 数据或播放状态变化时调用；重建当前根模板即可，CarPlay 会保留导航栈状态。
    func refresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.interfaceController != nil else { return }
            self.rebuildRoot()
        }
    }

    private func rebuildRoot() {
        guard let controller = interfaceController else { return }
        player?.playlist = catalog?.visibleStations ?? []

        let template = CPListTemplate(title: "收音机", sections: rootSections())
        rootTemplate = template
        controller.setRootTemplate(template, animated: false, completion: nil)
    }

    private func rootSections() -> [CPListSection] {
        var sections: [CPListSection] = []

        sections.append(CPListSection(items: playbackItems(), header: "正在播放", sectionIndexTitle: nil))

        var browse: [CPListItem] = []
        browse.append(makeItem(text: "最近播放",
                               detailText: "\(store?.recents.count ?? 0) 个电台",
                               image: UIImage(systemName: "clock"),
                               accessory: .disclosureIndicator) { [weak self] _, completion in
            self?.pushRecentStations()
            completion()
        })
        browse.append(makeItem(text: "收藏",
                               detailText: "\(store?.favorites.count ?? 0) 个电台",
                               image: UIImage(systemName: "heart"),
                               accessory: .disclosureIndicator) { [weak self] _, completion in
            self?.pushFavoriteStations()
            completion()
        })
        browse.append(makeItem(text: "按地区",
                               detailText: "\(catalog?.regions.count ?? 0) 个地区",
                               image: UIImage(systemName: "globe"),
                               accessory: .disclosureIndicator) { [weak self] _, completion in
            self?.pushRegions()
            completion()
        })
        browse.append(makeItem(text: "全部电台",
                               detailText: "\(catalog?.visibleStations.count ?? 0) 个电台 · \(catalog?.selectedSourceTitle() ?? "全部")",
                               image: UIImage(systemName: "radio"),
                               accessory: .disclosureIndicator) { [weak self] _, completion in
            self?.pushAllStations()
            completion()
        })
        sections.append(CPListSection(items: browse, header: "电台", sectionIndexTitle: nil))

        return sections
    }

    private func playbackItems() -> [CPListItem] {
        let current = player?.current
        let playing = player?.isPlaying ?? false

        let now = makeItem(text: "正在播放",
                           detailText: current.map { playing ? "播放中 · \($0.name)" : "已暂停 · \($0.name)" } ?? "暂无电台",
                           image: UIImage(systemName: "waveform"),
                           accessory: .disclosureIndicator) { [weak self] _, completion in
            DispatchQueue.main.async {
                self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared,
                                                        animated: true,
                                                        completion: nil)
                completion()
            }
        }

        let toggle = makeItem(text: playing ? "暂停" : "播放",
                              detailText: current?.name ?? "选择一个电台后开始播放",
                              image: UIImage(systemName: playing ? "pause.fill" : "play.fill"),
                              accessory: .none) { [weak self] _, completion in
            DispatchQueue.main.async {
                self?.togglePlayback()
                completion()
            }
        }

        let previous = makeItem(text: "上一个",
                                detailText: nil,
                                image: UIImage(systemName: "backward.fill"),
                                accessory: .none) { [weak self] _, completion in
            DispatchQueue.main.async {
                self?.player?.playlist = self?.catalog?.visibleStations ?? []
                self?.player?.previous()
                completion()
            }
        }

        let next = makeItem(text: "下一个",
                            detailText: nil,
                            image: UIImage(systemName: "forward.fill"),
                            accessory: .none) { [weak self] _, completion in
            DispatchQueue.main.async {
                self?.player?.playlist = self?.catalog?.visibleStations ?? []
                self?.player?.next()
                completion()
            }
        }

        return [now, toggle, previous, next]
    }

    private func makeItem(text: String,
                          detailText: String?,
                          image: UIImage?,
                          accessory: CPListItemAccessoryType,
                          handler: @escaping (CPSelectableListItem, @escaping () -> Void) -> Void) -> CPListItem {
        let item = CPListItem(text: text,
                              detailText: detailText,
                              image: image,
                              accessoryImage: nil,
                              accessoryType: accessory)
        item.handler = handler
        return item
    }

    private func stationItems(_ stations: [Station]) -> [CPListItem] {
        stations.prefix(300).map { station in
            let item = CPListItem(text: station.name,
                                  detailText: detail(for: station),
                                  image: UIImage(systemName: "radio"),
                                  accessoryImage: nil,
                                  accessoryType: .none)
            item.handler = { [weak self] _, completion in
                DispatchQueue.main.async {
                    self?.play(station)
                    completion()
                }
            }
            loadArtwork(for: station, into: item)
            return item
        }
    }

    private func detail(for station: Station) -> String? {
        let parts = [station.desc, station.region].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func station(withID id: String) -> Station? {
        catalog?.station(id: id) ?? catalog?.visibleStations.first { $0.id == id }
    }

    private func section(title: String?, stations: [Station]) -> CPListSection {
        CPListSection(items: stationItems(stations), header: title ?? "", sectionIndexTitle: nil)
    }

    private func pushRecentStations() {
        let list = (store?.recents ?? []).compactMap(station(withID:))
        push(CPListTemplate(title: "最近播放", sections: [section(title: nil, stations: list)]))
    }

    private func pushFavoriteStations() {
        let list = (store?.favorites ?? []).compactMap(station(withID:))
        push(CPListTemplate(title: "收藏", sections: [section(title: nil, stations: list)]))
    }

    private func pushRegions() {
        guard let catalog = catalog else { return }
        let items = catalog.regions.map { region in
            let count = catalog.visibleStations.filter { $0.region == region }.count
            let item = CPListItem(text: region,
                                  detailText: "\(count) 个电台",
                                  image: UIImage(systemName: "globe"),
                                  accessoryImage: nil,
                                  accessoryType: .disclosureIndicator)
            item.handler = { [weak self] _, completion in
                let stations = catalog.visibleStations.filter { $0.region == region }
                self?.push(CPListTemplate(title: region, sections: [self?.section(title: nil, stations: stations) ?? CPListSection(items: [], header: nil, sectionIndexTitle: nil)]))
                completion()
            }
            return item
        }
        push(CPListTemplate(title: "按地区", sections: [CPListSection(items: items, header: nil, sectionIndexTitle: nil)]))
    }

    private func pushAllStations() {
        guard let catalog = catalog else { return }
        let sections = catalog.regions.map { region in
            section(title: region, stations: catalog.visibleStations.filter { $0.region == region })
        }
        push(CPListTemplate(title: "全部电台", sections: sections))
    }

    private func push(_ template: CPTemplate) {
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func togglePlayback() {
        guard let player = player else { return }
        if player.current == nil, let first = catalog?.visibleStations.first {
            play(first)
        } else {
            player.toggle()
        }
    }

    private func play(_ station: Station) {
        guard let player = player, let catalog = catalog else { return }
        player.playlist = catalog.visibleStations
        if !player.playlist.contains(where: { $0.id == station.id }) {
            player.playlist = catalog.stations
        }
        player.play(station)
        store?.touch(station)
        refresh()
    }

    private func loadArtwork(for station: Station, into item: CPListItem) {
        guard let value = station.img_url, !value.isEmpty, let url = normalizedURL(value) else { return }
        let key = value as NSString
        if let cached = imageCache.object(forKey: key) {
            item.setImage(cached)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data, let image = UIImage(data: data) else { return }
            let prepared = self.squareImage(image)
            self.imageCache.setObject(prepared, forKey: key)
            DispatchQueue.main.async { item.setImage(prepared) }
        }.resume()
    }

    private func normalizedURL(_ value: String) -> URL? {
        if let url = URL(string: value), url.scheme != nil { return url }
        if let url = URL(string: "https://" + value), url.host != nil { return url }
        return URL(string: "http://" + value)
    }

    private func squareImage(_ image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return image }
        let origin = CGPoint(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2)
        let crop = CGRect(origin: origin, size: CGSize(width: side, height: side))
        let cropped: UIImage
        if let cg = image.cgImage?.cropping(to: crop) {
            cropped = UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
        } else {
            cropped = image
        }
        let outputSize = CGSize(width: 96, height: 96)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            cropped.draw(in: CGRect(origin: .zero, size: outputSize))
        }
    }
}
