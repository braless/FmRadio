import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Shared model helpers

private func widgetTint(_ name: String) -> Color {
    switch name {
    case "orange": return .orange
    case "green": return .green
    case "pink": return .pink
    case "purple": return .purple
    case "red": return .red
    default: return .blue
    }
}

private func widgetSubtitle(_ station: WidgetStation) -> String {
    station.desc.isEmpty ? station.region : "\(station.desc) · \(station.region)"
}

private func widgetArtwork(_ station: WidgetStation?, tint: Color) -> some View {
    ZStack {
        if let data = station?.artworkData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(
                gradient: Gradient(colors: [tint.opacity(0.85), tint.opacity(0.35)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "radio")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
        }
    }
}

/// 状态标签：iOS 27 上即使系统弱化渲染，也用高对比文字 + 图标明确显示播放状态。
@ViewBuilder
private func PlaybackStatusBadge(isPlaying: Bool, tint: Color) -> some View {
    HStack(spacing: 4) {
        Image(systemName: isPlaying ? "waveform" : "pause.fill")
            .font(.caption2.weight(.bold))
        Text(isPlaying ? "正在播放" : "已暂停")
            .font(.caption2.weight(.semibold))
    }
    .foregroundColor(isPlaying ? .red : .secondary)
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .background(isPlaying ? Color.red.opacity(0.12) : Color(.secondarySystemBackground))
    .clipShape(Capsule())
}

// MARK: - Timeline

struct WidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct FMRadioWidgetProvider: TimelineProvider {
    private func currentSnapshot() -> WidgetSnapshot {
        WidgetSnapshot.load() ?? .placeholder
    }

    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: Date(), snapshot: currentSnapshot())
    }
    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(WidgetEntry(date: Date(), snapshot: currentSnapshot()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let entry = WidgetEntry(date: Date(), snapshot: currentSnapshot())
        // 播放状态的快照由主 App 主动 reload；这里额外每 15 分钟兜底刷新一次。
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Interactive controls (iOS 17+)

@available(iOS 17.0, *)
@ViewBuilder
private func widgetControl(icon: String, label: String, tint: Color,
                           intent: (any AppIntent)?, fallbackAction: String) -> some View {
    if let intent {
        Button(intent: intent) {
            controlContent(icon: icon, label: label, tint: tint)
        }
        .buttonStyle(.plain)
    } else {
        Link(destination: WidgetAction.url(fallbackAction)) {
            controlContent(icon: icon, label: label, tint: tint)
        }
        .buttonStyle(.plain)
    }
}

@ViewBuilder
private func widgetPlayControl(isPlaying: Bool, tint: Color, stationID: String?) -> some View {
    let icon = isPlaying ? "pause.circle.fill" : "play.circle.fill"
    if #available(iOS 17.0, *) {
        Button(intent: RadioToggleIntent()) {
            controlContent(icon: icon, label: isPlaying ? "暂停" : "播放", tint: tint)
        }
        .buttonStyle(.plain)
    } else {
        Link(destination: WidgetAction.url("toggle", id: stationID)) {
            controlContent(icon: icon, label: isPlaying ? "暂停" : "播放", tint: tint)
        }
        .buttonStyle(.plain)
    }
}

@ViewBuilder
private func widgetRecentControl(station: WidgetStation, tint: Color) -> some View {
    if #available(iOS 17.0, *) {
        Button(intent: RadioPlayIntent(stationID: station.id)) {
            recentContent(station: station, tint: tint)
        }
        .buttonStyle(.plain)
    } else {
        Link(destination: WidgetAction.url("play", id: station.id)) {
            recentContent(station: station, tint: tint)
        }
        .buttonStyle(.plain)
    }
}

private func controlContent(icon: String, label: String, tint: Color) -> some View {
    VStack(spacing: 2) {
        Image(systemName: icon)
            .font(.title3.weight(.semibold))
            .foregroundColor(tint)
        Text(label)
            .font(.caption2)
            .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 40)
    .contentShape(Rectangle())
}

