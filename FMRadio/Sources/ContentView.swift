import SwiftUI
import WidgetKit

// MARK: - iOS 14 compatible view helpers

extension View {
    @ViewBuilder
    func appForeground(_ color: Color) -> some View {
        if #available(iOS 15.0, *) {
            self.foregroundStyle(color)
        } else {
            self.foregroundColor(color)
        }
    }

    @ViewBuilder
    func appPrimary() -> some View {
        if #available(iOS 15.0, *) {
            self.foregroundStyle(.primary)
        } else {
            self.foregroundColor(.primary)
        }
    }

    @ViewBuilder
    func appSecondary() -> some View {
        if #available(iOS 15.0, *) {
            self.foregroundStyle(.secondary)
        } else {
            self.foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    func appTertiary() -> some View {
        if #available(iOS 15.0, *) {
            self.foregroundStyle(.tertiary)
        } else {
            self.foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    func appTint(_ color: Color) -> some View {
        if #available(iOS 15.0, *) {
            self.tint(color)
        } else {
            self.accentColor(color)
        }
    }

    @ViewBuilder
    func appTextInputStyle() -> some View {
        if #available(iOS 15.0, *) {
            self.textInputAutocapitalization(.never).autocorrectionDisabled()
        } else {
            self
        }
    }

    @ViewBuilder
    func appTextSelection() -> some View {
        if #available(iOS 15.0, *) {
            self.textSelection(.enabled)
        } else {
            self
        }
    }

    @ViewBuilder
    func appSheetDetents() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.medium, .large])
        } else {
            self
        }
    }

    @ViewBuilder
    func appSectionHeader<S: StringProtocol>(_ title: S) -> some View {
        if #available(iOS 15.0, *) {
            Section {
                self
            } header: {
                HStack {
                    Text(title)
                    Spacer(minLength: 0)
                }
                .textCase(nil)
                .font(.footnote.weight(.semibold))
                .appSecondary()
            }
        } else {
            Section(header: Text(title)) {
                self
            }
        }
    }

    @ViewBuilder
    func appSectionHeaderView<Header: View>(@ViewBuilder header: () -> Header) -> some View {
        if #available(iOS 15.0, *) {
            Section {
                self
            } header: {
                header()
            }
        } else {
            Section(header: header()) {
                self
            }
        }
    }

    @ViewBuilder
    func appAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        if #available(iOS 15.0, *) {
            self.animation(animation, value: value)
        } else {
            self
        }
    }

    @ViewBuilder
    func appGlassCard(cornerRadius: CGFloat = 16) -> some View {
        if #available(iOS 26.0, *) {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.white.opacity(0.42), lineWidth: 0.8))
                .shadow(color: Color.black.opacity(0.18), radius: 18, y: 6)
        } else if #available(iOS 15.0, *) {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.12), radius: 12, y: 4)
        } else {
            self
                .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color(.systemBackground).opacity(0.92)))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.12), radius: 12, y: 4)
        }
    }
}

