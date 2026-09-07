import AppKit
import SwiftData
import SwiftUI

enum QuickEntryMode: Hashable {
    case smart
    case template(String)
}

enum QuickEntryModeCycle {
    static func next(
        from currentMode: QuickEntryMode,
        in availableModes: [QuickEntryMode],
        reverse: Bool
    ) -> QuickEntryMode? {
        guard !availableModes.isEmpty else { return nil }
        guard let currentIndex = availableModes.firstIndex(of: currentMode) else {
            return reverse ? availableModes.last : availableModes.first
        }

        let offset = reverse ? -1 : 1
        let nextIndex = (currentIndex + offset + availableModes.count) % availableModes.count
        return availableModes[nextIndex]
    }
}

enum QuickEntrySubmissionOutcome: Equatable {
    case blocked(requiredFieldName: String)
    case advance(nextIndex: Int, skippedOptionalField: Bool)
    case save(skippedOptionalField: Bool)
}

enum QuickEntryFormPolicy {
    static func submissionOutcome(
        field: PresetField?,
        input: String,
        currentIndex: Int,
        fieldCount: Int
    ) -> QuickEntrySubmissionOutcome {
        guard let field else {
            return .blocked(requiredFieldName: "Content")
        }

        let isEmpty = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if field.isRequired && isEmpty {
            return .blocked(requiredFieldName: field.name)
        }

        let skippedOptionalField = !field.isRequired && isEmpty
        if currentIndex < fieldCount - 1 {
            return .advance(
                nextIndex: currentIndex + 1,
                skippedOptionalField: skippedOptionalField
            )
        }
        return .save(skippedOptionalField: skippedOptionalField)
    }
}

enum QuickEntryModeTransferPolicy {
    static func seedText(from input: String, sourceField: PresetField?) -> String? {
        sourceField?.isEffectivelySensitive == true ? nil : input
    }
}

private enum QuickEntryLayout {
    static let rawSelectionToken = "__raw__"
}

private struct SmartPreviewState: Identifiable {
    let id = UUID()
    var sourceText: String
    var rawContent: String
    var selectedTemplateID: String?
    var fields: [PresetField]
}

private struct QuickEntryModeDraft {
    var fields: [PresetField]
    var currentFieldIndex: Int
}

private enum QuickEntryFeedback: Equatable {
    case none
    case error(String)

    var errorMessage: String? {
        guard case let .error(message) = self else { return nil }
        return message
    }
}

extension Notification.Name {
    static let quickEntryWillOpen = Notification.Name("quickEntryWillOpen")
    static let quickEntryDidDismiss = Notification.Name("quickEntryDidDismiss")
}

struct QuickEntryActions {
    let captureCompleted: @MainActor (Shard) -> Void
}

struct QuickEntryContentView: View {
    let actions: QuickEntryActions
    let presentationState: QuickEntryPresentationState

    @Query(sort: \PresetTemplate.orderIndex) private var templates: [PresetTemplate]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @AppStorage(AppSettingKeys.llmEndpointURL) private var llmEndpointURL = ""
    @AppStorage(AppSettingKeys.llmAPIToken) private var llmToken = ""
    @AppStorage(AppSettingKeys.llmRequestFormat) private var llmFormat = "openai"
    @AppStorage(AppSettingKeys.llmModelName) private var llmModelName = ""
    @AppStorage("default_quick_entry_mode") private var defaultQuickEntryMode = "template:shard"
    @AppStorage("quick_entry_selected_mode") private var storedSelectedMode = "template:shard"
    @AppStorage("custom_accent_hex") private var customAccentHex = ""

    @State private var selectedMode: QuickEntryMode = .template("shard")
    @State private var currentFieldIndex = 0
    @State private var payloadBuffer: [PresetField] = []
    @State private var inputText = ""
    @State private var feedback: QuickEntryFeedback = .none
    @State private var modeDrafts: [QuickEntryMode: QuickEntryModeDraft] = [:]
    @State private var isProcessing = false
    @State private var isCompletingCapture = false
    @State private var smartPreview: SmartPreviewState?
    @State private var smartRequestTask: Task<Void, Never>?
    @State private var smartRequestGeneration = 0
    @FocusState private var isInputFocused: Bool

