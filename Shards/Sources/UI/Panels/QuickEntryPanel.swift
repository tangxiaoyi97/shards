import AppKit
import Observation
import SwiftUI

enum QuickEntryPanelMetrics {
    static let compactSize = CGSize(width: 600, height: 64)
    static let previewSize = CGSize(width: 900, height: 600)
    static let cornerRadius: CGFloat = 16
}

struct QuickEntryTransitionState {
    private(set) var generation = 0
    private(set) var isDismissing = false

    mutating func beginPresentation() {
        generation &+= 1
        isDismissing = false
    }

    mutating func beginDismissal(replacingCurrent: Bool = false) -> Int? {
        guard replacingCurrent || !isDismissing else { return nil }
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

struct QuickEntryFadeTiming: Equatable, Sendable {
    let presentationDuration: TimeInterval
    let dismissalDuration: TimeInterval
    let reducedMotionDuration: TimeInterval
    let completionLeeway: TimeInterval

    static let standard = Self(
        presentationDuration: 0.14,
        dismissalDuration: 0.12,
        reducedMotionDuration: 0.08,
        completionLeeway: 0.02
    )

    static let immediate = Self(
        presentationDuration: 0,
        dismissalDuration: 0,
        reducedMotionDuration: 0,
        completionLeeway: 0
    )

    func presentationDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? reducedMotionDuration : presentationDuration
    }

    func dismissalDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? reducedMotionDuration : dismissalDuration
    }
}

@MainActor
@Observable
final class QuickEntryPresentationState {
    private(set) var isContentVisible = false

    func setContentVisible(_ isVisible: Bool, duration: TimeInterval) {
        guard isContentVisible != isVisible else { return }

        if duration > 0 {
            withAnimation(.easeOut(duration: duration)) {
                isContentVisible = isVisible
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isContentVisible = isVisible
            }
        }
    }
}

@MainActor
final class QuickEntryPanelTransitionController {
    let presentationState: QuickEntryPresentationState

    private var state = QuickEntryTransitionState()
    private let timing: QuickEntryFadeTiming
    private var dismissalTask: Task<Void, Never>?

    init(
        presentationState: QuickEntryPresentationState = QuickEntryPresentationState(),
        timing: QuickEntryFadeTiming = .standard
    ) {
        self.presentationState = presentationState
        self.timing = timing
    }

    var isDismissing: Bool {
        state.isDismissing
    }

    func beginPresentation() {
        cancelDismissalTask()
        state.beginPresentation()
        presentationState.setContentVisible(false, duration: 0)
    }

    func present(reduceMotion: Bool) {
        guard !state.isDismissing else { return }
        presentationState.setContentVisible(
            true,
            duration: timing.presentationDuration(reduceMotion: reduceMotion)
        )
    }

    func dismiss(
        panel: NSPanel,
        completedCapture: Bool,
        reduceMotion: Bool
    ) {
        guard panel.isVisible,
              let generation = state.beginDismissal(replacingCurrent: completedCapture)
        else {
            return
        }

        cancelDismissalTask()
        let fadeDuration = timing.dismissalDuration(reduceMotion: reduceMotion)
        presentationState.setContentVisible(false, duration: fadeDuration)

        let completionDelay = fadeDuration + timing.completionLeeway
        guard completionDelay > 0 else {
            finishDismissal(panel: panel, generation: generation)
            return
        }

        dismissalTask = Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .seconds(completionDelay))
            guard !Task.isCancelled, let self, let panel else { return }
            self.finishDismissal(panel: panel, generation: generation)
        }
    }

    private func finishDismissal(panel: NSPanel, generation: Int) {
        guard state.finishDismissal(generation: generation) else { return }

        panel.orderOut(nil)
        panel.alphaValue = 1
        dismissalTask = nil
    }

    private func cancelDismissalTask() {
        dismissalTask?.cancel()
        dismissalTask = nil
    }
}