@ViewBuilder
func appEmpty(_ title: String, _ systemImage: String, _ description: String) -> some View {
    VStack(spacing: 10) {
        Image(systemName: systemImage).font(.system(size: 42)).appSecondary()
        Text(title).font(.headline)
        Text(description).font(.caption).appSecondary().multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
}

func appDateText(_ date: Date) -> String {
    if #available(iOS 15.0, *) {
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .short
    return f.string(from: date)
}


@ViewBuilder
func appGradient(_ color: Color, opacity: Double) -> LinearGradient {
    LinearGradient(gradient: Gradient(colors: [color.opacity(opacity), color.opacity(opacity * 0.55)]), startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - Remote artwork (iOS 14 compatible, no async/await / Task / @MainActor)
private final class AppImageCache {
    static let shared = AppImageCache()
    private let cache = NSCache<NSString, UIImage>()
    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    func store(_ image: UIImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
}

struct RemoteImageView: View {
    let urlString: String?
    @EnvironmentObject private var store: Store
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    Image(systemName: "waveform")
                        .font(.title3)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .appForeground(Theme.tint(store.themeColor))
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: urlString ?? "") { _ in load() }
    }

    private func load() {
        guard let string = urlString, !string.isEmpty, let url = normalizedURL(string) else {
            image = nil
            return
        }
        if let cached = AppImageCache.shared.image(for: string) {
            image = cached
            return
        }
        image = nil
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let downloaded = UIImage(data: data) else { return }
            AppImageCache.shared.store(downloaded, for: string)
            DispatchQueue.main.async {
                if self.urlString == string { self.image = downloaded }
            }
        }.resume()
    }

    private func normalizedURL(_ value: String) -> URL? {
        if let url = URL(string: value), url.scheme != nil { return url }
        if let url = URL(string: "https://" + value), url.host != nil { return url }
        return URL(string: "http://" + value)
    }
}

struct StationArtwork: View {
    let station: Station
    var cornerRadius: CGFloat = 12
    @EnvironmentObject private var store: Store

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(appGradient(Theme.tint(store.themeColor), opacity: 0.18))
            if let value = station.img_url, !value.isEmpty {
                RemoteImageView(urlString: value)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                Image(systemName: "waveform")
                    .font(.title3)
                    .appForeground(Theme.tint(store.themeColor))
            }
        }
    }
}

// MARK: - Theme (iOS 26 style)
enum Theme {
    static func tint(_ name: String) -> Color {
        switch name {
        case "orange": return .orange
        case "green": return .green
        case "pink": return .pink
        case "purple": return .purple
        case "red": return .red
        default: return .blue
        }
    }
}

// MARK: - Root
struct ContentView: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var store: Store
    @EnvironmentObject var catalog: CatalogStore
    @State private var tab: Tab = .play
    @State private var showFullPlayer = false

    enum Tab: String, CaseIterable {
        case play = "播放", region = "地区", favorite = "收藏", search = "搜索", setting = "设置"
        var symbol: String {
            switch self {
            case .play: return "radio"
            case .region: return "globe"
            case .favorite: return "heart"
            case .search: return "magnifyingglass"
            case .setting: return "gearshape"
            }
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            PlayView().tabItem { Label(Tab.play.rawValue, systemImage: Tab.play.symbol) }.tag(Tab.play)
            RegionView().tabItem { Label(Tab.region.rawValue, systemImage: Tab.region.symbol) }.tag(Tab.region)
            FavoriteView().tabItem { Label(Tab.favorite.rawValue, systemImage: Tab.favorite.symbol) }.tag(Tab.favorite)
            SearchView().tabItem { Label(Tab.search.rawValue, systemImage: Tab.search.symbol) }.tag(Tab.search)
            SettingView().tabItem { Label(Tab.setting.rawValue, systemImage: Tab.setting.symbol) }.tag(Tab.setting)
        }
        .appTint(Theme.tint(store.themeColor))
        .background(WidgetBridgeView())
        .onAppear { player.playlist = catalog.visibleStations }
        .onReceive(catalog.$visibleStations) { stations in player.playlist = stations }
        .overlay(
            Group {
                if tab == .play {
                    MiniPlayer { showFullPlayer = true }
                        .padding(.bottom, 62)
                }
            },
            alignment: .bottom
        )
        .fullScreenCover(isPresented: $showFullPlayer) {
            FullPlayerView()
                .environmentObject(player)
                .environmentObject(store)
                .environmentObject(catalog)
        }
        .alert(isPresented: Binding(
            get: { player.errorMessage != nil },
            set: { if !$0 { player.errorMessage = nil } }
        )) {
            Alert(title: Text("播放错误"), message: Text(player.errorMessage ?? ""), dismissButton: .default(Text("好的")) { player.errorMessage = nil })
        }
        .onOpenURL { url in handleWidgetURL(url) }
    }

    private func handleWidgetURL(_ url: URL) {
        guard url.scheme?.lowercased() == "fmradio" else { return }
        let host = (url.host ?? "").lowercased()
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "id" })?.value
        DispatchQueue.main.async {
            self.player.playlist = self.catalog.visibleStations
            switch host {
            case "toggle":
                self.player.toggle()
            case "next":
                self.player.next()
            case "previous":
                self.player.previous()
            case "play":
                guard let id = id,
                      let station = self.catalog.station(id: id) ?? self.catalog.visibleStations.first(where: { $0.id == id }) else { return }
                self.player.play(station)
                self.store.touch(station)
            default:
                break
            }
        }
    }
}