    init(
        actions: QuickEntryActions,
        presentationState: QuickEntryPresentationState
    ) {
        self.actions = actions
        self.presentationState = presentationState
    }

    private var inputFieldIdentity: String {
        let secureToken = currentField.map(isSecureField) == true ? "secure" : "plain"
        switch selectedMode {
        case .smart:
            return "smart-\(currentFieldIndex)-\(secureToken)"
        case let .template(templateID):
            return "template-\(templateID)-\(currentFieldIndex)-\(secureToken)"
        }
    }

    private var appAccentColor: Color {
        Color(hex: customAccentHex) ?? Color(red: 79 / 255, green: 70 / 255, blue: 229 / 255)
    }

    private var interfaceAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 1)
    }

    private var hasLLMConfigured: Bool {
        !llmEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !llmToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !llmModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var smartConfiguration: SmartInputConfiguration {
        SmartInputConfiguration(
            endpointURL: llmEndpointURL,
            apiToken: llmToken,
            modelName: llmModelName,
            requestFormatString: llmFormat
        )
    }

    private var selectedTemplate: PresetTemplate? {
        guard case let .template(templateID) = selectedMode else { return nil }
        return templates.first(where: { $0.id == templateID })
    }

    private var currentField: PresetField? {
        payloadBuffer.indices.contains(currentFieldIndex) ? payloadBuffer[currentFieldIndex] : nil
    }

    private var currentPreviewTemplate: PresetTemplate? {
        guard let selectedTemplateID = smartPreview?.selectedTemplateID else { return nil }
        return templates.first(where: { $0.id == selectedTemplateID })
    }

    private var supportsStepping: Bool {
        selectedMode != .smart && payloadBuffer.count > 1
    }

    private var availableModes: [QuickEntryMode] {
        var modes = templates.map { QuickEntryMode.template($0.id) }
        if hasLLMConfigured {
            modes.insert(.smart, at: 0)
        }
        return modes
    }

    private var isShowingFailureFeedback: Bool {
        feedback.errorMessage != nil
    }

    private var isShowingSmartPreview: Bool {
        smartPreview != nil
    }

    private var hasUnsavedUserDraft: Bool {
        guard !isCompletingCapture else { return false }
        return !inputText.isEmpty
            || payloadBuffer.contains(where: { !$0.value.isEmpty })
            || modeDrafts.values.contains(where: { draft in
                draft.fields.contains(where: { !$0.value.isEmpty })
            })
            || smartPreview != nil
            || isProcessing
    }

    private var previewTemplateSelection: Binding<String> {
        Binding(
            get: { smartPreview?.selectedTemplateID ?? QuickEntryLayout.rawSelectionToken },
            set: { applySmartPreviewTemplateSelection($0) }
        )
    }

    private var previewRawContentBinding: Binding<String> {
        Binding(
            get: { smartPreview?.rawContent ?? "" },
            set: { newValue in
                guard var preview = smartPreview else { return }
                preview.rawContent = newValue
                smartPreview = preview
            }
        )
    }

    private var previewCanSave: Bool {
        guard let preview = smartPreview else { return false }

        if let template = currentPreviewTemplate {
            let definitions = template.schema.fields
            if preview.fields.count < definitions.count {
                return false
            }
            for (index, definition) in definitions.enumerated() where definition.isRequired {
                if preview.fields[index].trimmedValue.isEmpty {
                    return false
                }
            }
            return true
        }

        return !preview.rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var previewValidationMessage: String? {
        guard let preview = smartPreview else { return nil }

        if let template = currentPreviewTemplate {
            let missingFields = template.schema.fields.enumerated().compactMap { index, definition -> String? in
                guard definition.isRequired else { return nil }
                guard preview.fields.indices.contains(index) else { return definition.name }
                return preview.fields[index].trimmedValue.isEmpty ? definition.name : nil
            }
            if !missingFields.isEmpty {
                return "Missing required fields: \(missingFields.joined(separator: ", "))"
            }
            return "Ready to save into \(targetCollectionName(for: template))."
        }

        if preview.rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Raw content cannot be empty."
        }
        return "Ready to save as a raw shard."
    }

    var body: some View {
        Group {
            if !VaultContainer.shared.isPersistentStoreAvailable {
                vaultUnavailableView
                    .padding(.horizontal, 18)
            } else if isShowingSmartPreview {
                smartPreviewView
                    .padding(24)
            } else {
                compactComposerView
                    .padding(.horizontal, 14)
            }
        }
        .frame(
            width: isShowingSmartPreview ? QuickEntryPanelMetrics.previewSize.width : QuickEntryPanelMetrics.compactSize.width,
            height: isShowingSmartPreview ? QuickEntryPanelMetrics.previewSize.height : QuickEntryPanelMetrics.compactSize.height
        )
        .background {
            quickEntrySurface
        }
        .clipShape(RoundedRectangle(cornerRadius: QuickEntryPanelMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: QuickEntryPanelMetrics.cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.13), lineWidth: 0.5)
        )
        .opacity(presentationState.isContentVisible ? 1 : 0)
        .allowsHitTesting(presentationState.isContentVisible)
        .accessibilityHidden(!presentationState.isContentVisible)
        .animation(interfaceAnimation, value: isProcessing)
        .animation(interfaceAnimation, value: feedback)
        .animation(interfaceAnimation, value: isShowingSmartPreview)
        .onAppear {
            initializeFlow(forceDefault: true)
            updateQuickEntryPanelSize(animated: false)
        }
        .onChange(of: templates.map(\.id)) { _, _ in
            initializeFlow(forceDefault: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickEntryWillOpen)) { _ in
            initializeFlow(forceDefault: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickEntryDidDismiss)) { _ in
            initializeFlow(forceDefault: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultFlushRequested)) { notification in
            guard let request = notification.object as? VaultFlushRequest,
                  presentationState.isContentVisible,
                  hasUnsavedUserDraft
            else { return }
            request.recordFailure("Quick Entry still contains an unsaved draft.")
        }
        .onChange(of: isShowingSmartPreview) { _, _ in
            updateQuickEntryPanelSize(animated: true)
        }
        .onChange(of: inputText) { _, _ in
            if isShowingFailureFeedback {
                feedback = .none
            }
        }
        .onDisappear {
            cancelSmartRequest()
        }
    }

    private var vaultUnavailableView: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Vault unavailable")
                    .font(.system(size: 15, weight: .semibold))
                Text("Nothing was saved to temporary storage. Press Esc to close.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var quickEntrySurface: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            ZStack {
                VisualEffectView(material: .popover, blendingMode: .behindWindow)
                Color(nsColor: .windowBackgroundColor)
                    .opacity(0.28)
            }
        }
    }

    private var compactComposerView: some View {
        HStack(spacing: 0) {
            modePickerView

            Divider()
                .frame(height: 22)
                .padding(.horizontal, 10)

            inputFieldSection
            trailingSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var smartPreviewView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Review Smart Result", systemImage: "sparkles")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))

                    Text("Confirm the template, edit the fields, and choose how this capture should be saved.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Back") {
                    dismissSmartPreview()
                }
                .buttonStyle(.bordered)
                .disabled(isProcessing || isCompletingCapture)

                Button("Save") {
                    saveSmartPreview()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing || isCompletingCapture || !previewCanSave)
            }

            HStack(spacing: 12) {
                Picker("Save As", selection: previewTemplateSelection) {
                    Text("Raw Text").tag(QuickEntryLayout.rawSelectionToken)
                    ForEach(templates) { template in
                        Text(template.name).tag(template.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 220)

                Label(targetCollectionName(for: currentPreviewTemplate), systemImage: "tray.full")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.7), in: Capsule())

                Spacer()

                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let errorMessage = feedback.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .transition(.opacity)
            } else if let previewValidationMessage {
                Text(previewValidationMessage)
                    .font(.caption)
                    .foregroundStyle(previewCanSave ? Color.secondary : Color.orange)
            }

            HStack(alignment: .top, spacing: 16) {
                previewEditorSection

                originalInputSection
                    .frame(width: 240)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var previewEditorSection: some View {
        Group {
            if let template = currentPreviewTemplate {
                previewTemplateEditor(for: template)
            } else {
                rawPreviewEditor
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewTemplateEditor(for template: PresetTemplate) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: template.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(appAccentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.name)
                            .font(.headline)
                        Text(template.schema.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                if let preview = smartPreview, !preview.fields.isEmpty {
                    ForEach(preview.fields) { field in
                        EditablePresetFieldRow(
                            field: field,
                            value: previewFieldBinding(fieldID: field.id)
                        )

                        if field.id != preview.fields.last?.id {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                } else {
                    Text("This template has no explicit fields. Switch to Raw Text if you want to keep the original capture as-is.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.separator.opacity(0.45), lineWidth: 0.5)
            )
        }
    }

    private var rawPreviewEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Raw Content")
                .font(.headline)

            TextEditor(text: previewRawContentBinding)
                .font(.system(size: 15, design: .rounded))
                .scrollContentBackground(.hidden)
                .background(.clear)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.separator.opacity(0.45), lineWidth: 0.5)
                )
        }
    }

    private var originalInputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Original Input")
                .font(.headline)

            ScrollView {
                Text(smartPreview?.sourceText ?? "")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxHeight: .infinity)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("Use Back to adjust the original prompt, or switch to Raw Text if you want to keep it untouched.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var modePickerView: some View {
        Menu {
            Button {
                switchMode(to: .smart)
            } label: {
                Label("Smart", systemImage: "sparkles")
            }
            .disabled(!hasLLMConfigured)

            Divider()

            ForEach(templates) { template in
                Button {
                    switchMode(to: .template(template.id))
                } label: {
                    Label(template.name, systemImage: template.symbol)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: modeSymbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(appAccentColor)
                    .contentTransition(.symbolEffect(.replace))

                Text(modeDisplayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 92, alignment: .leading)

                Text("Tab")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Capture mode")
        .accessibilityValue(modeDisplayName)
        .help(modeTitle)
        .disabled(isProcessing || isCompletingCapture)
    }

    @ViewBuilder
    private var inputFieldSection: some View {
        ZStack(alignment: .leading) {
            if inputText.isEmpty {
                Text(placeholderText)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.62))
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if payloadBuffer.isEmpty {
                TextField("", text: .constant(""))
                    .disabled(true)
            } else if let currentField {
                if isSecureField(currentField) {
                    SecureField("", text: $inputText)
                        .id(inputFieldIdentity)
                        .focused($isInputFocused)
                        .onSubmit { advanceOrSave() }
                        .textFieldStyle(.plain)
                } else {
                    TextField("", text: $inputText)
                        .id(inputFieldIdentity)
                        .focused($isInputFocused)
                        .onSubmit { advanceOrSave() }
                        .textFieldStyle(.plain)
                }
            }
        }
        .font(.system(size: 18, weight: .regular))
        .frame(maxWidth: .infinity)
        .disabled(isProcessing || isCompletingCapture)
        .onKeyPress(keys: [.tab], phases: .down) { keyPress in
            guard !isShowingSmartPreview else { return .ignored }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                cycleMode(reverse: keyPress.modifiers.contains(.shift))
            }
            return .handled
        }
    }

    @ViewBuilder
    private var trailingSection: some View {
        HStack(spacing: 8) {
            if isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 34, height: 34)
                    .transition(.opacity.combined(with: .scale))
            } else if let errorMessage = feedback.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.red)
                    .lineLimit(1)
                    .transition(.opacity)
            } else {
                if supportsStepping {
                    if currentFieldIndex > 0 {
                        Button(action: moveToPreviousField) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Previous field")
                        .help("Previous field")
                    }

                    Text("\(currentFieldIndex + 1)/\(payloadBuffer.count)")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }

                Button(action: advanceOrSave) {
                    HStack(spacing: 5) {
                        if isSkippingOptionalField && canMoveForward {
                            Text("Skip")
                                .font(.caption.weight(.medium))
                        }
                        Image(systemName: canMoveForward ? "arrow.right" : "return")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 18, height: 18)
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 9))
                .controlSize(.small)
                .tint(appAccentColor)
                .disabled(!canAdvance)
                .accessibilityLabel(
                    isSkippingOptionalField && canMoveForward
                        ? "Skip optional field"
                        : (canMoveForward ? "Next field" : "Save shard")
                )
                .help(
                    isSkippingOptionalField && canMoveForward
                        ? "Skip optional field (Return)"
                        : (canMoveForward ? "Next field (Return)" : "Submit (Return)")
                )
            }
        }
    }

    private var modeTitle: String {
        switch selectedMode {
        case .smart:
            return hasLLMConfigured ? "Smart" : "Smart requires endpoint, token, and model"
        case .template:
            return selectedTemplate?.name ?? "Template"
        }
    }

    private var modeSymbol: String {
        switch selectedMode {
        case .smart:
            return "sparkles"
        case .template:
            return selectedTemplate?.symbol ?? "square.grid.2x2"
        }
    }

    private var placeholderText: String {
        if let placeholder = currentField?.placeholder, !placeholder.isEmpty {
            return placeholder
        }
        let fieldName = currentField?.name ?? "Content"
        return "\(modeDisplayName) · \(fieldName)"
    }

    private var modeDisplayName: String {
        switch selectedMode {
        case .smart:
            return "Smart"
        case .template:
            return selectedTemplate?.name ?? "Template"
        }
    }

    private var canAdvance: Bool {
        if case .blocked = submissionOutcome { return false }
        return true
    }

    private var canMoveForward: Bool {
        if case .advance = submissionOutcome { return true }
        return false
    }

    private var isSkippingOptionalField: Bool {
        switch submissionOutcome {
        case let .advance(_, skipped), let .save(skipped):
            return skipped
        case .blocked:
            return false
        }
    }

    private var submissionOutcome: QuickEntrySubmissionOutcome {
        QuickEntryFormPolicy.submissionOutcome(
            field: currentField,
            input: inputText,
            currentIndex: currentFieldIndex,
            fieldCount: payloadBuffer.count
        )
    }

    private func initializeFlow(forceDefault: Bool) {
        cancelSmartRequest()
        isCompletingCapture = false
        isProcessing = false
        smartPreview = nil
        feedback = .none
        modeDrafts = [:]
        updateQuickEntryPanelSize(animated: false)

        guard !templates.isEmpty else {
            payloadBuffer = []
            return
        }

        let targetMode = resolveMode(from: forceDefault ? defaultQuickEntryMode : storedSelectedMode)
        apply(mode: targetMode)
    }

    private func resolveMode(from storedValue: String) -> QuickEntryMode {
        if storedValue == "smart", hasLLMConfigured {
            return .smart
        }

        if let template = resolveTemplate(from: storedValue) {
            return .template(template.id)
        }

        if let shardTemplate = templates.first(where: { $0.name.caseInsensitiveCompare("Shard") == .orderedSame }) {
            return .template(shardTemplate.id)
        }

        guard let fallback = templates.first else { return .smart }
        return .template(fallback.id)
    }

    private func resolveTemplate(from storedValue: String) -> PresetTemplate? {
        guard storedValue.hasPrefix("template:") else { return nil }
        let token = String(storedValue.dropFirst("template:".count))
        return templates.first(where: {
            $0.id == token || $0.name.caseInsensitiveCompare(token) == .orderedSame
        })
    }

    private func apply(mode: QuickEntryMode) {
        switch mode {
        case .smart:
            selectSmartMode()
        case let .template(templateID):
            guard let template = templates.first(where: { $0.id == templateID }) else { return }
            select(template: template)
        }
    }

    private func select(template: PresetTemplate, seedText: String? = nil) {
        smartPreview = nil
        selectedMode = .template(template.id)
        storedSelectedMode = "template:\(template.id)"
        let mode = QuickEntryMode.template(template.id)
        if let draft = modeDrafts[mode], !draft.fields.isEmpty {
            payloadBuffer = draft.fields
            currentFieldIndex = min(draft.currentFieldIndex, draft.fields.count - 1)
        } else {
            payloadBuffer = template.fields.isEmpty
                ? [PresetField(name: "Content", value: "", isRequired: true)]
                : template.fields
            if let seedText, !seedText.isEmpty, !payloadBuffer.isEmpty {
                payloadBuffer[0].value = seedText
            }
            currentFieldIndex = 0
        }
        inputText = payloadBuffer.indices.contains(currentFieldIndex)
            ? payloadBuffer[currentFieldIndex].value
            : ""
        feedback = .none
        requestInputFocus()
    }

    private func selectSmartMode(seedText: String? = nil) {
        guard hasLLMConfigured else {
            apply(mode: resolveMode(from: defaultQuickEntryMode))
            return
        }

        smartPreview = nil
        selectedMode = .smart
        storedSelectedMode = "smart"
        if let draft = modeDrafts[.smart], !draft.fields.isEmpty {
            payloadBuffer = draft.fields
            currentFieldIndex = min(draft.currentFieldIndex, draft.fields.count - 1)
            inputText = payloadBuffer[currentFieldIndex].value
        } else {
            payloadBuffer = [PresetField(name: "Content", value: seedText ?? "", isRequired: true)]
            currentFieldIndex = 0
            inputText = seedText ?? ""
        }
        feedback = .none
        requestInputFocus()
    }

    private func isSecureField(_ field: PresetField) -> Bool {
        field.isEffectivelySensitive
    }

    private func cycleMode(reverse: Bool) {
        guard !isProcessing, !isCompletingCapture else { return }
        guard let nextMode = QuickEntryModeCycle.next(
            from: selectedMode,
            in: availableModes,
            reverse: reverse
        ) else { return }

        switchMode(to: nextMode)
    }

    private func switchMode(to mode: QuickEntryMode) {
        guard mode != selectedMode else { return }
        // Never carry a credential into an unrelated mode's ordinary text
        // field. The source mode's complete draft is still cached below.
        let seedText = QuickEntryModeTransferPolicy.seedText(
            from: inputText,
            sourceField: currentField
        )
        cacheCurrentModeDraft()

        switch mode {
        case .smart:
            selectSmartMode(seedText: seedText)
        case let .template(templateID):
            guard let template = templates.first(where: { $0.id == templateID }) else { return }
            select(template: template, seedText: seedText)
        }
    }

    private func cacheCurrentModeDraft() {
        guard !payloadBuffer.isEmpty else { return }
        var fields = payloadBuffer
        if fields.indices.contains(currentFieldIndex) {
            fields[currentFieldIndex].value = inputText
        }
        modeDrafts[selectedMode] = QuickEntryModeDraft(
            fields: fields,
            currentFieldIndex: currentFieldIndex
        )
    }

    private func moveToPreviousField() {
        guard currentFieldIndex > 0 else { return }
        payloadBuffer[currentFieldIndex].value = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        currentFieldIndex -= 1
        inputText = payloadBuffer[currentFieldIndex].value
        requestInputFocus()
    }

    private func moveToNextField(_ nextIndex: Int) {
        guard payloadBuffer.indices.contains(nextIndex) else { return }
        currentFieldIndex = nextIndex
        inputText = payloadBuffer[currentFieldIndex].value
        requestInputFocus()
    }

    private func advanceOrSave() {
        guard !isProcessing, !isCompletingCapture, currentField != nil else { return }
        switch submissionOutcome {
        case let .blocked(requiredFieldName):
            feedback = .error("\(requiredFieldName) is required")
        case let .advance(nextIndex, _):
            payloadBuffer[currentFieldIndex].value = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            withAnimation(interfaceAnimation) {
                moveToNextField(nextIndex)
            }
        case .save:
            payloadBuffer[currentFieldIndex].value = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            saveToVault()
        }
    }

    private func saveToVault() {
        let encryptionMode = ProtectionService.shared.desiredEncryptionModeForNewShard()
        if encryptionMode == .global, ProtectionService.shared.requiresGlobalUnlock {
            feedback = .error("Unlock vault to save")
            isProcessing = false
            return
        }

        isProcessing = true

        switch selectedMode {
        case .smart:
            guard hasLLMConfigured else {
                initializeFlow(forceDefault: true)
                isProcessing = false
                return
            }

            let userText = payloadBuffer.first?.value ?? inputText
            let templateDescriptors = templates.map(\.smartDescriptor)
            let configuration = smartConfiguration
            smartRequestGeneration &+= 1
            let requestGeneration = smartRequestGeneration
            smartRequestTask?.cancel()
            smartRequestTask = Task {
                do {
                    let result = try await SmartInputService.shared.process(
                        rawInput: userText,
                        templates: templateDescriptors,
                        configuration: configuration
                    )
                    try Task.checkCancellation()
                    guard requestGeneration == smartRequestGeneration else { return }
                    smartRequestTask = nil
                    presentSmartPreview(result: result, rawInput: userText)
                } catch {
                    guard requestGeneration == smartRequestGeneration else { return }
                    smartRequestTask = nil
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        isProcessing = false
                        return
                    }
                    feedback = .error(smartFailureStatusText(for: error))
                    isProcessing = false
                }
            }

        case .template:
            let template = selectedTemplate
            let templateName = template?.name
            let payload = PresetPayload(
                presetType: templateName ?? "Shard",
                fields: payloadBuffer,
                templateID: template?.id
            )
            finishSave(with: payload, templateName: templateName)
        }
    }

    private func presentSmartPreview(result: SmartInputResult, rawInput: String) {
        let matchedTemplate = previewTemplate(for: result)
        let previewFields = matchedTemplate.map {
            rebuildPreviewFields(for: $0, existingFields: result.payload.fields, rawContent: rawInput)
        } ?? []

        smartPreview = SmartPreviewState(
            sourceText: rawInput,
            rawContent: rawInput,
            selectedTemplateID: matchedTemplate?.id,
            fields: previewFields
        )
        feedback = .none
        isProcessing = false
        isInputFocused = false
    }

    private func dismissSmartPreview() {
        smartPreview = nil
        feedback = .none
        isProcessing = false
        requestInputFocus()
    }

    private func cancelSmartRequest() {
        smartRequestGeneration &+= 1
        smartRequestTask?.cancel()
        smartRequestTask = nil
        isProcessing = false
    }

    private func saveSmartPreview() {
        guard !isProcessing, !isCompletingCapture, let preview = smartPreview else { return }

        let encryptionMode = ProtectionService.shared.desiredEncryptionModeForNewShard()
        if encryptionMode == .global, ProtectionService.shared.requiresGlobalUnlock {
            feedback = .error("Unlock vault to save")
            isProcessing = false
            return
        }

        isProcessing = true

        if let template = currentPreviewTemplate {
            let payload = PresetPayload(
                presetType: template.name,
                fields: preview.fields,
                preferredStyle: template.presentationStyle.rawValue,
                templateID: template.id
            )
            finishSave(with: payload, templateName: template.name)
        } else {
            finishSave(with: .raw(preview.rawContent), templateName: nil)
        }
    }

    private func finishSave(with payload: PresetPayload, templateName: String?) {
        let encryptionMode = ProtectionService.shared.desiredEncryptionModeForNewShard()
        let matchedTemplate = templates.matchingTemplate(for: payload) ?? templateName.flatMap { name in
            templates.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        }

        do {
            let context = VaultContainer.shared.container.mainContext
            let collections = try context.fetch(FetchDescriptor<ShardCollection>())
            let collectionId = matchedTemplate
                .flatMap { template in
                    collections.first(where: {
                        $0.name.caseInsensitiveCompare(template.targetCollectionName) == .orderedSame
                    })?.id
                }
                ?? collections.first(where: { $0.name == VaultContainer.Defaults.shardsCollectionName })?.id
                ?? VaultContainer.Defaults.allCollectionID
            let shard = try VaultRepository.shared.save(
                payload: payload,
                collectionId: collectionId,
                tagIds: [],
                encryptionMode: encryptionMode
            )

            isProcessing = false
            isCompletingCapture = true
            actions.captureCompleted(shard)

        } catch {
            if let repositoryError = error as? VaultRepositoryError,
               case .storeUnavailable = repositoryError {
                feedback = .error("Vault unavailable")
            } else {
                feedback = .error("Save failed")
            }
            isProcessing = false
        }
    }

    private func smartFailureStatusText(for error: Error) -> String {
        if let smartError = error as? SmartInputError {
            return smartError.quickEntryStatusText
        }
        if error is URLError {
            return "Fail: Network error"
        }
        return "Smart Parse Failed"
    }

    private func previewFieldBinding(fieldID: String) -> Binding<String> {
        Binding(
            get: { smartPreview?.fields.first(where: { $0.id == fieldID })?.value ?? "" },
            set: { newValue in
                guard var preview = smartPreview,
                      let index = preview.fields.firstIndex(where: { $0.id == fieldID }) else { return }
                preview.fields[index].value = newValue
                smartPreview = preview
            }
        )
    }

    private func applySmartPreviewTemplateSelection(_ selection: String) {
        guard var preview = smartPreview else { return }
        let previousTemplate = currentPreviewTemplate

        if selection == QuickEntryLayout.rawSelectionToken {
            if let previousTemplate {
                let suggestedRawContent = preferredRawContent(from: preview.fields, template: previousTemplate)
                if !suggestedRawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    preview.rawContent = suggestedRawContent
                }
            }
            preview.selectedTemplateID = nil
        } else if let template = templates.first(where: { $0.id == selection }) {
            preview.selectedTemplateID = template.id
            preview.fields = rebuildPreviewFields(for: template, existingFields: preview.fields, rawContent: preview.rawContent)
        }

        smartPreview = preview
    }

    private func previewTemplate(for result: SmartInputResult) -> PresetTemplate? {
        if let matchedTemplate = templates.matchingTemplate(for: result.payload) {
            return matchedTemplate
        }
        if let templateName = result.templateName,
           let matchedTemplate = templates.first(where: { $0.name.caseInsensitiveCompare(templateName) == .orderedSame }) {
            return matchedTemplate
        }

        guard !result.payload.isRaw else { return nil }
        return templates.first(where: { $0.name.caseInsensitiveCompare(result.payload.presetType) == .orderedSame })
    }

    private func rebuildPreviewFields(
        for template: PresetTemplate,
        existingFields: [PresetField],
        rawContent: String
    ) -> [PresetField] {
        var rebuiltFields = template.fields
        guard !rebuiltFields.isEmpty else {
            return [PresetField(name: "Content", value: rawContent, isRequired: true)]
        }

        let existingValueMap = existingFields.reduce(into: [String: String]()) { partialResult, field in
            partialResult[normalizeFieldToken(field.name)] = field.value
            if let key = field.key, !key.isEmpty {
                partialResult[normalizeFieldToken(key)] = field.value
            }
        }

        for index in rebuiltFields.indices {
            let definition = template.schema.fields[index]
            let lookupKeys = [
                normalizeFieldToken(definition.key),
                normalizeFieldToken(definition.name),
                normalizeFieldToken(rebuiltFields[index].name)
            ]

            if let mappedValue = lookupKeys.compactMap({ existingValueMap[$0] }).first {
                rebuiltFields[index].value = mappedValue
            }
        }

        if let noteIndex = noteFieldIndex(in: template), rebuiltFields[noteIndex].trimmedValue.isEmpty {
            rebuiltFields[noteIndex].value = rawContent
        }

        if rebuiltFields.allSatisfy({ $0.trimmedValue.isEmpty }), let firstIndex = rebuiltFields.indices.first {
            rebuiltFields[firstIndex].value = rawContent
        }

        return rebuiltFields
    }

    private func preferredRawContent(from fields: [PresetField], template: PresetTemplate) -> String {
        if let noteIndex = noteFieldIndex(in: template) {
            let noteValue = fields.indices.contains(noteIndex) ? fields[noteIndex].trimmedValue : ""
            if !noteValue.isEmpty {
                return noteValue
            }
        }

        let joinedFields = fields
            .map(\.trimmedValue)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return joinedFields
    }

    private func noteFieldIndex(in template: PresetTemplate) -> Int? {
        template.schema.fields.firstIndex { definition in
            definition.valueType == .note || ["content", "body", "text", "note"].contains(normalizeFieldToken(definition.key))
        }
    }

    private func normalizeFieldToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    private func targetCollectionName(for template: PresetTemplate?) -> String {
        guard let template, !template.targetCollectionName.isEmpty else {
            return VaultContainer.Defaults.shardsCollectionName
        }
        return template.targetCollectionName
    }

    private func updateQuickEntryPanelSize(animated: Bool) {
        let targetSize = isShowingSmartPreview ? QuickEntryPanelMetrics.previewSize : QuickEntryPanelMetrics.compactSize
        DispatchQueue.main.async {
            guard let panel = NSApp.windows.compactMap({ $0 as? QuickEntryPanel }).first else { return }
            let currentFrame = panel.frame
            let newFrame = NSRect(
                x: currentFrame.midX - targetSize.width / 2,
                y: currentFrame.midY - targetSize.height / 2,
                width: targetSize.width,
                height: targetSize.height
            )

            guard animated, !reduceMotion else {
                panel.setFrame(newFrame, display: true)
                return
            }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        }
    }

    private func requestInputFocus() {
        DispatchQueue.main.async {
            isInputFocused = true
        }
    }
}
