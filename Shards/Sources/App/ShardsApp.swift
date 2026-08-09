import SwiftUI

@main
struct ShardsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("custom_accent_hex") private var customAccentHex = ""

    private static let defaultAccentColor = Color(red: 79/255, green: 70/255, blue: 229/255) // #4F46E5 indigo

    private var appTint: Color {
        if let custom = Color(hex: customAccentHex) {
            return custom
        }
        return Self.defaultAccentColor
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .containerBackground(.clear, for: .window)
                .modelContainer(VaultContainer.shared.container)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .toolbar(removing: .title)
                .tint(appTint)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 720)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .containerBackground(.clear, for: .window)
                .modelContainer(VaultContainer.shared.container)
                .tint(appTint)
        }
        .restorationBehavior(.disabled)
    }
}
