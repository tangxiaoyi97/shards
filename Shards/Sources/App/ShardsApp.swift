import Observation
import SwiftUI

enum VaultCommand {
    case createShard
    case save
    case togglePin
    case moveToTrash
    case focusSearch
    case toggleEditorFocus
}

struct VaultCommandState: Equatable {
    let canSave: Bool
    let canTogglePin: Bool
    let canMoveToTrash: Bool
    let isEditorFocused: Bool

    static let unavailable = VaultCommandState(
        canSave: false,
        canTogglePin: false,
        canMoveToTrash: false,
        isEditorFocused: false
    )
}

struct VaultCommandRequest {
    let targetID: UUID
    let command: VaultCommand
}

extension Notification.Name {
    static let vaultCommandRequested = Notification.Name("vaultCommandRequested")
}

@MainActor
@Observable
final class VaultCommandDispatcher {
    let targetID = UUID()
    private(set) var state = VaultCommandState.unavailable

    func update(_ state: VaultCommandState) {
        self.state = state
    }

    func perform(_ command: VaultCommand) {
        NotificationCenter.default.post(
            name: .vaultCommandRequested,
            object: VaultCommandRequest(targetID: targetID, command: command)
        )
    }
}

private struct VaultCommandDispatcherKey: FocusedValueKey {
    typealias Value = VaultCommandDispatcher
}

extension FocusedValues {
    var vaultCommandDispatcher: VaultCommandDispatcher? {
        get { self[VaultCommandDispatcherKey.self] }
        set { self[VaultCommandDispatcherKey.self] = newValue }
    }
}

private struct VaultCommands: Commands {
    @FocusedValue(\.vaultCommandDispatcher) private var dispatcher

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Shard") {
                dispatcher?.perform(.createShard)
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(dispatcher == nil)
        }

        CommandMenu("Shard") {
            Button("Save Shard") {
                dispatcher?.perform(.save)
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(dispatcher?.state.canSave != true)

            Button("Toggle Pin") {
                dispatcher?.perform(.togglePin)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(dispatcher?.state.canTogglePin != true)

            Divider()

            Button("Focus Search") {
                dispatcher?.perform(.focusSearch)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(dispatcher == nil)

            Button(dispatcher?.state.isEditorFocused == true ? "Exit Focus Mode" : "Focus Editor") {
                dispatcher?.perform(.toggleEditorFocus)
            }
            .disabled(dispatcher?.state.canSave != true)

            Divider()

            Button("Move to Trash", role: .destructive) {
                dispatcher?.perform(.moveToTrash)
            }
            .disabled(dispatcher?.state.canMoveToTrash != true)
        }
    }
}

@main
struct ShardsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("custom_accent_hex") private var customAccentHex = ""
    @AppStorage(AppSettingKeys.appearance) private var appearanceRawValue = AppAppearance.system.rawValue

    private static let defaultAccentColor = Color(red: 79/255, green: 70/255, blue: 229/255) // #4F46E5 indigo

    private var appTint: Color {
        if let custom = Color(hex: customAccentHex) {
            return custom
        }
        return Self.defaultAccentColor
    }

    private var preferredColorScheme: ColorScheme? {
        (AppAppearance(rawValue: appearanceRawValue) ?? .system).preferredColorScheme
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .containerBackground(.clear, for: .window)
                .modelContainer(VaultContainer.shared.container)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .toolbar(removing: .title)
                .tint(appTint)
                .preferredColorScheme(preferredColorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 720)
        .restorationBehavior(.disabled)
        .commands {
            VaultCommands()

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdateController.shared.checkForUpdates()
                }
            }
        }

        Settings {
            SettingsView()
                .containerBackground(.clear, for: .window)
                .modelContainer(VaultContainer.shared.container)
                .tint(appTint)
                .preferredColorScheme(preferredColorScheme)
        }
        .restorationBehavior(.disabled)
    }
}
