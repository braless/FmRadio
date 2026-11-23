import Foundation
import SwiftUI
import Combine

// MARK: - 电台源配置

/// 一个可配置的电台目录来源。内置官方接口是第一条默认配置。
struct RadioSource: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var urlString: String
    var enabled: Bool
    /// 电台数组在 JSON 中的路径，例如 "radio" 或 "data.list"。留空则自动识别。
    var listPath: String
    /// 字段名映射：App 字段 -> 接口字段
    var fields: FieldMap

    struct FieldMap: Codable, Hashable {
        var id: String
        var name: String
        var url: String
        var desc: String
        var region: String
        var image: String

        static let `default` = FieldMap(
            id: "radio_id", name: "name", url: "url",
            desc: "desc", region: "region", image: "img_url"
        )

        init(id: String = "radio_id", name: String = "name", url: String = "url",
             desc: String = "desc", region: String = "region", image: String = "img_url") {
            self.id = id; self.name = name; self.url = url
            self.desc = desc; self.region = region; self.image = image
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? "radio_id"
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "name"
            url = try c.decodeIfPresent(String.self, forKey: .url) ?? "url"
            desc = try c.decodeIfPresent(String.self, forKey: .desc) ?? "desc"
            region = try c.decodeIfPresent(String.self, forKey: .region) ?? "region"
            image = try c.decodeIfPresent(String.self, forKey: .image) ?? "img_url"
        }
    }

    static let builtinID = "builtin"

    static var builtin: RadioSource {
        RadioSource(
            id: builtinID,
            name: "默认",
            urlString: StationData.remoteURL,
            enabled: true,
            listPath: "radio",
            fields: .default
        )
    }

    var isBuiltin: Bool { id == RadioSource.builtinID }

    init(id: String = UUID().uuidString, name: String, urlString: String,
         enabled: Bool = true, listPath: String = "", fields: FieldMap = .default) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.enabled = enabled
        self.listPath = listPath
        self.fields = fields
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名源"
        urlString = try c.decodeIfPresent(String.self, forKey: .urlString) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        listPath = try c.decodeIfPresent(String.self, forKey: .listPath) ?? ""
        fields = try c.decodeIfPresent(FieldMap.self, forKey: .fields) ?? .default
    }
}

// MARK: - 通用解析器

enum StationParser {
    /// 依次尝试 JSON（按配置映射）和 M3U 文本。
    static func parse(_ data: Data, source: RadioSource) -> [Station] {
        if let list = parseJSON(data, source: source), !list.isEmpty { return list }
        return parseM3U(data)
    }

    private static func parseJSON(_ data: Data, source: RadioSource) -> [Station]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var array: [[String: Any]]?
        if let direct = root as? [[String: Any]] {
            array = direct
        } else if let dict = root as? [String: Any] {
            // 1) 用户指定的路径，支持点号分层，如 data.list
            if !source.listPath.trimmingCharacters(in: .whitespaces).isEmpty {
                array = value(at: source.listPath, in: dict) as? [[String: Any]]
            }
            // 2) 常见键名
            if array == nil {
                for key in ["radio", "stations", "list", "items", "results", "channels", "data"] {
                    if let found = dict[key] as? [[String: Any]] { array = found; break }
                }
            }
            // 3) 自动找出第一个「含名称与地址」的对象数组
            if array == nil {
                array = dict.values.compactMap { $0 as? [[String: Any]] }.first { items in
                    items.contains { d in
                        (firstString(d, keys: aliases(for: \.name, source: source)) != nil) &&
                        (firstString(d, keys: aliases(for: \.url, source: source)) != nil)
                    }
                }
            }
        }
        guard let array else { return nil }

