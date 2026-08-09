import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    @MainActor
    func applyToApplication(_ application: NSApplication = .shared) {
        switch self {
        case .system:
            application.appearance = nil
        case .light:
            application.appearance = NSAppearance(named: .aqua)
        case .dark:
            application.appearance = NSAppearance(named: .darkAqua)
        }
    }

    static var current: AppAppearance {
        let rawValue = UserDefaults.standard.string(forKey: AppSettingKeys.appearance)
        return AppAppearance(rawValue: rawValue ?? "") ?? .system
    }
}
