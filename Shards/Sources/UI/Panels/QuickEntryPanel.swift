import AppKit
import QuartzCore

enum QuickEntryPanelMetrics {
    static let compactSize = CGSize(width: 600, height: 64)
    static let previewSize = CGSize(width: 900, height: 600)
    static let cornerRadius: CGFloat = 16
    static let presentationOffset: CGFloat = 8
    static let presentationScale: CGFloat = 0.982
    static let dismissalScale: CGFloat = 0.974
}

enum QuickEntryPanelMotion {
    static func presentationFrame(for restingFrame: NSRect) -> NSRect {
        scaledFrame(
            from: restingFrame,
            scale: QuickEntryPanelMetrics.presentationScale,
            verticalOffset: QuickEntryPanelMetrics.presentationOffset
        )
    }

    static func dismissalFrame(for restingFrame: NSRect) -> NSRect {
        scaledFrame(
            from: restingFrame,
            scale: QuickEntryPanelMetrics.dismissalScale,
            verticalOffset: QuickEntryPanelMetrics.presentationOffset * 0.75
        )
    }

    private static func scaledFrame(
        from frame: NSRect,
        scale: CGFloat,
        verticalOffset: CGFloat
    ) -> NSRect {
        let scaledSize = NSSize(width: frame.width * scale, height: frame.height * scale)
        return NSRect(
            x: frame.midX - scaledSize.width / 2,
            y: frame.midY - scaledSize.height / 2 + verticalOffset,
            width: scaledSize.width,
            height: scaledSize.height
        )
    }
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

@MainActor
final class QuickEntryDustAnimator {
    private enum Metrics {
        static let margin: CGFloat = 42
        static let maximumColumns = 30
        static let compactRows = 6
        static let previewRows = 12
        static let totalDuration = Duration.milliseconds(460)
    }

    private var overlayPanel: NSPanel?
    private var completionTask: Task<Void, Never>?
    private var completion: (() -> Void)?

    var isAnimating: Bool {
        overlayPanel != nil
    }

    func play(from sourcePanel: NSPanel, completion: @escaping () -> Void) -> Bool {
        cancel()

        guard let snapshot = snapshot(of: sourcePanel),
              let sourceView = sourcePanel.contentView
        else {
            return false
        }

        let sourceBounds = sourceView.bounds
        let expandedFrame = sourcePanel.frame.insetBy(dx: -Metrics.margin, dy: -Metrics.margin)
        let effectView = NSView(frame: NSRect(origin: .zero, size: expandedFrame.size))
        effectView.wantsLayer = true
        effectView.layer?.backgroundColor = NSColor.clear.cgColor
        effectView.layer?.masksToBounds = false

        addSnapshotTiles(
            snapshot,
            sourceBounds: sourceBounds,
            to: effectView,
            origin: NSPoint(x: Metrics.margin, y: Metrics.margin)
        )

        let panel = NSPanel(
            contentRect: expandedFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = sourcePanel.level
        panel.collectionBehavior = sourcePanel.collectionBehavior
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.contentView = effectView
        panel.orderFrontRegardless()

        overlayPanel = panel
        self.completion = completion
        completionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Metrics.totalDuration)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
        return true
    }

    func cancel() {
        completionTask?.cancel()
        completionTask = nil
        completion = nil
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
    }

    private func finish() {
        let pendingCompletion = completion
        completionTask = nil
        completion = nil
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
        pendingCompletion?()
    }

    private func snapshot(of panel: NSPanel) -> CGImage? {
        guard let view = panel.contentView else { return nil }
        view.layoutSubtreeIfNeeded()

        let bounds = view.bounds
        guard !bounds.isEmpty,
              let representation = view.bitmapImageRepForCachingDisplay(in: bounds)
        else {
            return nil
        }

        view.cacheDisplay(in: bounds, to: representation)
        return representation.cgImage
    }

    private func addSnapshotTiles(
        _ snapshot: CGImage,
        sourceBounds: NSRect,
        to effectView: NSView,
        origin: NSPoint
    ) {
        guard let rootLayer = effectView.layer else { return }

        let columns = min(Metrics.maximumColumns, max(18, Int(sourceBounds.width / 20)))
        let rows = sourceBounds.height > QuickEntryPanelMetrics.compactSize.height * 2
            ? Metrics.previewRows
            : Metrics.compactRows
        let tileWidth = sourceBounds.width / CGFloat(columns)
        let tileHeight = sourceBounds.height / CGFloat(rows)
        let animationStart = CACurrentMediaTime()
        var random = DustRandomNumberGenerator(seed: 0x5348_4152_4453)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for row in 0..<rows {
            for column in 0..<columns {
                let x = CGFloat(column) * tileWidth
                let y = CGFloat(row) * tileHeight
                let width = column == columns - 1 ? sourceBounds.width - x : tileWidth
                let height = row == rows - 1 ? sourceBounds.height - y : tileHeight

                let tileLayer = CALayer()
                tileLayer.frame = NSRect(
                    x: origin.x + x,
                    y: origin.y + y,
                    width: width + 0.5,
                    height: height + 0.5
                )
                tileLayer.contents = snapshot
                tileLayer.contentsGravity = .resize
                tileLayer.contentsRect = CGRect(
                    x: x / sourceBounds.width,
                    y: y / sourceBounds.height,
                    width: width / sourceBounds.width,
                    height: height / sourceBounds.height
                )
                tileLayer.contentsScale = effectView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
                rootLayer.addSublayer(tileLayer)

                let progress = CGFloat(column) / CGFloat(max(columns - 1, 1))
                let delay = Double((1 - progress) * 0.08 + random.nextUnit() * 0.025)
                let duration = 0.24 + Double(random.nextUnit()) * 0.1
                let horizontalDrift = 18 + random.nextUnit() * 34
                let verticalDrift = (random.nextUnit() - 0.5) * 28
                let rotation = (random.nextUnit() - 0.5) * 0.26
                let finalScale = 0.46 + random.nextUnit() * 0.28

                var finalTransform = CATransform3DIdentity
                finalTransform = CATransform3DTranslate(finalTransform, horizontalDrift, verticalDrift, 0)
                finalTransform = CATransform3DRotate(finalTransform, rotation, 0, 0, 1)
                finalTransform = CATransform3DScale(finalTransform, finalScale, finalScale, 1)

                let opacityAnimation = CABasicAnimation(keyPath: "opacity")
                opacityAnimation.fromValue = 1
                opacityAnimation.toValue = 0

                let transformAnimation = CABasicAnimation(keyPath: "transform")
                transformAnimation.fromValue = CATransform3DIdentity
                transformAnimation.toValue = finalTransform

                let group = CAAnimationGroup()
                group.animations = [opacityAnimation, transformAnimation]
                group.beginTime = animationStart + delay
                group.duration = duration
                group.fillMode = .forwards
                group.isRemovedOnCompletion = false
                group.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                tileLayer.add(group, forKey: "quick-entry-dust")
            }
        }

        CATransaction.commit()
    }
}

private struct DustRandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextUnit() -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        let normalized = Double(state >> 11) / Double(1 << 53)
        return CGFloat(normalized)
    }
}
