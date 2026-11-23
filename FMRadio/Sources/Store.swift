import Foundation
import Combine
import SwiftUI

/// Persists favorites / recents / theme, matching the original app's
/// `LAST_RADIO_STORE`, `RADIO_FAVORITED`, `RADIO_RECENT`, color settings.
final class Store: ObservableObject {
    @Published var favorites: [String] {
        didSet { defaults.set(favorites, forKey: "RADIO_FAVORITED") }
    }
    @Published var recents: [String] {
        didSet { defaults.set(recents, forKey: "RADIO_RECENT") }
    }
    @Published var lastStationID: String? {
        didSet { defaults.set(lastStationID, forKey: "LAST_RADIO_STORE") }
    }
    @AppStorage("APP_THEME_COLOR") var themeColor: String = "blue"
    @AppStorage("APP_UI_COLOR_CHANGED") var colorChanged: Bool = false

    private let defaults = UserDefaults.standard

    init() {
        favorites = defaults.stringArray(forKey: "RADIO_FAVORITED") ?? []
        recents = defaults.stringArray(forKey: "RADIO_RECENT") ?? []
        lastStationID = defaults.string(forKey: "LAST_RADIO_STORE")
    }

    func isFavorite(_ s: Station) -> Bool { favorites.contains(s.id) }
    func toggleFavorite(_ s: Station) {
        if let i = favorites.firstIndex(of: s.id) { favorites.remove(at: i) }
        else { favorites.append(s.id) }
    }
    func touch(_ s: Station) {
        recents.removeAll { $0 == s.id }
        recents.insert(s.id, at: 0)
        if recents.count > 30 { recents = Array(recents.prefix(30)) }
        lastStationID = s.id
    }
    func clearRecents() {
        recents.removeAll()
    }
}