        return array.compactMap { d -> Station? in
            guard let name = firstString(d, keys: aliases(for: \.name, source: source)),
                  let url = firstString(d, keys: aliases(for: \.url, source: source)),
                  !url.isEmpty else { return nil }
            let identifier = firstString(d, keys: aliases(for: \.id, source: source)) ?? url
            return Station(
                radio_id: identifier,
                name: name,
                desc: firstString(d, keys: aliases(for: \.desc, source: source)) ?? "",
                region: firstString(d, keys: aliases(for: \.region, source: source)) ?? "其他",
                url: url,
                img_url: firstString(d, keys: aliases(for: \.image, source: source)),
                tag: nil
            )
        }
    }

    /// keyPath 取值，支持 "a.b.c"
    private static func value(at path: String, in dict: [String: Any]) -> Any? {
        var node: Any? = dict
        for part in path.split(separator: ".").map({ String($0).trimmingCharacters(in: .whitespaces) }) {
            guard let d = node as? [String: Any] else { return nil }
            node = d[part]
        }
        return node
    }

    private static func aliases(for key: KeyPath<RadioSource.FieldMap, String>, source: RadioSource) -> [String] {
        let configured = source.fields[keyPath: key]
        let common: [String]
        switch key {
        case \.id:     common = ["radio_id", "id", "uuid", "stationId", "station_id"]
        case \.name:   common = ["name", "title", "radioName", "station", "channel"]
        case \.url:    common = ["url", "urlString", "stream", "streamUrl", "playUrl", "link"]
        case \.desc:   common = ["desc", "description", "intro", "subtitle"]
        case \.region: common = ["region", "area", "category", "group", "country"]
        case \.image:  common = ["img_url", "image", "logo", "cover", "pic", "img", "imgUrl", "imgurl", "pic_url", "thumbnail", "thumb"]
        default:       common = []
        }
        return ([configured] + common).filter { !$0.isEmpty }
    }

    private static func firstString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let s = dict[key] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                return s.trimmingCharacters(in: .whitespaces)
            }
            if let n = dict[key] as? NSNumber { return n.stringValue }
        }
        return nil
    }

    /// 简单 M3U：#EXTINF:-1,名称 后跟流地址
    static func parseM3U(_ data: Data) -> [Station] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        var result: [Station] = []
        var pendingName: String?
        for raw in text.split(separator: "\n") {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:") {
                let rest = line.dropFirst("#EXTINF:".count)
                if let comma = rest.firstIndex(of: ",") {
                    pendingName = String(rest[rest.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                }
            } else if !line.isEmpty && !line.hasPrefix("#") {
                let name = pendingName ?? (URL(string: line)?.host ?? "电台 \(result.count + 1)")
                result.append(Station(
                    radio_id: "m3u-\(result.count)-\(line.count)",
                    name: name, desc: "", region: "自定义", url: line,
                    img_url: nil, tag: nil
                ))
                pendingName = nil
            }
        }
        return result
    }
}

// MARK: - 目录管理

/// 电台目录管理：按配置并发加载多个来源，合并去重；全部失败时回退内置 1115 台。
struct RadioSourceOption: Identifiable, Hashable {
    let id: String
    let title: String
}

final class CatalogStore: ObservableObject {
    enum SourceSelection {
        static let all = "all"
        static let builtin = RadioSource.builtinID
    }

    @Published var sources: [RadioSource] = []
    /// 所有启用源的合并结果（保留用于收藏、搜索和“全部”）。
    @Published var stations: [Station] = StationData.all
    /// 当前源选择下可见的电台，主列表、地区页和播放队列都使用它。
    @Published var visibleStations: [Station] = StationData.all
    @Published var selectedSourceID: String = SourceSelection.all
    @Published var lastUpdated: Date?
    @Published var loadMessage: String?
    @Published var isBuiltinUnlocked: Bool = false

    private var stationsBySource: [String: [Station]] = [:]

    private let defaults = UserDefaults.standard
    private let sourcesKey = "RADIO_SOURCES"
    private let builtinUnlockedKey = "RADIO_BUILTIN_SOURCE_UNLOCKED"
    private let selectedSourceKey = "RADIO_SELECTED_SOURCE_ID"

    init() {
        loadSources()
        let saved = defaults.string(forKey: selectedSourceKey) ?? SourceSelection.all
        selectedSourceID = saved
        refreshVisibleStations()
        reload()
    }

    // MARK: 源配置持久化

    private func loadSources() {
        let unlocked = defaults.bool(forKey: builtinUnlockedKey)
        guard let data = defaults.data(forKey: sourcesKey),
              let decoded = try? JSONDecoder().decode([RadioSource].self, from: data),
              !decoded.isEmpty else {
            sources = [.builtin]
            isBuiltinUnlocked = unlocked
            saveSources()
            return
        }
        var list = decoded
        if !list.contains(where: { $0.id == RadioSource.builtinID }) { list.append(.builtin) }
        if let i = list.firstIndex(where: { $0.id == RadioSource.builtinID }) {
            var builtin = list.remove(at: i)
            // 覆盖安装时把旧官方地址自动迁移到新默认源；用户解锁编辑过则尊重其修改。
            if !unlocked && (builtin.urlString.isEmpty || builtin.urlString.contains("ioscndeveloper.cn")) {
                builtin = .builtin
            }
            list.insert(builtin, at: 0)
        }
        sources = list
        isBuiltinUnlocked = unlocked
    }

