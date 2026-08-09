import AppKit
import KeyboardShortcuts
import SwiftData
import SwiftUI

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension KeyboardShortcuts.Name {
    nonisolated(unsafe) static let toggleQuickEntry = Self(
        "toggleQuickEntry",
        default: .init(.s, modifiers: [.command, .shift])
    )
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var quickEntryPanel: QuickEntryPanel?
    private var settingsWindow: NSWindow?
    private var toastPanel: NSPanel?
    private var toastTask: Task<Void, Never>?
    private var menuDispatchWorkItem: DispatchWorkItem?
    private var quickEntryTransitionState = QuickEntryTransitionState()
    private let defaults = UserDefaults.standard

    override init() {
        super.init()
        AppSettingsMigration.migrateLegacySettingsIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        clearLegacyWindowRestorationState()
        ProtectionService.shared.refreshConfiguration()
        setupMenuBar()
        setupQuickEntryPanel()
        setupShortcuts()

        // Defer activation-policy application so SwiftUI has already
        // presented the window; calling it synchronously here can race
        // with WindowGroup initialisation and lose the Dock icon.
        DispatchQueue.main.async { [weak self] in
            self?.applyDockIconPreference()
        }

        // Observe only the one key we care about (avoids the broad
        // UserDefaults.didChangeNotification firing for every @AppStorage
        // write on launch and causing a race condition).
        defaults.addObserver(self,
                             forKeyPath: "hide_dock_icon",
                             options: [.new],
                             context: nil)
    }

    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        if keyPath == "hide_dock_icon" {
            DispatchQueue.main.async { [weak self] in
                self?.applyDockIconPreference()
            }
        }
    }

    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: "hide_dock_icon")
    }

    // Clicking the Dock icon brings the main window to the front
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            openVaultUI()
        }
        return true
    }

    // Hide from Dock (but keep in menu bar) or show in both
    private func applyDockIconPreference() {
        let hide = defaults.bool(forKey: "hide_dock_icon")
        NSApp.setActivationPolicy(hide ? .accessory : .regular)
    }

    private func clearLegacyWindowRestorationState() {
        defaults.set(false, forKey: "NSQuitAlwaysKeepsWindows")

        let keysToRemove = defaults.dictionaryRepresentation().keys.filter { key in
            key.hasPrefix("NSWindow Frame SwiftUI.")
                || key.hasPrefix("NSSplitView Subview Frames SwiftUI.")
        }

        guard !keysToRemove.isEmpty else { return }
        for key in keysToRemove {
            defaults.removeObject(forKey: key)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func application(_ sender: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ sender: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else { return }
        button.image = NSImage(
            systemSymbolName: "rectangle.and.paperclip",
            accessibilityDescription: "Clipboard to Shard"
        )
        button.action = #selector(menuBarClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
    }

    private func setupQuickEntryPanel() {
        let panel = QuickEntryPanel(
            contentRect: NSRect(origin: .zero, size: QuickEntryPanelMetrics.compactSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.onRequestDismissal = { [weak self] in
            self?.dismissQuickEntryPanel()
        }
        panel.center()
        refreshQuickEntryPanelContent(panel)
        quickEntryPanel = panel
    }

    private func refreshQuickEntryPanelContent(_ panel: QuickEntryPanel? = nil) {
        guard let targetPanel = panel ?? quickEntryPanel else { return }
        let container = VaultContainer.shared.container
        let hosting = TransparentHostingView(rootView: QuickEntryContentView().modelContainer(container))
        hosting.sizingOptions = []
        targetPanel.contentView = hosting
        targetPanel.setContentSize(QuickEntryPanelMetrics.compactSize)
    }

    private func setupShortcuts() {
        KeyboardShortcuts.onKeyUp(for: .toggleQuickEntry) { [weak self] in
            self?.toggleQuickEntryPanel()
        }
    }

    @objc
    private func menuBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showMenu()
            return
        }

        if event.type == .leftMouseUp {
            if event.clickCount == 2 {
                menuDispatchWorkItem?.cancel()
                handleClipboardToShard()
            } else {
                let workItem = DispatchWorkItem { [weak self] in
                    self?.showMenu()
                }
                menuDispatchWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
            }
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let openVaultItem = menu.addItem(withTitle: "Open Vault", action: #selector(openVaultUI), keyEquivalent: "o")
        openVaultItem.keyEquivalentModifierMask = [.command]

        let quickEntryItem = menu.addItem(withTitle: "Quick Entry", action: #selector(showQuickEntryPanel), keyEquivalent: "S")
        quickEntryItem.keyEquivalentModifierMask = [.command, .shift]

        let settingsItem = menu.addItem(withTitle: "Settings…", action: #selector(openSettingsUI), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]

        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func handleClipboardToShard() {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            flashStatusBarIcon(success: false)
            return
        }

        do {
            let encryptionMode = ProtectionService.shared.desiredEncryptionModeForNewShard()
            if encryptionMode == .global, ProtectionService.shared.requiresGlobalUnlock {
                flashStatusBarIcon(success: false)
                showToast(message: "Unlock the vault before saving")
                return
            }

            let context = VaultContainer.shared.container.mainContext
            let tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
            let collections = (try? context.fetch(FetchDescriptor<ShardCollection>())) ?? []
            let shardsCollectionId = collections.first(where: {
                $0.name == VaultContainer.Defaults.shardsCollectionName
            })?.id ?? VaultContainer.Defaults.allCollectionID
            let tagIds = resolveStatusBarDoubleClickTagIDs(from: tags)

            try VaultRepository.shared.saveRawText(
                text,
                collectionId: shardsCollectionId,
                tagIds: tagIds,
                encryptionMode: encryptionMode
            )
            flashStatusBarIcon(success: true)
        } catch {
            flashStatusBarIcon(success: false)
        }
    }

    private func flashStatusBarIcon(success: Bool) {
        guard let button = statusItem?.button else { return }
        let originalImage = button.image
        let feedbackImage = NSImage(
            systemSymbolName: success ? "checkmark.circle.fill" : "xmark.circle.fill",
            accessibilityDescription: success ? "Saved" : "Failed"
        )
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            button.animator().alphaValue = 0.3
        }, completionHandler: {
            Task { @MainActor in
                button.image = feedbackImage
                button.contentTintColor = NSColor(red: 79/255, green: 70/255, blue: 229/255, alpha: 1)
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.2
                    button.animator().alphaValue = 1.0
                })
            }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Task { @MainActor in
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.2
                    button.animator().alphaValue = 0.3
                }, completionHandler: {
                    Task { @MainActor in
                        button.image = originalImage
                        button.contentTintColor = nil
                        NSAnimationContext.runAnimationGroup({ ctx in
                            ctx.duration = 0.2
                            button.animator().alphaValue = 1.0
                        })
                    }
                })
            }
        }
    }

    @objc
    private func showQuickEntryPanel() {
        toggleQuickEntryPanel(forceVisible: true)
    }

    @objc
    func openSettingsUI() {
        if #available(macOS 14.0, *) {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue.contains("settings") == true ||
                $0.title == "Settings"
            }) {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }

        if settingsWindow == nil {
            let accentHex = UserDefaults.standard.string(forKey: "custom_accent_hex") ?? ""
            let tintColor: Color? = accentHex.isEmpty ? nil : Color(hex: accentHex)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.isReleasedWhenClosed = false
            window.center()
            let settingsRoot = SettingsView().modelContainer(VaultContainer.shared.container)
            if let tintColor {
                window.contentView = NSHostingView(rootView: settingsRoot.tint(tintColor))
            } else {
                window.contentView = NSHostingView(rootView: settingsRoot)
            }
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc
    func openVaultUI() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { window in
            !(window is QuickEntryPanel) && window !== settingsWindow
        }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func toggleQuickEntryPanel(forceVisible: Bool = false) {
        guard let quickEntryPanel else { return }

        if quickEntryPanel.isVisible && !forceVisible {
            dismissQuickEntryPanel()
            return
        }

        if ProtectionService.shared.requiresGlobalUnlock {
            openVaultUI()
            showToast(message: "Unlock the vault before using Quick Entry")
            return
        }

        quickEntryTransitionState.beginPresentation()

        // Signal the existing SwiftUI view to reset its state. Do NOT
        // replace contentView here — creating a new NSHostingView every
        // open is slow and causes the notification to fire before the new
        // view's onReceive subscription is ready, breaking initialisation.
        NotificationCenter.default.post(name: .quickEntryWillOpen, object: nil)
        quickEntryPanel.setContentSize(QuickEntryPanelMetrics.compactSize)
        quickEntryPanel.alphaValue = 0
        quickEntryPanel.center()

        let restingFrame = quickEntryPanel.frame
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduceMotion {
            quickEntryPanel.setFrame(
                restingFrame.offsetBy(dx: 0, dy: QuickEntryPanelMetrics.presentationOffset),
                display: false
            )
        }

        NSApp.activate(ignoringOtherApps: true)
        quickEntryPanel.orderFrontRegardless()
        quickEntryPanel.makeKey()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.12 : 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            quickEntryPanel.animator().alphaValue = 1
            if !reduceMotion {
                quickEntryPanel.animator().setFrame(restingFrame, display: true)
            }
        }
    }

    func dismissQuickEntryPanel() {
        guard let quickEntryPanel,
              quickEntryPanel.isVisible,
              let transitionGeneration = quickEntryTransitionState.beginDismissal()
        else {
            return
        }

        let restingFrame = quickEntryPanel.frame
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let dismissedFrame = restingFrame.offsetBy(dx: 0, dy: QuickEntryPanelMetrics.presentationOffset)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.1 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            quickEntryPanel.animator().alphaValue = 0
            if !reduceMotion {
                quickEntryPanel.animator().setFrame(dismissedFrame, display: true)
            }
        } completionHandler: { [weak self, weak quickEntryPanel] in
            Task { @MainActor in
                guard let self,
                      let quickEntryPanel,
                      self.quickEntryTransitionState.isCurrentDismissal(
                          generation: transitionGeneration
                      )
                else {
                    return
                }

                quickEntryPanel.orderOut(nil)
                quickEntryPanel.setFrame(restingFrame, display: false)
                quickEntryPanel.alphaValue = 1
                _ = self.quickEntryTransitionState.finishDismissal(
                    generation: transitionGeneration
                )
            }
        }
    }

    private func resolveStatusBarDoubleClickTagIDs(from tags: [Tag]) -> [String] {
        guard defaults.object(forKey: "status_bar_double_click_add_tags") == nil || defaults.bool(forKey: "status_bar_double_click_add_tags") else {
            return []
        }

        let storedIDs = defaults.string(forKey: "status_bar_double_click_tag_ids")?
            .split(separator: ",")
            .map(String.init) ?? []
        let validIDs = storedIDs.filter { candidate in tags.contains(where: { $0.id == candidate }) }
        if !validIDs.isEmpty {
            return validIDs
        }

        if let clipboardTagID = tags.first(where: {
            $0.name.caseInsensitiveCompare(VaultContainer.Defaults.clipboardTagName) == .orderedSame || $0.symbol == "paperclip"
        })?.id {
            return [clipboardTagID]
        }

        return []
    }

    func showToast(message: String) {
        toastTask?.cancel()
        toastPanel?.orderOut(nil)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]

        let rootView = ToastView(message: message)
        panel.contentView = NSHostingView(rootView: rootView)

        if let visibleFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame {
            let origin = NSPoint(
                x: visibleFrame.maxX - 280,
                y: visibleFrame.maxY - 88
            )
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()
        toastPanel = panel

        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.toastPanel?.orderOut(nil)
        }
    }
}

private struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            VisualEffectView(material: .hudWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .padding(6)
    }
}
