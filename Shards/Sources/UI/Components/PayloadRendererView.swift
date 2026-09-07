import AppKit
import SwiftData
import SwiftUI

struct PayloadRendererView: View {
    @Binding var payloadText: String
    let contentID: String
    var isEditable = true
    @AppStorage(AppSettingKeys.editorFontSize) private var editorFontSize = 15.0
    @Query(sort: \PresetTemplate.orderIndex, order: .forward) private var templates: [PresetTemplate]
    @State private var isShowingMalformedRawData = false

    private var payloadDecodingResult: PresetPayloadDecodingResult {
        switch PresetPayload.decoding(payloadText) {
        case let .decoded(decoded):
            let schema = templates.matchingTemplate(for: decoded)?.schema
            return .decoded(decoded.resolvingMetadata(using: schema))
        case .plainText:
            return .plainText
        case .malformedStructured:
            return .malformedStructured
        }
    }

    var body: some View {
        Group {
            switch payloadDecodingResult {
            case let .decoded(preset):
                if preset.isRaw {
                    textRenderer(for: preset)
                } else {
                    switch effectivePresentationStyle(for: preset) {
                    case .table, .custom:
                        tableRenderer(for: preset)
                    case .plainText:
                        textRenderer(for: preset)
                    }
                }
            case .plainText:
                textRenderer(for: nil)
            case .malformedStructured:
                if isShowingMalformedRawData {
                    textRenderer(for: nil)
                } else {
                    malformedStructuredContent
                }
            }
        }
        .onChange(of: contentID) { _, _ in
            isShowingMalformedRawData = false
        }
    }

    private var malformedStructuredContent: some View {
        ContentUnavailableView {
            Label("Structured Content Unavailable", systemImage: "exclamationmark.shield")
        } description: {
            Text("This shard could not be decoded. Its raw data may contain sensitive values and remains hidden by default.")
        } actions: {
            Button("Show Raw Data") {
                isShowingMalformedRawData = true
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Reveals the complete undecoded shard")
        }
    }

    @ViewBuilder
    private func tableRenderer(for preset: PresetPayload) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(preset.fields.enumerated()), id: \.element.id) { index, field in
                    EditablePresetFieldRow(
                        field: field,
                        isEditable: isEditable,
                        value: Binding(
                            get: { value(for: field.id, in: preset) },
                            set: { updatePresetField(fieldID: field.id, value: $0, in: preset) }
                        )
                    )

                    if index < preset.fields.count - 1 {
                        Divider()
                            .padding(.leading, 16)
                    }
                }
            }
            .frame(maxWidth: 820)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.58),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.separator.opacity(0.38), lineWidth: 0.5)
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private func textRenderer(for preset: PresetPayload?) -> some View {
        let editorBinding = textBinding(for: preset)
        return HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if editorBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Write your shard…")
                        .font(.system(size: editorFontSize))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, PlainTextEditorView.textInset.width)
                        .padding(.top, PlainTextEditorView.textInset.height)
                        .allowsHitTesting(false)
                }

                PlainTextEditorView(
                    text: editorBinding,
                    fontSize: editorFontSize,
                    isEditable: isEditable
                )
                .disabled(!isEditable)
            }
            .frame(maxWidth: 820, maxHeight: .infinity)
            .background(
                Color(nsColor: .textBackgroundColor).opacity(0.16),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 18)
    }

    private func textBinding(for preset: PresetPayload?) -> Binding<String> {
        Binding(
            get: {
                if let preset {
                    if preset.isRaw {
                        return preset.fields.first(where: { $0.name.normalizedFieldKey == "content" })?.value ?? payloadText
                    }
                    if let field = editableTextField(in: preset) {
                        return field.value
                    }
                }
                return payloadText
            },
            set: { newValue in
                if let preset {
                    var updated = preset
                    if updated.isRaw,
                       let index = updated.fields.firstIndex(where: { $0.name.normalizedFieldKey == "content" }) {
                        updated.fields[index].value = newValue
                        write(payload: updated)
                    } else if let field = editableTextField(in: updated),
                              let index = updated.fields.firstIndex(where: { $0.id == field.id }) {
                        updated.fields[index].value = newValue
                        write(payload: updated)
                    } else {
                        payloadText = newValue
                    }
                } else {
                    payloadText = newValue
                }
            }
        )
    }

    private func value(for fieldID: String, in preset: PresetPayload) -> String {
        preset.fields.first(where: { $0.id == fieldID })?.value ?? ""
    }

    private func updatePresetField(fieldID: String, value: String, in preset: PresetPayload) {
        var updated = preset
        guard let index = updated.fields.firstIndex(where: { $0.id == fieldID }) else { return }
        updated.fields[index].value = value
        write(payload: updated)
    }

    private func write(payload: PresetPayload) {
        if payload.isRaw {
            payloadText = payload.fields.first(where: { $0.name.normalizedFieldKey == "content" })?.value ?? ""
            return
        }

        if let data = try? JSONEncoder().encode(payload),
           let json = String(data: data, encoding: .utf8) {
            payloadText = json
        }
    }

    private func presentationStyle(for preset: PresetPayload) -> PresetTemplateSchema.PresentationStyle {
        template(for: preset)?.presentationStyle ?? inferredPresentationStyle(for: preset)
    }

    private func effectivePresentationStyle(for preset: PresetPayload) -> PresetTemplateSchema.PresentationStyle {
        preset.fields.contains(where: \.isEffectivelySensitive)
            ? .table
            : presentationStyle(for: preset)
    }

    private func template(for preset: PresetPayload) -> PresetTemplate? {
        templates.matchingTemplate(for: preset)
    }

    private func editableTextField(in preset: PresetPayload) -> PresetField? {
        let preferredKeys = ["content", "body", "text", "note"]
        for key in preferredKeys {
            if let field = preset.fields.first(where: { $0.name.normalizedFieldKey == key }) {
                return field
            }
        }

        if let key = template(for: preset)?.schema.titleFieldKey,
           let field = preset.fields.first(where: { $0.name.normalizedFieldKey == key }) {
            return field
        }

        return preset.fields.first
    }

    private func inferredPresentationStyle(for preset: PresetPayload) -> PresetTemplateSchema.PresentationStyle {
        if preset.fields.count == 1,
           let field = preset.fields.first,
           ["content", "body", "text", "note"].contains(field.name.normalizedFieldKey) {
            return .plainText
        }
        return .table
    }
}