private func recentContent(station: WidgetStation, tint: Color) -> some View {
    HStack(spacing: 8) {
        Image(systemName: "waveform")
            .font(.caption)
            .foregroundColor(tint)
        Text(station.name)
            .font(.caption.weight(.medium))
            .lineLimit(1)
        Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 10)
    .background(Color(.secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .contentShape(Rectangle())
}

// MARK: - Views

struct SmallWidgetView: View {
    let entry: WidgetEntry
    var body: some View {
        let snap = entry.snapshot
        let tint = widgetTint(snap.theme)
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [tint.opacity(0.28), Color(.systemBackground)]),
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "radio").font(.caption.weight(.semibold)).foregroundColor(tint)
                    Text("收音机").font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    PlaybackStatusBadge(isPlaying: snap.isPlaying, tint: tint)
                }
                Spacer(minLength: 0)
                if let current = snap.current {
                    Text(current.name).font(.headline.weight(.bold)).lineLimit(2)
                    Text(widgetSubtitle(current)).font(.caption).foregroundColor(.secondary).lineLimit(1)
                } else {
                    Text("未选择电台").font(.headline.weight(.semibold)).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                if #available(iOS 17.0, *) {
                    HStack {
                        widgetControl(icon: "backward.fill", label: "上一个", tint: tint,
                                      intent: RadioPreviousIntent(), fallbackAction: "previous")
                        widgetPlayControl(isPlaying: snap.isPlaying, tint: tint, stationID: snap.current?.id)
                        widgetControl(icon: "forward.fill", label: "下一个", tint: tint,
                                      intent: RadioNextIntent(), fallbackAction: "next")
                    }
                } else {
                    HStack {
                        Link(destination: WidgetAction.url("previous")) {
                            Image(systemName: "backward.fill").font(.title3).foregroundColor(tint).frame(maxWidth: .infinity)
                        }
                        Link(destination: WidgetAction.url("toggle", id: snap.current?.id)) {
                            Image(systemName: snap.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title2).foregroundColor(tint).frame(maxWidth: .infinity)
                        }
                        Link(destination: WidgetAction.url("next")) {
                            Image(systemName: "forward.fill").font(.title3).foregroundColor(tint).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}

struct MediumWidgetView: View {
    let entry: WidgetEntry
    var body: some View {
        let snap = entry.snapshot
        let tint = widgetTint(snap.theme)
        HStack(spacing: 14) {
            ZStack { widgetArtwork(snap.current, tint: tint) }
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "radio").font(.caption2.weight(.semibold)).foregroundColor(tint)
                    Text("收音机").font(.caption2.weight(.semibold)).foregroundColor(tint)
                    Spacer(minLength: 0)
                    PlaybackStatusBadge(isPlaying: snap.isPlaying, tint: tint)
                }
                Text(snap.current?.name ?? "未选择电台").font(.headline.weight(.bold)).lineLimit(1)
                Text(snap.current.map(widgetSubtitle) ?? "打开 App 选择电台")
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if #available(iOS 17.0, *) {
                    HStack(spacing: 0) {
                        widgetControl(icon: "backward.fill", label: "", tint: tint,
                                      intent: RadioPreviousIntent(), fallbackAction: "previous")
                        widgetPlayControl(isPlaying: snap.isPlaying, tint: tint, stationID: snap.current?.id)
                        widgetControl(icon: "forward.fill", label: "", tint: tint,
                                      intent: RadioNextIntent(), fallbackAction: "next")
                    }
                } else {
                    HStack(spacing: 0) {
                        Link(destination: WidgetAction.url("previous")) {
                            Image(systemName: "backward.fill").font(.title3.weight(.semibold)).foregroundColor(tint).frame(width: 46, height: 34)
                        }
                        Link(destination: WidgetAction.url("toggle", id: snap.current?.id)) {
                            Image(systemName: snap.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title3.weight(.semibold)).foregroundColor(tint).frame(width: 46, height: 34)
                        }
                        Link(destination: WidgetAction.url("next")) {
                            Image(systemName: "forward.fill").font(.title3.weight(.semibold)).foregroundColor(tint).frame(width: 46, height: 34)
                        }
                    }
                }
            }
        }
        .padding(14)
    }
}

struct LargeWidgetView: View {
    let entry: WidgetEntry
    var body: some View {
        let snap = entry.snapshot
        let tint = widgetTint(snap.theme)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "radio").foregroundColor(tint)
                Text("收音机").font(.headline.weight(.bold))
                Spacer(minLength: 0)
                PlaybackStatusBadge(isPlaying: snap.isPlaying, tint: tint)
            }
            ZStack(alignment: .bottomLeading) {
                widgetArtwork(snap.current, tint: tint)
                LinearGradient(gradient: Gradient(colors: [Color.clear, Color.black.opacity(0.65)]),
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text(snap.current?.name ?? "未选择电台").font(.title3.weight(.bold)).foregroundColor(.white).lineLimit(1)
                    Text(snap.current.map(widgetSubtitle) ?? "打开 App 选择电台")
                        .font(.caption).foregroundColor(.white.opacity(0.85)).lineLimit(1)
                }
                .padding(14)
            }
            .frame(height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            if #available(iOS 17.0, *) {
                HStack(spacing: 0) {
                    widgetControl(icon: "backward.fill", label: "上一个", tint: tint,
                                  intent: RadioPreviousIntent(), fallbackAction: "previous")
                    widgetPlayControl(isPlaying: snap.isPlaying, tint: tint, stationID: snap.current?.id)
                    widgetControl(icon: "forward.fill", label: "下一个", tint: tint,
                                  intent: RadioNextIntent(), fallbackAction: "next")
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 0) {
                    largeFallbackLink("backward.fill", "previous", tint)
                    largeFallbackLink(snap.isPlaying ? "pause.circle.fill" : "play.circle.fill", "toggle", tint)
                    largeFallbackLink("forward.fill", "next", tint)
                }
                .frame(maxWidth: .infinity)
            }
            if !snap.recents.isEmpty {
                Text("最近播放").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(Array(snap.recents.prefix(4)), id: \.id) { station in
                        widgetRecentControl(station: station, tint: tint)
                    }
                }
            } else {
                Spacer(minLength: 0)
                Text("播放电台后，这里会显示快捷入口")
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func largeFallbackLink(_ icon: String, _ action: String, _ tint: Color) -> some View {
        Link(destination: WidgetAction.url(action)) {
            Image(systemName: icon).font(.title2.weight(.semibold)).foregroundColor(tint)
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }
    }
}

struct FMRadioWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WidgetEntry
    var body: some View {
        switch family {
        case .systemSmall: SmallWidgetView(entry: entry)
        case .systemMedium: MediumWidgetView(entry: entry)
        case .systemLarge: LargeWidgetView(entry: entry)
        @unknown default: SmallWidgetView(entry: entry)
        }
    }
}

@main
struct FMRadioWidgetBundle: WidgetBundle {
    var body: some Widget { FMRadioWidget() }
}

struct FMRadioWidget: Widget {
    let kind: String = "FMRadioWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FMRadioWidgetProvider()) { entry in
            FMRadioWidgetView(entry: entry)
        }
        .configurationDisplayName("收音机")
        .description("快速播放电台、切换频道")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