    private func saveSources() {
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(data, forKey: sourcesKey)
        }
    }

    func addSource(_ source: RadioSource) {
        sources.append(source)
        saveSources()
        reload()
    }

    func updateSource(_ source: RadioSource) {
        guard let i = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[i] = source
        saveSources()
        reload()
    }

    func removeSource(_ source: RadioSource) {
        guard !source.isBuiltin else { return }
        sources.removeAll { $0.id == source.id }
        saveSources()
        reload()
    }

    func moveSource(from: IndexSet, to: Int) {
        sources.move(fromOffsets: from, toOffset: to)
        if let i = sources.firstIndex(where: { $0.id == RadioSource.builtinID }), i != 0 {
            let item = sources.remove(at: i)
            sources.insert(item, at: 0)
        }
        saveSources()
        reload()
    }

    func resetSources() {
        sources = [.builtin]
        isBuiltinUnlocked = false
        defaults.set(false, forKey: builtinUnlockedKey)
        if !sourceOptions.contains(where: { $0.id == selectedSourceID }) {
            selectSource(SourceSelection.all)
        }
        saveSources()
        reload()
    }

    func setBuiltinUnlocked(_ value: Bool) {
        isBuiltinUnlocked = value
        defaults.set(value, forKey: builtinUnlockedKey)
    }

    // MARK: 加载

    func reload() {
        let enabled = sources.filter { $0.enabled && !$0.urlString.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !enabled.isEmpty else {
            stations = StationData.all
            stationsBySource = [RadioSource.builtinID: StationData.all]
            loadMessage = "未启用任何电台源，已使用内置目录"
            lastUpdated = Date()
            refreshVisibleStations()
            return
        }

        loadMessage = "正在更新电台目录…"
        let group = DispatchGroup()
        let lock = NSLock()
        var merged: [Station] = []
        var seen = Set<String>()
        var bySource: [String: [Station]] = [:]

        for source in enabled {
            group.enter()
            fetch(source) { list in
                lock.lock()
                bySource[source.id] = list
                for s in list {
                    let key = s.id.isEmpty ? s.url : s.id
                    if seen.insert(key).inserted { merged.append(s) }
                }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            if merged.isEmpty {
                self.stations = StationData.all
                self.stationsBySource = [RadioSource.builtinID: StationData.all]
                self.loadMessage = "所有电台源加载失败，已回退内置 \(StationData.all.count) 台"
            } else {
                self.stations = merged
                self.stationsBySource = bySource
                self.loadMessage = "已加载 \(merged.count) 个电台"
            }
            self.refreshVisibleStations()
            self.lastUpdated = Date()
        }
    }

    // MARK: 源切换

    var sourceOptions: [RadioSourceOption] {
        var options = [RadioSourceOption(id: SourceSelection.all, title: "全部")]
        let builtin = sources.first { $0.isBuiltin } ?? .builtin
        options.append(RadioSourceOption(id: SourceSelection.builtin, title: builtin.name))
        for source in sources where !source.isBuiltin {
            options.append(RadioSourceOption(id: source.id, title: source.name))
        }
        return options
    }

    func selectedSourceTitle() -> String {
        sourceOptions.first { $0.id == selectedSourceID }?.title ?? "全部"
    }

    func selectSource(_ id: String) {
        let valid = sourceOptions.contains { $0.id == id }
        selectedSourceID = valid ? id : SourceSelection.all
        defaults.set(selectedSourceID, forKey: selectedSourceKey)
        refreshVisibleStations()
    }

    private func refreshVisibleStations() {
        switch selectedSourceID {
        case SourceSelection.all:
            visibleStations = stations
        case SourceSelection.builtin:
            let list = stationsBySource[RadioSource.builtinID] ?? []
            if list.isEmpty {
                visibleStations = stationsBySource.isEmpty ? StationData.all : []
            } else {
                visibleStations = list
            }
        default:
            visibleStations = stationsBySource[selectedSourceID] ?? []
        }
    }

    private func fetch(_ source: RadioSource, completion: @escaping ([Station]) -> Void) {
        let text = source.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.lowercased().hasPrefix("http") == true else {
            completion([]); return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data else { completion([]); return }
            completion(StationParser.parse(data, source: source))
        }.resume()
    }

    func station(id: String) -> Station? { stations.first { $0.id == id } }

    var regions: [String] {
        var seen = Set<String>(); var out = [String]()
        for s in visibleStations where seen.insert(s.region).inserted { out.append(s.region) }
        return out
    }
}

// MARK: - 配置建议文本

enum SourceConfigHelp {
    static let text = """
    电台源配置结构说明

    【单个源的字段】
    • name       源名称，仅用于显示
    • url        接口地址，支持 http / https
    • listPath   电台数组在 JSON 中的路径，可留空自动识别
                 例如 "radio" 或 "data.list"
    • fields     字段名映射：左边是 App 内字段，右边是接口里的字段名

    【推荐 JSON（内置官方接口就是这种格式）】
    {
      "radio": [
        {
          "radio_id": "1",
          "name": "CNR中国之声",
          "desc": "FM106.1",
          "region": "中央",
          "url": "http://.../index.m3u8",
          "img_url": ""
        }
      ]
    }

    对应配置：
    listPath = radio
    fields = id:radio_id / name:name / url:url
             desc:desc / region:region / image:img_url

    【也支持】
    • 顶层直接是电台对象数组
    • 常见字段名自动识别（title、stream、streamUrl、area、logo 等）
    • M3U 文本（#EXTINF 行 + 流地址行）
    • 多个源自动合并去重，位置靠前的源优先
    """
}