// MARK: - Station list row
struct StationRow: View {
    let station: Station
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if #available(iOS 15.0, *) {
                rowContent
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { store.toggleFavorite(station) } label: {
                            Label(store.isFavorite(station) ? "取消收藏" : "收藏",
                                  systemImage: store.isFavorite(station) ? "heart.slash.fill" : "heart.fill")
                        }
                        .tint(store.isFavorite(station) ? .gray : .pink)
                    }
            } else {
                rowContent
                    .modifier(FavoriteSwipeFallback(station: station))
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 14) {
            StationArtwork(station: station, cornerRadius: 12)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(station.name).font(.headline)
                Text("\(station.desc) · \(station.region)").font(.caption).appSecondary().lineLimit(1)
            }
            Spacer()
            if store.isFavorite(station) {
                Image(systemName: "heart.fill").font(.caption).appForeground(.pink)
            }
            if player.current?.id == station.id && player.isPlaying {
                PlayIndicator().frame(width: 18, height: 16)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { player.play(station); store.touch(station) }
    }
}

/// iOS 14 没有 swipeActions，用横向拖拽模拟左滑收藏/取消收藏。
struct FavoriteSwipeFallback: ViewModifier {
    let station: Station
    @EnvironmentObject var store: Store
    @State private var dragX: CGFloat = 0
    @State private var hint: String?

    func body(content: Content) -> some View {
        ZStack {
            HStack {
                Spacer(minLength: 0)
                Button { toggleFavorite() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: store.isFavorite(station) ? "heart.slash.fill" : "heart.fill")
                            .font(.system(size: 18, weight: .semibold))
                        Text(store.isFavorite(station) ? "取消" : "收藏")
                            .font(.caption2.weight(.semibold))
                    }
                    .frame(width: 76)
                    .appForeground(.white)
                }
                .buttonStyle(.plain)
            }
            .background(store.isFavorite(station) ? Color.gray : Color.pink)
            .cornerRadius(12)
            .padding(.vertical, 6)
            .opacity(dragX < -8 ? 1 : 0)

            content
                .background(Color(.systemBackground))
                .offset(x: dragX)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            let t = value.translation
                            guard abs(t.width) > abs(t.height) else { return }
                            dragX = max(-84, min(0, t.width))
                        }
                        .onEnded { _ in
                            if dragX <= -42 { toggleFavorite() }
                            withAnimation { dragX = 0 }
                        }
                )
        }
        .overlay(
            Group {
                if let hint = hint {
                    Text(hint)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.72)))
                        .appForeground(.white)
                }
            },
            alignment: .top
        )
        .appAnimation(.easeOut(duration: 0.18), value: dragX)
        .appAnimation(.easeOut(duration: 0.2), value: hint)
    }

    private func toggleFavorite() {
        let wasFavorite = store.isFavorite(station)
        store.toggleFavorite(station)
        hint = wasFavorite ? "已取消收藏" : "已收藏"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { hint = nil }
    }
}

struct PlayIndicator: View {
    @EnvironmentObject var store: Store
    @State private var anim = false
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.tint(store.themeColor))
                    .frame(width: 3, height: anim ? 14 : 5)
                    .animation(.easeInOut(duration: 0.4).repeatForever().delay(Double(i) * 0.15))
            }
        }
        .onAppear { anim = true }
    }
}

// MARK: - 源切换菜单
struct SourceSwitchMenu: View {
    @EnvironmentObject var catalog: CatalogStore