private struct PlainTextEditorView: NSViewRepresentable {
    static let textInset = CGSize(width: 24, height: 20)

    @Binding var text: String
    var fontSize: CGFloat
    var isEditable = true

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.string = text
        textView.drawsBackground = false
        textView.backgroundColor = NSColor.clear
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textContainerInset = NSSize(width: Self.textInset.width, height: Self.textInset.height)
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true
        textView.allowsUndo = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = NSView.AutoresizingMask.width

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        textView.isEditable = isEditable
        let newFont = NSFont.systemFont(ofSize: fontSize)
        if textView.font != newFont {
            textView.font = newFont
        }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditorView

        init(_ parent: PlainTextEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let newValue = textView.string
            if parent.text != newValue {
                parent.text = newValue
            }
        }
    }
}

struct EditablePresetFieldRow: View {
    let field: PresetField
    var isEditable = true
    @Binding var value: String
    @AppStorage(AppSettingKeys.editorFontSize) private var editorFontSize = 15.0
    @State private var isRevealed = false
    @State private var isHovered = false
    @State private var showCopied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSecret: Bool {
        field.isEffectivelySensitive
    }

    private var isLongForm: Bool {
        field.isEffectivelyLongForm
    }

    private var fieldIcon: String {
        switch field.valueType {
        case .licenseKey: return "key.viewfinder"
        case .secret: return "key.fill"
        case .username: return "person.fill"
        case .email: return "envelope.fill"
        case .url: return "link"
        case .phone: return "phone.fill"
        case .number: return "number"
        case .date: return "calendar"
        case .note: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .text, .custom, .none: break
        }

        let name = field.name.lowercased()
        if name.contains("password") { return "key.fill" }
        if name.contains("token") || name.contains("key") { return "network.badge.shield.half.filled" }
        if name.contains("email") { return "envelope.fill" }
        if name.contains("user") || name.contains("name") { return "person.fill" }
        if name.contains("url") || name.contains("website") { return "link" }
        if name.contains("note") || name.contains("content") { return "doc.text" }
        if name.contains("phone") { return "phone.fill" }
        return "textformat"
    }

    var body: some View {
        HStack(alignment: isLongForm ? .top : .center, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: fieldIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Text(field.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 120, alignment: .leading)

            Group {
                if isSecret && !isRevealed {
                    SecureField(field.placeholder ?? field.name, text: $value)
                        .textFieldStyle(.plain)
                        .font(.system(size: editorFontSize, design: .monospaced))
                        .disabled(!isEditable)
                } else if isLongForm {
                    TextEditor(text: $value)
                        .font(.system(size: editorFontSize))
                        .frame(minHeight: 96)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .disabled(!isEditable)
                } else {
                    TextField(field.placeholder ?? field.name, text: $value)
                        .textFieldStyle(.plain)
                        .font(
                            field.usesMonospacedText
                                ? .system(size: editorFontSize, design: .monospaced)
                                : .system(size: editorFontSize)
                        )
                        .textSelection(.enabled)
                        .disabled(!isEditable)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if isSecret {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                            isRevealed.toggle()
                        }
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isRevealed ? "Hide" : "Reveal")
                    .accessibilityLabel(isRevealed ? "Hide \(field.name)" : "Reveal \(field.name)")
                }

                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(value, forType: .string)
                    withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.15)) { showCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.15)) { showCopied = false }
                    }
                } label: {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(showCopied ? .green : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy")
                .accessibilityLabel("Copy \(field.name)")
                .opacity(isHovered || showCopied ? 1 : 0.38)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentShape(.rect)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.12)) { isHovered = hovering }
        }
        .onChange(of: field.id) { _, _ in
            isRevealed = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            isRevealed = false
        }
    }
}
