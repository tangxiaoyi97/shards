import AppKit

enum QuickEntryPanelMetrics {
    static let compactSize = CGSize(width: 600, height: 64)
    static let previewSize = CGSize(width: 900, height: 600)
    static let cornerRadius: CGFloat = 16
    static let presentationOffset: CGFloat = 8
}

struct QuickEntryTransitionState {
    private(set) var generation = 0
    private(set) var isDismissing = false

    mutating func beginPresentation() {
        generation &+= 1
        isDismissing = false
    }

    mutating func beginDismissal() -> Int? {
        guard !isDismissing else { return nil }
        generation &+= 1
        isDismissing = true
        return generation
    }

    func isCurrentDismissal(generation expectedGeneration: Int) -> Bool {
        isDismissing && generation == expectedGeneration
    }

    mutating func finishDismissal(generation expectedGeneration: Int) -> Bool {
        guard isCurrentDismissal(generation: expectedGeneration) else { return false }
        isDismissing = false
        return true
    }
}

final class QuickEntryPanel: NSPanel {
    var onRequestDismissal: (() -> Void)?
    private var isPerformingFallbackDismissal = false

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing bufferingType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: bufferingType, defer: flag)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear

        hasShadow = true

        hidesOnDeactivate = false
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
    }

    override func sendEvent(_ event: NSEvent) {
        guard !Self.isEscapeKeyDown(event) else {
            requestDismissal(nil)
            return
        }
        super.sendEvent(event)
    }

    static func isEscapeKeyDown(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == 53
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func resignKey() {
        super.resignKey()
        requestDismissal(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        requestDismissal(sender)
    }

    private func requestDismissal(_ sender: Any?) {
        guard !isPerformingFallbackDismissal else { return }

        if let onRequestDismissal {
            onRequestDismissal()
        } else {
            isPerformingFallbackDismissal = true
            orderOut(sender)
            isPerformingFallbackDismissal = false
        }
    }
}
