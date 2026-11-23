import Foundation
import WidgetKit

enum WidgetShared {
    static let appGroup = "group.com.oaife.radio"
    static let snapshotKey = "FMRadioWidgetSnapshot"
    static let playlistKey = "FMRadioWidgetPlaylist"
    static let commandKey = "FMRadioWidgetCommand"
    static let themeKey = "FMRadioThemeColor"
    static let commandNotification = "com.oaife.radio.widget.command"

    private static let widgetKind = "FMRadioWidget"

    private static let snapshotFile = "FMRadioWidgetSnapshot.json"
    private static let playlistFile = "FMRadioWidgetPlaylist.json"
    private static let commandFile = "FMRadioWidgetCommand.json"
    private static let themeFile = "FMRadioThemeColor.txt"

    private static var ud: UserDefaults? { UserDefaults(suiteName: appGroup) }

    private static var containerURL: URL? {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func fileURL(_ name: String) -> URL? {
        containerURL?.appendingPathComponent(name, isDirectory: false)
    }

    private static func readFile(_ name: String) -> Data? {
        guard let url = fileURL(name) else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func writeFile(_ name: String, data: Data) {
        guard let url = fileURL(name) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func removeFile(_ name: String) {
        guard let url = fileURL(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func saveJSON<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        writeFile(name, data: data)
    }

    private static func loadJSON<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = readFile(name) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func saveTheme(_ name: String) {
        ud?.set(name, forKey: themeKey)
        writeFile(themeFile, data: Data(name.utf8))
    }

    static func loadTheme() -> String? {
        if let data = readFile(themeFile), let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return value
        }
        return ud?.string(forKey: themeKey)
    }

    static func savePlaylist(_ items: [WidgetPlaylistItem]) {
        saveJSON(items, playlistFile)
        guard let ud = ud, let data = try? JSONEncoder().encode(items) else { return }
        ud.set(data, forKey: playlistKey)
    }

    static func loadPlaylist() -> [WidgetPlaylistItem] {
        if let items: [WidgetPlaylistItem] = loadJSON([WidgetPlaylistItem].self, playlistFile) {
            return items
        }
        guard let ud = ud, let data = ud.data(forKey: playlistKey) else { return [] }
        return (try? JSONDecoder().decode([WidgetPlaylistItem].self, from: data)) ?? []
    }

    static func loadSnapshot() -> WidgetSnapshot? {
        var decoded: WidgetSnapshot? = loadJSON(WidgetSnapshot.self, snapshotFile)
        if decoded == nil, let data = ud?.data(forKey: snapshotKey) {
            decoded = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        }
        guard var snapshot = decoded else { return nil }
        if let theme = loadTheme(), !theme.isEmpty {
            snapshot.theme = theme
        }
        return snapshot
    }

    static func saveSnapshot(_ snapshot: WidgetSnapshot) {
        saveJSON(snapshot, snapshotFile)
        if let data = try? JSONEncoder().encode(snapshot) {
            ud?.set(data, forKey: snapshotKey)
        }
    }

    static func reloadWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// App Intent / widget 写入控制命令，主 App 通过 Darwin 通知或启动时消费。
    static func postCommand(_ action: String, stationID: String?) {
        postCommand(WidgetCommand(action: action, stationID: stationID, at: Date().timeIntervalSince1970))
    }

    static func postCommand(_ command: WidgetCommand) {
        saveJSON(command, commandFile)
        if let ud = ud, let data = try? JSONEncoder().encode(command) {
            ud.set(data, forKey: commandKey)
        }
        #if canImport(CoreFoundation)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(commandNotification as CFString),
            nil, nil, true
        )
        #endif
    }

    /// iOS 17+ Button(intent:) 不会唤醒主 App。iOS 26/27 上 UserDefaults 也可能在 widget 进程里读到旧值，
    /// 因此命令同时写入 App Group 文件并立即重建快照，再强制 widget timeline 刷新。
    static func applyCommandToWidgetState(_ command: WidgetCommand) {
        var snapshot = loadSnapshot() ?? .placeholder
        let playlist = loadPlaylist()

        switch command.action {
        case "toggle":
            snapshot.isPlaying.toggle()

        case "play":
            if let id = command.stationID,
               let item = playlist.first(where: { $0.id == id }) ?? playlist.first(where: { $0.id == snapshot.current?.id }) {
                snapshot.current = WidgetStation(item: item, preserving: snapshot.existingStation(id: item.id))
                snapshot.isPlaying = true
            } else if snapshot.current == nil, let first = playlist.first {
                snapshot.current = WidgetStation(item: first, preserving: nil)
                snapshot.isPlaying = true
            } else if snapshot.current != nil {
                snapshot.isPlaying = true
            }

        case "next", "previous":
            guard !playlist.isEmpty else { break }
            let currentID = snapshot.current?.id ?? command.stationID
            let targetIndex: Int
            if let currentID = currentID, let found = playlist.firstIndex(where: { $0.id == currentID }) {
                if command.action == "next" {
                    targetIndex = (found + 1) % playlist.count
                } else {
                    targetIndex = (found - 1 + playlist.count) % playlist.count
                }
            } else {
                targetIndex = command.action == "next" ? 0 : playlist.count - 1
            }
            let item = playlist[targetIndex]
            snapshot.current = WidgetStation(item: item, preserving: snapshot.existingStation(id: item.id))

        default:
            break
        }

        snapshot.updatedAt = Date()
        snapshot.save()
    }

    static func consumeCommand() -> WidgetCommand? {
        var decoded: WidgetCommand? = loadJSON(WidgetCommand.self, commandFile)
        if decoded == nil, let data = ud?.data(forKey: commandKey) {
            decoded = try? JSONDecoder().decode(WidgetCommand.self, from: data)
        }
        removeFile(commandFile)
        ud?.removeObject(forKey: commandKey)
        return decoded
    }
}

struct WidgetCommand: Codable {
    var action: String
    var stationID: String?
    var at: TimeInterval
}

struct WidgetPlaylistItem: Codable, Hashable {
    var id: String
    var name: String
    var desc: String
    var region: String
    var url: String
    var img_url: String?
}

struct WidgetStation: Codable, Hashable {
    var id: String
    var name: String
    var desc: String
    var region: String
    var artworkData: Data?
}

struct WidgetSnapshot: Codable {
    var current: WidgetStation?
    var isPlaying: Bool
    var theme: String
    var recents: [WidgetStation]
    var favorites: [WidgetStation]
    var updatedAt: Date

    static var placeholder: WidgetSnapshot {
        WidgetSnapshot(
            current: WidgetStation(id: "demo", name: "收音机", desc: "FM 101.1", region: "默认", artworkData: nil),
            isPlaying: false,
            theme: "blue",
            recents: [],
            favorites: [],
            updatedAt: Date()
        )
    }

    static func load() -> WidgetSnapshot? {
        WidgetShared.loadSnapshot()
    }

    func save() {
        WidgetShared.saveSnapshot(self)
    }
}

extension WidgetStation {
    init(item: WidgetPlaylistItem, preserving existing: WidgetStation?) {
        self.init(
            id: item.id,
            name: item.name,
            desc: item.desc,
            region: item.region,
            artworkData: existing?.artworkData
        )
    }
}

extension WidgetSnapshot {
    func existingStation(id: String) -> WidgetStation? {
        if current?.id == id { return current }
        if let station = recents.first(where: { $0.id == id }) { return station }
        return favorites.first { $0.id == id }
    }
}

enum WidgetAction {
    static let scheme = "fmradio"

    static func url(_ action: String, id: String? = nil) -> URL {
        var value = "\(scheme)://\(action)"
        if let id = id, !id.isEmpty {
            value += "?id=\(id)"
        }
        return URL(string: value)!
    }
}