    var body: some View {
        Menu {
            ForEach(catalog.sourceOptions) { option in
                Button {
                    catalog.selectSource(option.id)
                } label: {
                    HStack {
                        Text(option.title)
                        Spacer(minLength: 12)
                        if catalog.selectedSourceID == option.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                Text(catalog.selectedSourceTitle())
                    .font(.caption)
                    .lineLimit(1)
            }
            .appPrimary()
        }
    }
}

// MARK: - Play tab
struct PlayView: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var store: Store
    @EnvironmentObject var catalog: CatalogStore

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(catalog.visibleStations) { s in StationRow(station: s) }
                }
                .appSectionHeader("全部电台")
            }
            .navigationTitle("收音机")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    SourceSwitchMenu()
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

// MARK: - Region tab
struct RegionView: View {
    @EnvironmentObject var catalog: CatalogStore
    @State private var expanded: String? = "中央"
    var body: some View {
        NavigationView {
            List {
                if catalog.visibleStations.isEmpty {
                    appEmpty("暂无电台", "square.stack.3d.up", "当前源没有可用电台，可在右上角切换源")
                }
                ForEach(catalog.regions, id: \.self) { region in
                    Section {
                        if expanded == region {
                            ForEach(catalog.visibleStations.filter { $0.region == region }) { s in
                                StationRow(station: s)
                            }
                        }
                    }
                    .appSectionHeaderView {
                        Button {
                            withAnimation { expanded = expanded == region ? nil : region }
                        } label: {
                            HStack {
                                Label(region, systemImage: "globe")
                                Spacer()
                                Image(systemName: expanded == region ? "chevron.up" : "chevron.down")
                            }
                        }
                        .buttonStyle(.plain)
                        .appPrimary()
                    }
                }
            }
            .navigationTitle("地区")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    SourceSwitchMenu()
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

// MARK: - Favorites tab
struct FavoriteView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var catalog: CatalogStore
    var body: some View {
        NavigationView {
            List {
                if store.favorites.isEmpty {
                    appEmpty("暂无收藏", "heart", "在电台列表中左滑条目即可收藏")
                } else {
                    ForEach(catalog.stations.filter { store.favorites.contains($0.id) }) { s in
                        StationRow(station: s)
                    }
                    .onDelete { idx in
                        let items = catalog.stations.filter { store.favorites.contains($0.id) }
                        for i in idx where items.indices.contains(i) { store.toggleFavorite(items[i]) }
                    }
                }
                if !store.recents.isEmpty {
                    Section {
                        ForEach(store.recents.compactMap { id in catalog.stations.first { $0.id == id } }) { s in
                            StationRow(station: s)
                        }
                    }
                    .appSectionHeaderView {
                        HStack {
                            Text("最近播放")
                            Spacer(minLength: 12)
                            Button {
                                store.clearRecents()
                            } label: {
                                Text("清除")
                                    .font(.footnote.weight(.medium))
                                    .appSecondary()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("收藏")
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

// MARK: - Search tab

/// 用 UIViewController 托管输入框：等导航 push 转场完成后再聚焦，
/// 避免键盘跟随 push 动画从左侧滑入。
private struct AutoFocusTextField: UIViewControllerRepresentable {
    @Binding var text: String
    let onReturn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AutoFocusTextField
        init(_ parent: AutoFocusTextField) { self.parent = parent }
        @objc func editingChanged(_ tf: UITextField) { parent.text = tf.text ?? "" }
        func textFieldShouldReturn(_ tf: UITextField) -> Bool {
            tf.resignFirstResponder()
            parent.onReturn()
            return true
        }
    }

    func makeUIViewController(context: Context) -> AutoFocusFieldController {
        let vc = AutoFocusFieldController()
        let tf = vc.textField
        tf.placeholder = "电台名称 / 地区"
        tf.borderStyle = .none
        tf.font = .systemFont(ofSize: 16)
        tf.returnKeyType = .search
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.clearButtonMode = .whileEditing
        tf.text = text
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        tf.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: AutoFocusFieldController, context: Context) {
        if vc.textField.text != text { vc.textField.text = text }
    }
}

private final class AutoFocusFieldController: UIViewController {
    let textField = UITextField()

    override func loadView() {
        view = UIView()
        textField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textField.topAnchor.constraint(equalTo: view.topAnchor),
            textField.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textField.heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let coordinator = transitionCoordinator, coordinator.isAnimated {
            coordinator.animate(alongsideTransition: nil) { _ in
                self.focusField()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self.focusField()
            }
        }
    }

    private func focusField() {
        guard !textField.isFirstResponder else { return }
        textField.becomeFirstResponder()
    }
}

struct SearchView: View {
    @EnvironmentObject var catalog: CatalogStore
    @State private var query = ""

    private var results: [Station] {
        guard !query.isEmpty else { return [] }
        return catalog.stations.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.desc.localizedCaseInsensitiveContains(query) ||
            $0.region.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationView {
            List {
                if query.isEmpty {
                    appEmpty("搜索电台", "magnifyingglass", "输入名称、描述或地区")
                } else if results.isEmpty {
                    appEmpty("没有结果", "magnifyingglass", "没有找到“\(query)”")
                } else {
                    ForEach(results) { s in StationRow(station: s) }
                }
            }
            .navigationTitle("搜索")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: SearchInputView(query: $query)) {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct SearchInputView: View {
    @Binding var query: String
    @Environment(\.presentationMode) private var presentationMode
    var body: some View {
        Form {
            Section {
                AutoFocusTextField(text: $query) {
                    presentationMode.wrappedValue.dismiss()
                }
            }
            .appSectionHeader("关键词")
            Section {
                Button("完成") { presentationMode.wrappedValue.dismiss() }
            }
        }
        .navigationTitle("搜索")
    }
}

// MARK: - Setting tab
struct SettingView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var catalog: CatalogStore
    @AppStorage("APP_THEME_COLOR") private var theme = "blue"
    let colors: [(String, String)] = [("blue","蓝色"),("orange","橙色"),("green","绿色"),("pink","粉色"),("purple","紫色"),("red","红色")]

    @State private var editing: RadioSource?
    @State private var showSuggestions = false
    @State private var showResetConfirm = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 12) {
                        Text("外观").appPrimary()
                        Spacer(minLength: 8)
                        HStack(spacing: 10) {
                            ForEach(colors, id: \.0) { key, _ in
                                Button {
                                    theme = key; store.colorChanged.toggle()
                                } label: {
                                    ZStack {
                                        Circle().fill(Theme.tint(key)).frame(width: 22, height: 22)
                                        if theme == key {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11, weight: .bold))
                                                .appForeground(.white)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    ForEach(catalog.sources) { source in
                        HStack(spacing: 12) {
                            Image(systemName: source.isBuiltin ? "building.columns" : "cloud")
                                .appForeground(Theme.tint(store.themeColor))
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name).font(.body.weight(.medium))
                                Text(source.urlString)
                                    .font(.caption).appSecondary()
                                    .lineLimit(1)
                            }
                            Spacer()
                            if source.isBuiltin {
                                Button {
                                    catalog.setBuiltinUnlocked(!catalog.isBuiltinUnlocked)
                                } label: {
                                    Image(systemName: catalog.isBuiltinUnlocked ? "lock.open.fill" : "lock.fill")
                                        .font(.caption)
                                        .appForeground(catalog.isBuiltinUnlocked ? Theme.tint(store.themeColor) : .secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !source.isBuiltin || catalog.isBuiltinUnlocked { editing = source }
                        }
                    }
                    .onMove { indices, to in catalog.moveSource(from: indices, to: to) }

                    Button { editing = RadioSource(name: "", urlString: "") } label: {
                        Label("添加电台源", systemImage: "plus.circle.fill")
                    }

                    Button { catalog.reload() } label: {
                        Label("立即更新目录", systemImage: "arrow.triangle.2.circlepath")
                    }

                    if let message = catalog.loadMessage {
                        Text(message).font(.caption).appSecondary()
                    }
                    if let date = catalog.lastUpdated {
                        Text("上次更新: " + appDateText(date))
                            .font(.caption2).appTertiary()
                    }
                }
                .appSectionHeader("电台源")
                Section {
                    Text("默认是内置源，始终排第一且不可删除。点击锁头可解锁编辑。")
                        .font(.caption).appSecondary()
                }

                Section {
                    HStack {
                        Label("音量", systemImage: "speaker.wave.2")
                        Slider(value: Binding(get: { player.volume }, set: { player.volume = $0 }), in: 0...1)
                    }
                    Button { player.stop() } label: { Label("停止播放", systemImage: "stop.circle") }
                                }
                .appSectionHeader("播放")

                Section {
                    AppInfoRow(title: "版本", value: "1.0.0 (iOS14 兼容)")
                    AppInfoRow(title: "当前电台数", value: "\(catalog.stations.count)")
                    AppInfoRow(title: "电台来源", value: "多源合并 · 内置兜底")
                    Button { showResetConfirm = true } label: {
                        Label("恢复默认源配置", systemImage: "arrow.counterclockwise")
                    }
                    Button {
                        if let url = URL(string: "https://github.com/braless/FmRadio") {
                            UIApplication.shared.open(url, options: [:], completionHandler: nil)
                        }
                    } label: {
                        HStack {
                            Text("反馈")
                            Spacer(minLength: 8)
                            ZStack {
                                Circle().fill(Color(.label)).frame(width: 20, height: 20)
                                Text("G").font(.system(size: 12, weight: .bold)).foregroundColor(Color(.systemBackground))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
                .appSectionHeader("关于")
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSuggestions = true } label: {
                        Label("配置建议", systemImage: "info.circle")
                    }
                }
            }
            .sheet(isPresented: $showSuggestions) {
                NavigationView {
                    ScrollView {
                        Text(SourceConfigHelp.text)
                            .font(.system(.body, design: .monospaced))
                            .appTextSelection()
                            .padding()
                    }
                    .navigationTitle("配置建议")
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("完成") { showSuggestions = false }
                        }
                    }
                }
                .navigationViewStyle(StackNavigationViewStyle())
                .appSheetDetents()
            }
            .sheet(item: $editing) { source in
                SourceEditView(source: source) { updated in
                    if catalog.sources.contains(where: { $0.id == updated.id }) {
                        catalog.updateSource(updated)
                    } else {
                        catalog.addSource(updated)
                    }
                }
            }
            .alert(isPresented: $showResetConfirm) {
                Alert(title: Text("恢复默认？"), message: Text("将删除所有自定义电台源，只保留内置官方接口。"),
                      primaryButton: .destructive(Text("恢复默认")) { catalog.resetSources() },
                      secondaryButton: .cancel())
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct AppInfoRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).appSecondary()
        }
    }
}

// MARK: - 源编辑
struct SourceEditView: View {
    @Environment(\.presentationMode) private var presentationMode
    @EnvironmentObject var catalog: CatalogStore
    let original: RadioSource
    let onSave: (RadioSource) -> Void

    @State private var name: String
    @State private var urlString: String
    @State private var listPath: String
    @State private var fieldMap: RadioSource.FieldMap
    @State private var enabled: Bool

    init(source: RadioSource, onSave: @escaping (RadioSource) -> Void) {
        self.original = source
        self.onSave = onSave
        _name = State(initialValue: source.name)
        _urlString = State(initialValue: source.urlString)
        _listPath = State(initialValue: source.listPath)
        _fieldMap = State(initialValue: source.fields)
        _enabled = State(initialValue: source.enabled)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !urlString.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("源名称", text: $name).appTextInputStyle()
                    TextField("接口地址 http/https", text: $urlString).appTextInputStyle()
                }
                .appSectionHeader("基础")
                Section {
                    TextField("列表路径，如 radio 或 data.list", text: $listPath).appTextInputStyle()
                                }
                .appSectionHeader("JSON 解析（可留空自动识别）")
                Section {
                    FieldRow(label: "ID", text: Binding(get: { fieldMap.id }, set: { fieldMap.id = $0 }))
                    FieldRow(label: "名称", text: Binding(get: { fieldMap.name }, set: { fieldMap.name = $0 }))
                    FieldRow(label: "地址", text: Binding(get: { fieldMap.url }, set: { fieldMap.url = $0 }))
                    FieldRow(label: "描述", text: Binding(get: { fieldMap.desc }, set: { fieldMap.desc = $0 }))
                    FieldRow(label: "地区", text: Binding(get: { fieldMap.region }, set: { fieldMap.region = $0 }))
                    FieldRow(label: "图片", text: Binding(get: { fieldMap.image }, set: { fieldMap.image = $0 }))
                                }
                .appSectionHeader("字段映射（App 字段 → 接口字段）")
                Section {
                    Button("恢复默认字段映射") { fieldMap = .default }
                }
                if !original.isBuiltin {
                    Section {
                        Button("删除源") {
                            catalog.removeSource(original)
                            presentationMode.wrappedValue.dismiss()
                        }
                        .appForeground(.red)
                    }
                }
                Section {
                    Text(SourceConfigHelp.text)
                        .font(.caption)
                        .appSecondary()
                        .appTextSelection()
                }
                .appSectionHeader("配置提示")
            }
            .navigationTitle(original.name.isEmpty ? "添加电台源" : "编辑电台源")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        let updated = RadioSource(
                            id: original.id, name: name.trimmingCharacters(in: .whitespaces),
                            urlString: urlString.trimmingCharacters(in: .whitespaces),
                            enabled: enabled, listPath: listPath.trimmingCharacters(in: .whitespaces),
                            fields: fieldMap
                        )
                        onSave(updated)
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct FieldRow: View {
    let label: String
    @Binding var text: String
    var body: some View {
        HStack {
            Text(label).frame(width: 52, alignment: .leading)
            TextField("接口字段名", text: $text).appTextInputStyle()
        }
    }
}

// MARK: - Mini player
struct MiniPlayer: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var store: Store
    let onOpen: () -> Void

    var body: some View {
        Group {
            if let s = player.current {
                HStack(spacing: 8) {
                    Button { onOpen() } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                StationArtwork(station: s, cornerRadius: 10)
                                if player.isBuffering { ProgressView() }
                            }
                            .frame(width: 40, height: 40)
                            VStack(alignment: .leading) {
                                Text(s.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(player.isPlaying ? "正在播放 · \(s.region)" : (player.isBuffering ? "加载中…" : "已暂停"))
                                    .font(.caption).appSecondary()
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.up")
                                .font(.caption.weight(.semibold))
                                .appSecondary()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 10) {
                        Button { player.previous() } label: {
                            Image(systemName: "backward.fill")
                                .font(.subheadline)
                                .appForeground(Theme.tint(store.themeColor).opacity(0.75))
                        }
                        Button { player.toggle() } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title2)
                                .appForeground(Theme.tint(store.themeColor))
                        }
                        Button { player.next() } label: {
                            Image(systemName: "forward.fill")
                                .font(.subheadline)
                                .appForeground(Theme.tint(store.themeColor).opacity(0.75))
                        }
                    }
                    .appTint(Theme.tint(store.themeColor))
                    .padding(.trailing, 4)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .appGlassCard(cornerRadius: 24)
                .frame(maxWidth: 520)
                .padding(.horizontal, 26)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .appAnimation(.spring(response: 0.35), value: player.current?.id)
    }
}

// MARK: - Full-screen player (Apple Music inspired)
struct FullPlayerView: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var store: Store
    @EnvironmentObject var catalog: CatalogStore
    @Environment(\.presentationMode) private var presentationMode

    private var tint: Color { Theme.tint(store.themeColor) }
    private var queueCount: Int { max(player.playlist.count, 1) }
    private var currentIndex: Int {
        guard let id = player.current?.id else { return 0 }
        return player.playlist.firstIndex { $0.id == id } ?? 0
    }

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [tint.opacity(0.52), Color(.systemBackground).opacity(0.96)]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            Circle()
                .fill(tint.opacity(0.22))
                .frame(width: 280, height: 280)
                .blur(radius: 60)
                .offset(x: -120, y: -220)

            Circle()
                .fill(tint.opacity(0.16))
                .frame(width: 320, height: 320)
                .blur(radius: 70)
                .offset(x: 150, y: 180)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 8)
                artwork
                    .padding(.horizontal, 32)
                Spacer(minLength: 14)
                stationInfo
                Spacer(minLength: 18)
                volumeRow
                Spacer(minLength: 18)
                transportRow
                Spacer(minLength: 22)
                queueInfo
            }
            .padding(.bottom, 18)
        }
        .appTint(tint)
        .gesture(
            DragGesture(minimumDistance: 80)
                .onEnded { value in
                    if value.translation.height > 120 && abs(value.translation.height) > abs(value.translation.width) {
                        dismiss()
                    }
                }
        )
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .appForeground(.primary)
            }
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Text("正在播放")
                    .font(.caption.weight(.semibold))
                    .appPrimary()
                Text(catalog.selectedSourceTitle())
                    .font(.caption2)
                    .appSecondary()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let s = player.current {
                Button { store.toggleFavorite(s) } label: {
                    Image(systemName: store.isFavorite(s) ? "heart.fill" : "heart")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .appForeground(store.isFavorite(s) ? .pink : .primary)
                }
            } else {
                Color.clear.frame(width: 34, height: 34)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    private var artwork: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, 340)
            ZStack {
                RoundedRectangle(cornerRadius: 30)
                    .fill(appGradient(tint, opacity: 0.34))
                RoundedRectangle(cornerRadius: 30)
                    .stroke(Color.white.opacity(0.42), lineWidth: 1)
                if let s = player.current, let value = s.img_url, !value.isEmpty {
                    RemoteImageView(urlString: value)
                        .clipShape(RoundedRectangle(cornerRadius: 30))
                } else {
                    Image("radio")
                        .resizable()
                        .scaledToFit()
                        .padding(side * 0.22)
                        .opacity(0.95)
                }
                if player.isBuffering {
                    ProgressView()
                        .scaleEffect(1.4)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .shadow(color: tint.opacity(0.35), radius: 32, y: 16)
        }
        .frame(height: min(UIScreen.main.bounds.width - 64, 340))
    }

    private var stationInfo: some View {
        VStack(spacing: 8) {
            if let s = player.current {
                Text(s.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("\(s.desc) · \(s.region)")
                    .font(.subheadline)
                    .appSecondary()
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text("LIVE")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(tint.opacity(0.22)))
                        .appForeground(tint)
                    PlayIndicator()
                        .frame(width: 18, height: 16)
                    Text(player.isPlaying ? "正在播放" : (player.isBuffering ? "加载中…" : "已暂停"))
                        .font(.caption)
                        .appSecondary()
                }
            } else {
                Text("未选择电台")
                    .font(.title3.weight(.semibold))
                    .appSecondary()
            }
        }
        .padding(.horizontal, 32)
    }

    private var volumeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.caption)
                .appSecondary()
            Slider(value: Binding(get: { player.volume }, set: { player.volume = $0 }), in: 0...1)
                .appTint(tint)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
                .appSecondary()
        }
        .padding(.horizontal, 36)
    }

    private var transportRow: some View {
        HStack(spacing: 44) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .appForeground(.primary)
                    .frame(width: 52, height: 52)
            }
            Button { player.toggle() } label: {
                ZStack {
                    Circle().fill(tint).frame(width: 78, height: 78)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .bold))
                        .appForeground(.white)
                        .offset(x: player.isPlaying ? 0 : 2)
                }
            }
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .appForeground(.primary)
                    .frame(width: 52, height: 52)
            }
        }
    }

    private var queueInfo: some View {
        Text("\(currentIndex + 1) / \(queueCount) · \(catalog.selectedSourceTitle())")
            .font(.caption2)
            .appTertiary()
    }

    private func dismiss() {
        presentationMode.wrappedValue.dismiss()
    }
}

// MARK: - App entry
@main
struct FMRadioApp: App {
    @StateObject private var player = AudioPlayer()
    @StateObject private var store = Store()
    @StateObject private var catalog = CatalogStore()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(player).environmentObject(store).environmentObject(catalog) }
    }
}
