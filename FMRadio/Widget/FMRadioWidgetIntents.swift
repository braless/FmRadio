import Foundation
import AppIntents
import WidgetKit

/// Widget target 内的 App Intents：iOS 17+ 可直接控制主 App 播放器，无需打开 UI。
@available(iOS 17.0, *)
private func runWidgetCommand(_ action: String, id: String? = nil) {
    let command = WidgetCommand(action: action, stationID: id, at: Date().timeIntervalSince1970)
    WidgetShared.applyCommandToWidgetState(command)
    WidgetShared.postCommand(command)
    WidgetShared.reloadWidget()
}

@available(iOS 17.0, *)
struct RadioToggleIntent: AppIntent {
    static let title: LocalizedStringResource = "播放/暂停"
    static let description = IntentDescription("切换当前电台播放状态，无需打开 App。")

    func perform() async throws -> some IntentResult {
        runWidgetCommand("toggle")
        return .result()
    }
}

@available(iOS 17.0, *)
struct RadioPreviousIntent: AppIntent {
    static let title: LocalizedStringResource = "上一个电台"
    func perform() async throws -> some IntentResult {
        runWidgetCommand("previous")
        return .result()
    }
}

@available(iOS 17.0, *)
struct RadioNextIntent: AppIntent {
    static let title: LocalizedStringResource = "下一个电台"
    func perform() async throws -> some IntentResult {
        runWidgetCommand("next")
        return .result()
    }
}

@available(iOS 17.0, *)
struct RadioPlayIntent: AppIntent {
    static let title: LocalizedStringResource = "播放电台"
    @Parameter(title: "电台 ID")
    var stationID: String

    init() {}
    init(stationID: String) { self.stationID = stationID }

    func perform() async throws -> some IntentResult {
        runWidgetCommand("play", id: stationID)
        return .result()
    }
}
