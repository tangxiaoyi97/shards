import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class ModifierKeyMonitor {
    var isOptionPressed = false
    @ObservationIgnored nonisolated(unsafe) private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.isOptionPressed = event.modifierFlags.contains(.option)
            return event
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

struct ShardListRow: View {
    let title: String
    let modeName: String
    let iconName: String
    let isPinned: Bool
    let isDeleted: Bool
    let isLocked: Bool
    let isProtected: Bool
    let tags: [(name: String, symbol: String, colorHex: String)]
    let dateString: String
    var isCompact = false
    var accentColor: Color = .accentColor
    var contentPreview = ""

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 2 : 4) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accentColor)
                    .frame(width: 14)

                Text(title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if isCompact && !tags.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(tags.prefix(3), id: \.name) { tag in
                            Image(systemName: tag.symbol)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color(hex: tag.colorHex) ?? .secondary)
                        }
                    }
                }

                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if isProtected {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.caption2)
                        .foregroundStyle(.blue.opacity(0.8))
                }
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if isDeleted {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.6))
                }
            }

            if !isCompact {
                if !contentPreview.isEmpty {
                    Text(contentPreview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(dateString)
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    if !tags.isEmpty {
                        adaptiveTagSummary
                    }
                }
            }
        }
        .padding(.vertical, isCompact ? 2 : 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = [modeName]
        if !contentPreview.isEmpty { parts.append(contentPreview) }
        if isPinned { parts.append("Pinned") }
        if isLocked { parts.append("Editing locked") }
        if isProtected { parts.append("Protected") }
        if isDeleted { parts.append("In Trash") }
        if !tags.isEmpty { parts.append("Tags: \(tags.map(\.name).joined(separator: ", "))") }
        parts.append("Edited \(dateString)")
        return parts.joined(separator: ". ")
    }

    private var adaptiveTagSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(tags.prefix(3), id: \.name) { tag in
                    tagSummaryChip(for: tag, showsLabel: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(tags.prefix(3), id: \.name) { tag in
                    tagSummaryChip(for: tag, showsLabel: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tagSummaryChip(
        for tag: (name: String, symbol: String, colorHex: String),
        showsLabel: Bool
    ) -> some View {
        HStack(spacing: 2) {
            Image(systemName: tag.symbol)
                .font(.system(size: 8, weight: .semibold))
            if showsLabel {
                Text(tag.name)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Color(hex: tag.colorHex) ?? .secondary)
    }
}

struct BatchShardSelectionView: View {
    let selectedCount: Int
    let lockedCount: Int
    let isTrash: Bool
    let hasEditableSelection: Bool
    let shouldPin: Bool
    let addableTags: [Tag]
    let removableTags: [Tag]
    let accentColor: Color
    let onAddTag: (Tag) -> Void
    let onRemoveTag: (Tag) -> Void
    let onSetPinned: (Bool) -> Void
    let onTrash: () -> Void
    let onRestore: () -> Void
    let onDelete: () -> Void
    let onClearSelection: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(accentColor)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 6) {
                Text("\(selectedCount) Shards Selected")
                    .font(.title2.weight(.semibold))
                Text("Drag the selection onto a tag or Trash, or use the actions below.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if lockedCount > 0, !isTrash {
                    Label(
                        "\(lockedCount) locked \(lockedCount == 1 ? "shard" : "shards") will be skipped",
                        systemImage: "lock.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                tagMenu

                if isTrash {
                    Button(action: onRestore) {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash.slash")
                    }
                } else {
                    Button { onSetPinned(shouldPin) } label: {
                        Label(shouldPin ? "Pin" : "Unpin", systemImage: shouldPin ? "pin" : "pin.slash")
                    }
                    .disabled(!hasEditableSelection)
                    Button(role: .destructive, action: onTrash) {
                        Label("Trash", systemImage: "trash")
                    }
                    .disabled(!hasEditableSelection)
                }

                Button("Clear Selection", action: onClearSelection)
            }
            .buttonStyle(.bordered)

            Text("Categories are intentionally unchanged because a shard’s fields must continue to match its template schema.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.clear)
    }

    private var tagMenu: some View {
        Menu {
            if addableTags.isEmpty {
                Text("Every selected shard already has each available tag")
            } else {
                ForEach(addableTags) { tag in
                    Button { onAddTag(tag) } label: {
                        Label(tag.name, systemImage: tag.symbol)
                    }
                }
            }

            if !removableTags.isEmpty {
                Divider()
                Menu("Remove Tag") {
                    ForEach(removableTags) { tag in
                        Button { onRemoveTag(tag) } label: {
                            Label(tag.name, systemImage: "tag.slash")
                        }
                    }
                }
            }
        } label: {
            Label("Tags", systemImage: "tag")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!hasEditableSelection)
    }
}

private struct ShardDropTargetModifier: ViewModifier {
    let accentColor: Color
    let onDrop: ([ShardDragPayload]) -> Bool
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accentColor.opacity(isTargeted ? 0.14 : 0))
            }
            .dropDestination(for: ShardDragPayload.self) { payloads, _ in
                onDrop(payloads)
            } isTargeted: { targeted in
                withAnimation(.easeOut(duration: 0.12)) {
                    isTargeted = targeted
                }
            }
    }
}

extension View {
    func shardDropTarget(
        accentColor: Color,
        onDrop: @escaping ([ShardDragPayload]) -> Bool
    ) -> some View {
        modifier(ShardDropTargetModifier(accentColor: accentColor, onDrop: onDrop))
    }
}

struct TagPopoverContent: View {
    let shard: Shard
    let availableTags: [Tag]
    var accentColor = Color(red: 79 / 255, green: 70 / 255, blue: 229 / 255)
    let onToggleTag: (Tag) -> Void
    let onCreateTag: (_ name: String, _ symbol: String, _ colorHex: String) -> Void

    @State private var quickTagName = ""
    @State private var quickTagSymbol = "tag.fill"
    @State private var quickTagColor = Color(red: 79 / 255, green: 70 / 255, blue: 229 / 255)
    @State private var showCreateSection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags")
                .font(.headline)
                .padding(.bottom, 2)

            if !availableTags.isEmpty {
                VStack(spacing: 1) {
                    ForEach(availableTags) { tag in
                        Button { onToggleTag(tag) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: tag.symbol)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color(hex: tag.colorHex) ?? .secondary)
                                    .frame(width: 18)
                                Text(tag.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if shard.tagIds.contains(tag.id) {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color(hex: tag.colorHex) ?? accentColor)
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(
                                shard.tagIds.contains(tag.id)
                                    ? (Color(hex: tag.colorHex) ?? accentColor).opacity(0.08)
                                    : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            DisclosureGroup(isExpanded: $showCreateSection) {
                VStack(spacing: 8) {
                    TextField("Tag name", text: $quickTagName)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                    HStack(spacing: 8) {
                        TextField("SF Symbol", text: $quickTagSymbol)
                            .textFieldStyle(.roundedBorder)
                            .font(.body)
                        ColorPicker("", selection: $quickTagColor)
                            .labelsHidden()
                    }
                    Button("Create & Attach") {
                        onCreateTag(
                            quickTagName.trimmingCharacters(in: .whitespacesAndNewlines),
                            quickTagSymbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "tag.fill"
                                : quickTagSymbol,
                            quickTagColor.toHex() ?? "#4F46E5"
                        )
                        quickTagName = ""
                        quickTagSymbol = "tag.fill"
                        quickTagColor = Color(red: 79 / 255, green: 70 / 255, blue: 229 / 255)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(quickTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 4)
            } label: {
                Text("New Tag")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = measuredRows(maxWidth: maxWidth, subviews: subviews)
        let measuredWidth = rows.map(\.width).max() ?? 0
        let measuredHeight = rows.map(\.height).reduce(0, +)
            + CGFloat(max(rows.count - 1, 0)) * spacing

        return CGSize(
            width: maxWidth.isFinite ? maxWidth : measuredWidth,
            height: measuredHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = measuredRows(maxWidth: bounds.width, subviews: subviews)
        var currentY = bounds.minY

        for row in rows {
            var currentX = bounds.minX

            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(
                        x: currentX,
                        y: currentY + (row.height - item.size.height) / 2
                    ),
                    proposal: ProposedViewSize(item.size)
                )
                currentX += item.size.width + spacing
            }

            currentY += row.height + spacing
        }
    }

    private func measuredRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var currentItems: [Item] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = currentItems.isEmpty
                ? size.width
                : currentWidth + spacing + size.width

            if !currentItems.isEmpty, proposedWidth > maxWidth {
                rows.append(Row(items: currentItems, width: currentWidth, height: currentHeight))
                currentItems = []
                currentWidth = 0
                currentHeight = 0
            }

            currentWidth = currentItems.isEmpty ? size.width : currentWidth + spacing + size.width
            currentHeight = max(currentHeight, size.height)
            currentItems.append(Item(index: index, size: size))
        }

        if !currentItems.isEmpty {
            rows.append(Row(items: currentItems, width: currentWidth, height: currentHeight))
        }

        return rows
    }

    private struct Item {
        let index: Int
        let size: CGSize
    }

    private struct Row {
        let items: [Item]
        let width: CGFloat
        let height: CGFloat
    }
}

struct ProtectionPrompt: Identifiable {
    enum Purpose {
        case protect
        case unlockProtected
        case removeProtection
    }

    let id = UUID()
    let shardID: String
    let purpose: Purpose

    var title: String {
        switch purpose {
        case .protect: "Protect Shard"
        case .unlockProtected: "Unlock Protected Shard"
        case .removeProtection: "Remove Protection"
        }
    }

    var actionTitle: String {
        switch purpose {
        case .protect: "Protect"
        case .unlockProtected: "Unlock"
        case .removeProtection: "Remove Protection"
        }
    }

    var description: String {
        switch purpose {
        case .protect:
            "This password will be required before the shard content can be viewed."
        case .unlockProtected:
            "Enter the shard password to reveal the content for this session."
        case .removeProtection:
            "Enter the shard password to remove its dedicated protection."
        }
    }
}

struct ProtectionPasswordSheet: View {
    let prompt: ProtectionPrompt
    @Binding var password: String
    @Binding var confirmation: String
    let errorMessage: String?
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt.title)
                .font(.title3.weight(.bold))

            Text(prompt.description)
                .font(.body)
                .foregroundStyle(.secondary)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            if prompt.purpose == .protect {
                SecureField("Confirm password", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(prompt.actionTitle, action: onSubmit)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
