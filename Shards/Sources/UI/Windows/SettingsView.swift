import Foundation
import KeyboardShortcuts
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general
    @AppStorage("custom_accent_hex") private var customAccentHex = ""

    enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
        case general = "General"
        case editor = "Editor"
        case appearance = "Appearance"
        case management = "Management"
        case advanced = "Advanced"
        case diagnostics = "Diagnostics"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .editor: return "doc.richtext"
            case .appearance: return "paintbrush"
            case .management: return "slider.horizontal.3"
            case .advanced: return "wrench.and.screwdriver"
            case .diagnostics: return "stethoscope"
            }
        }

        var summary: String {
            switch self {
            case .general:
                return "Shortcuts and how Shards appears on your Mac."
            case .editor:
                return "Writing behavior, save feedback, and useful statistics."
            case .appearance:
                return "Color, background, typography, and list density."
            case .management:
                return "Capture defaults, menu bar behavior, and tags."
            case .advanced:
                return "Protection, Smart Mode, templates, and vault data."
            case .diagnostics:
                return "Storage, backups, updates, and troubleshooting details."
            }
        }
    }

    private var appAccentColor: Color {
        Color(hex: customAccentHex) ?? Color(red: 79 / 255, green: 70 / 255, blue: 229 / 255)
    }

    var body: some View {
        ZStack {
            AppBackgroundView()
                .ignoresSafeArea()

            HStack(spacing: 0) {
                SettingsSidebar(
                    selection: $selectedTab,
                    accentColor: appAccentColor
                )

                Rectangle()
                    .fill(.separator.opacity(0.55))
                    .frame(width: 1)

                settingsDetail
            }
        }
        .frame(minWidth: 780, idealWidth: 820, minHeight: 590, idealHeight: 640)
    }

    private var settingsDetail: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                SettingsPageHeader(
                    title: selectedTab.rawValue,
                    summary: selectedTab.summary,
                    icon: selectedTab.icon,
                    accentColor: appAccentColor
                )

                switch selectedTab {
                case .general: GeneralSettingsView()
                case .editor: EditorSettingsView()
                case .appearance: PersonalizationSettingsView()
                case .management: ManagementSettingsView()
                case .advanced: AdvancedSettingsView()
                case .diagnostics: DiagnosticsSettingsView()
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 30)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.18))
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @AppStorage("hide_dock_icon") private var hideDockIcon = false

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(
                "Quick Entry",
                icon: "bolt.fill",
                summary: "Capture a thought without leaving your current app."
            ) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Global shortcut")
                            .font(.body.weight(.medium))
                        Text("Works anywhere on your Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    KeyboardShortcuts.Recorder(for: .toggleQuickEntry)
                        .fixedSize()
                }
            }

            SettingsCard("Keyboard Shortcuts", icon: "command") {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    shortcutRow("⌘S", "Save current shard")
                    shortcutRow("⌘⇧P", "Pin / Unpin")
                    shortcutRow("⌘⌫", "Move to Trash")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsCard(
                "App Presence",
                icon: "dock.rectangle",
                summary: "Choose whether Shards also appears in the Dock."
            ) {
                Toggle("Hide Dock icon", isOn: $hideDockIcon)
                SettingsNote(text: "When hidden, the main window remains available from the menu bar and Quick Entry shortcut.")
            }

            SettingsCard(
                "About Shards",
                icon: "info.circle",
                summary: "Version details to include when reporting an issue."
            ) {
                VStack(spacing: 12) {
                    LabeledContent("Version") {
                        Text(AppBuildInfo.version)
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }

                    Divider()

                    LabeledContent("Build") {
                        Text(AppBuildInfo.build)
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }

                    Divider()

                    LabeledContent("Git Commit") {
                        HStack(spacing: 8) {
                            Text(AppBuildInfo.gitCommit)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)

                            if AppBuildInfo.hasLocalChanges {
                                Text("Modified")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.orange.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }
            }

            SoftwareUpdateSettingsCard()
        }
    }

    private func shortcutRow(_ keys: String, _ desc: String) -> some View {
        GridRow {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
            Text(desc)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Editor

private struct EditorSettingsView: View {
    @AppStorage("editor_stats_items") private var editorStatsItems = "words,characters"
    @AppStorage("editor_show_status_bar") private var showStatusBar = true

    private let allStats: [(key: String, label: String)] = [
        ("words", "Words"),
        ("characters", "Characters"),
        ("sentences", "Sentences"),
        ("paragraphs", "Paragraphs")
    ]

    private var selectedStats: Set<String> {
        Set(editorStatsItems.split(separator: ",").map(String.init))
    }

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(
                "Editor Feedback",
                icon: "rectangle.bottomthird.inset.filled",
                summary: "Keep save state and writing statistics close to the editor."
            ) {
                Toggle("Show editor status bar", isOn: $showStatusBar)
                SettingsNote(text: "The compact bar shows the selected statistics and whether the current shard is saved.")
            }

            SettingsCard(
                "Statistics",
                icon: "textformat.123",
                summary: "Choose between one and four measurements."
            ) {
                if showStatusBar {
                    ForEach(allStats, id: \.key) { stat in
                        Toggle(stat.label, isOn: Binding(
                            get: { selectedStats.contains(stat.key) },
                            set: { enabled in
                                var items = selectedStats
                                if enabled {
                                    guard items.count < 4 else { return }
                                    items.insert(stat.key)
                                } else {
                                    guard items.count > 1 else { return }
                                    items.remove(stat.key)
                                }
                                editorStatsItems = allStats.map(\.key).filter { items.contains($0) }.joined(separator: ",")
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                } else {
                    ContentUnavailableView(
                        "Status Bar Hidden",
                        systemImage: "rectangle.slash",
                        description: Text("Turn on the editor status bar to choose statistics.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }

            SettingsCard("Auto-Save", icon: "checkmark.arrow.trianglehead.counterclockwise") {
                SettingsNote(text: "Changes are saved 1.5 seconds after your last edit. Press ⌘S to save immediately.")
            }
        }
    }
}

// MARK: - Management

private struct ManagementSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query(sort: \PresetTemplate.orderIndex) private var templates: [PresetTemplate]

    @AppStorage("default_quick_entry_mode") private var defaultQuickEntryMode = "template:shard"
    @AppStorage("status_bar_double_click_add_tags") private var statusBarDoubleClickAddTags = true
    @AppStorage("status_bar_double_click_tag_ids") private var statusBarDoubleClickTagIDs = ""

    @State private var newTagName = ""
    @State private var newTagColor = "#4F46E5"
    @State private var newTagSymbol = "tag.fill"
    @State private var selectedTemplateId: String?
    @State private var pendingImportedTemplate: PresetTemplate?
    @State private var showReplaceAlert = false
    @State private var importErrorMessage: String?

    private let hiddenTagNames = ["Password", "Token"]

    private var editableTags: [Tag] {
        tags.filter { !hiddenTagNames.contains($0.name) }
    }

    private var doubleClickTagIDSet: Set<String> {
        Set(statusBarDoubleClickTagIDs.split(separator: ",").map(String.init))
    }

    private var selectedTemplate: PresetTemplate? {
        guard let selectedTemplateId else { return nil }
        return templates.first(where: { $0.id == selectedTemplateId })
    }

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(
                "Capture Default",
                icon: "bolt.horizontal.fill",
                summary: "Choose the template selected when Quick Entry opens."
            ) {
                Picker("Default Mode", selection: $defaultQuickEntryMode) {
                    ForEach(templates, id: \.id) { template in
                        Text(template.name).tag("template:\(template.id)" as String)
                    }
                }
            }

            SettingsCard(
                "Menu Bar Capture",
                icon: "menubar.rectangle",
                summary: "Apply useful tags when saving clipboard content from the menu bar."
            ) {
                Toggle("Auto-attach tags when saving from menu bar", isOn: $statusBarDoubleClickAddTags)

                if statusBarDoubleClickAddTags && !editableTags.isEmpty {
                    Divider()
                    ForEach(editableTags) { tag in
                        Toggle(isOn: Binding(
                            get: { doubleClickTagIDSet.contains(tag.id) },
                            set: { updateDoubleClickTag(tagID: tag.id, isEnabled: $0) }
                        )) {
                            Label(tag.name, systemImage: tag.symbol)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            SettingsCard(
                "Tags",
                icon: "tag.fill",
                summary: "Rename, recolor, or add labels used across the vault."
            ) {
                ForEach(editableTags) { tag in
                    HStack(spacing: 10) {
                        SymbolPickerButton(symbol: Binding(
                            get: { tag.symbol },
                            set: { tag.symbol = $0; try? context.save() }
                        ), color: Color(hex: tag.colorHex) ?? .secondary)

                        TextField("Name", text: Binding(
                            get: { tag.name },
                            set: { tag.name = $0; try? context.save() }
                        ))
                        .frame(maxWidth: .infinity)

                        ColorPicker("", selection: Binding(
                            get: { Color(hex: tag.colorHex) ?? .blue },
                            set: { tag.colorHex = $0.toHex() ?? tag.colorHex; try? context.save() }
                        ))
                        .labelsHidden()

                        if !tag.isSystem {
                            Button(role: .destructive) { delete(tag: tag) } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.red.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if tag.id != editableTags.last?.id {
                        Divider()
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    SymbolPickerButton(symbol: $newTagSymbol, color: Color(hex: newTagColor) ?? .blue)

                    TextField("New tag name…", text: $newTagName)
                        .frame(maxWidth: .infinity)
                        .onSubmit { addTag() }

                    ColorPicker("", selection: Binding(
                        get: { Color(hex: newTagColor) ?? .blue },
                        set: { newTagColor = $0.toHex() ?? newTagColor }
                    ))
                    .labelsHidden()

                    Button { addTag() } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            seedStatusBarTagsIfNeeded()
        }
        .alert("Replace Existing Template?", isPresented: $showReplaceAlert, presenting: pendingImportedTemplate) { pending in
            Button("Replace", role: .destructive) { replaceExistingTemplate(with: pending) }
            Button("Cancel", role: .cancel) { pendingImportedTemplate = nil }
        } message: { pending in
            Text("A template named \(pending.name) already exists. Replace it with the pasted version?")
        }
    }

    private func seedStatusBarTagsIfNeeded() {
        guard statusBarDoubleClickTagIDs.isEmpty,
              let clipboardTag = editableTags.first(where: { $0.name.caseInsensitiveCompare(VaultContainer.Defaults.clipboardTagName) == .orderedSame })
        else { return }
        statusBarDoubleClickTagIDs = clipboardTag.id
    }

    private func updateDoubleClickTag(tagID: String, isEnabled: Bool) {
        var ids = doubleClickTagIDSet
        if isEnabled { ids.insert(tagID) } else { ids.remove(tagID) }
        statusBarDoubleClickTagIDs = ids.sorted().joined(separator: ",")
    }

    private func addTag() {
        let trimmedName = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let trimmedSymbol = newTagSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = Tag(name: trimmedName, colorHex: newTagColor, symbol: trimmedSymbol.isEmpty ? "tag.fill" : trimmedSymbol)
        context.insert(tag)
        try? context.save()
        newTagName = ""
        newTagColor = "#4F46E5"
        newTagSymbol = "tag.fill"
    }

    private func delete(tag: Tag) {
        guard !tag.isSystem else { return }
        let shards = (try? context.fetch(FetchDescriptor<Shard>())) ?? []
        for shard in shards where shard.tagIds.contains(tag.id) {
            shard.tagIds.removeAll(where: { $0 == tag.id })
        }
        var ids = doubleClickTagIDSet
        ids.remove(tag.id)
        statusBarDoubleClickTagIDs = ids.sorted().joined(separator: ",")
        context.delete(tag)
        try? context.save()
    }

    private func replaceExistingTemplate(with pending: PresetTemplate) {
        if let existing = templates.first(where: { $0.name.caseInsensitiveCompare(pending.name) == .orderedSame }) {
            existing.symbol = pending.symbol
            existing.targetCollectionName = pending.targetCollectionName
            existing.schemaFieldsJSON = pending.schemaFieldsJSON
            try? context.save()
            selectedTemplateId = existing.id
        }
        pendingImportedTemplate = nil
    }
}

// MARK: - Advanced (Intelligence + Data + Templates)

private struct AdvancedSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var shards: [Shard]
    @Query private var tags: [Tag]
    @Query(sort: \PresetTemplate.orderIndex) private var templates: [PresetTemplate]
    @Query private var collections: [ShardCollection]

    @AppStorage(AppSettingKeys.llmEndpointURL) private var llmEndpointURL = ""
    @AppStorage(AppSettingKeys.llmAPIToken) private var llmToken = ""
    @AppStorage(AppSettingKeys.llmRequestFormat) private var llmFormat = "openai"
    @AppStorage(AppSettingKeys.llmModelName) private var llmModelName = ""

    @StateObject private var protection = ProtectionService.shared
    @State private var feedbackMessage: String?
    @State private var feedbackIsError = false
    @State private var selectedTemplateId: String?
    @State private var globalPassword = ""
    @State private var confirmGlobalPassword = ""
    @State private var unlockPassword = ""
    @State private var disablePassword = ""
    @State private var isConfirmingEmptyTrash = false

    private var selectedTemplate: PresetTemplate? {
        guard let selectedTemplateId else { return nil }
        return templates.first(where: { $0.id == selectedTemplateId })
    }

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(
                "Vault Protection",
                icon: "lock.shield.fill",
                summary: "Protect stored content with one vault password."
            ) {
                if protection.globalProtectionEnabled {
                    HStack {
                        Label(
                            protection.globalUnlocked ? "Vault unlocked" : "Vault locked",
                            systemImage: protection.globalUnlocked ? "lock.open.fill" : "lock.fill"
                        )
                        .foregroundStyle(protection.globalUnlocked ? .green : .orange)

                        Spacer()

                        if protection.globalUnlocked {
                            Button("Lock Now") {
                                protection.lockGlobalSession()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if !protection.globalUnlocked {
                        SecureField("Unlock password", text: $unlockPassword)
                            .textFieldStyle(.roundedBorder)

                        Button("Unlock Vault") {
                            unlockGlobalProtection()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(unlockPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Divider()

                    SecureField("Current password to disable global protection", text: $disablePassword)
                        .textFieldStyle(.roundedBorder)

                    Button("Disable Global Protection") {
                        disableGlobalProtection()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(disablePassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    SecureField("New global password", text: $globalPassword)
                        .textFieldStyle(.roundedBorder)

                    SecureField("Confirm global password", text: $confirmGlobalPassword)
                        .textFieldStyle(.roundedBorder)

                    Button("Enable Global Protection") {
                        enableGlobalProtection()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(
                        globalPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        confirmGlobalPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

                SettingsNote(text: "Global protection encrypts non-protected shards and locks the vault when Shards leaves the foreground.")

                if let feedbackMessage {
                    Text(feedbackMessage)
                        .font(.caption)
                        .foregroundStyle(feedbackIsError ? .red : .green)
                }
            }

            SettingsCard(
                "Smart Mode",
                icon: "sparkles",
                summary: "Connect an OpenAI-, Anthropic-, or Gemini-compatible endpoint."
            ) {
                LabeledContent("Endpoint") {
                    TextField("https://api.example.com/v1", text: $llmEndpointURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                }

                LabeledContent("API Token") {
                    SecureField("Required by your provider", text: $llmToken)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                }

                LabeledContent("Model") {
                    TextField("Model name", text: $llmModelName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                }

                Picker("Request Format", selection: $llmFormat) {
                    Text("OpenAI Compatible").tag("openai" as String)
                    Text("Anthropic Compatible").tag("anthropic" as String)
                    Text("Gemini Compatible").tag("gemini" as String)
                }

                SettingsNote(text: "Smart Mode sends only the current Quick Entry draft using the selected provider format.")
            }

            SettingsCard(
                "Templates",
                icon: "square.grid.2x2.fill",
                summary: "Templates define fields and destination collections for structured shards."
            ) {
                ForEach(templates) { template in
                    HStack(spacing: 10) {
                        Image(systemName: template.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)

                        Text(template.name)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(template.targetCollectionName.isEmpty ? "—" : template.targetCollectionName)
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        if template.name.caseInsensitiveCompare("Shard") != .orderedSame || templates.count > 1 {
                            Button(role: .destructive) { deleteTemplate(template) } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.red.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if template.id != templates.last?.id {
                        Divider()
                    }
                }

                Button("Import Template from Clipboard") {
                    importTemplate()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let feedbackMessage, !feedbackIsError {
                    Text(feedbackMessage)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let feedbackMessage, feedbackIsError {
                    Text(feedbackMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            SettingsCard(
                "Vault Data",
                icon: "externaldrive.fill",
                summary: "Review the vault at a glance, or move a copy between devices."
            ) {
                Grid(horizontalSpacing: 24, verticalSpacing: 4) {
                    GridRow {
                        statCell(value: shards.filter { $0.deletedAt == nil }.count, label: "Active")
                        statCell(value: shards.filter { $0.deletedAt != nil }.count, label: "Trashed")
                        statCell(value: tags.count, label: "Tags")
                        statCell(value: templates.count, label: "Templates")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)

                Divider()

                HStack(spacing: 12) {
                    Button("Export JSON…") { exportJSON() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Export CSV…") { exportCSV() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Import JSON or Backup…") { importJSON() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            SettingsCard(
                "Danger Zone",
                icon: "trash.fill",
                summary: "Permanent actions require confirmation."
            ) {
                Button("Empty Trash") {
                    isConfirmingEmptyTrash = true
                }
                .foregroundStyle(.red)
                .disabled(shards.filter { $0.deletedAt != nil }.isEmpty)
            }
        }
        .onAppear {
            protection.refreshConfiguration()
        }
        .confirmationDialog(
            "Permanently delete every shard in Trash?",
            isPresented: $isConfirmingEmptyTrash
        ) {
            Button("Empty Trash", role: .destructive, action: emptyTrash)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func emptyTrash() {
        let trashed = shards.filter { $0.deletedAt != nil }
        guard !trashed.isEmpty else { return }
        for shard in trashed {
            context.delete(shard)
        }
        try? context.save()
        feedbackMessage = "Permanently deleted \(trashed.count) shard(s)."
        feedbackIsError = false
    }

    private func enableGlobalProtection() {
        feedbackMessage = nil
        let normalized = globalPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized == confirmGlobalPassword.trimmingCharacters(in: .whitespacesAndNewlines) else {
            feedbackMessage = "The passwords do not match."
            feedbackIsError = true
            return
        }

        do {
            try protection.enableGlobalProtection(password: normalized, context: context)
            globalPassword = ""
            confirmGlobalPassword = ""
            feedbackMessage = "Global protection enabled."
            feedbackIsError = false
        } catch {
            feedbackMessage = error.localizedDescription
            feedbackIsError = true
        }
    }

    private func unlockGlobalProtection() {
        feedbackMessage = nil
        do {
            try protection.unlockGlobal(password: unlockPassword)
            unlockPassword = ""
            feedbackMessage = "Vault unlocked."
            feedbackIsError = false
        } catch {
            feedbackMessage = error.localizedDescription
            feedbackIsError = true
        }
    }

    private func disableGlobalProtection() {
        feedbackMessage = nil
        do {
            try protection.disableGlobalProtection(password: disablePassword, context: context)
            disablePassword = ""
            feedbackMessage = "Global protection disabled."
            feedbackIsError = false
        } catch {
            feedbackMessage = error.localizedDescription
            feedbackIsError = true
        }
    }

    private func statCell(value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func importTemplate() {
        feedbackMessage = nil
        let trimmed = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            feedbackMessage = "Clipboard is empty."
            feedbackIsError = true
            return
        }
        guard let data = trimmed.data(using: .utf8) else { return }
        do {
            let imported = try JSONDecoder().decode(ImportedTemplate.self, from: data)
            let nextIndex = (templates.map(\.orderIndex).max() ?? 0) + 1
            let template = imported.toPresetTemplate(orderIndex: nextIndex)
            if templates.contains(where: { $0.name.caseInsensitiveCompare(template.name) == .orderedSame }) {
                feedbackMessage = "Template '\(template.name)' already exists."
                feedbackIsError = true
            } else {
                context.insert(template)
                try? context.save()
                feedbackMessage = "Imported '\(template.name)' successfully."
                feedbackIsError = false
            }
        } catch {
            feedbackMessage = "Invalid template JSON format."
            feedbackIsError = true
        }
    }

    private func deleteTemplate(_ template: PresetTemplate) {
        context.delete(template)
        try? context.save()
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "shards_export.json"
        panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let exportData = ExportPackage(
                    shards: shards.map { ShardExport(shard: $0) },
                    tags: tags.map { TagExport(tag: $0) },
                    templates: templates.map { TemplateExport(template: $0) },
                    collections: collections.map { CollectionExport(collection: $0) },
                    exportedAt: Date()
                )
                let data = try JSONEncoder().encode(exportData)
                let formatted = try JSONSerialization.data(
                    withJSONObject: try JSONSerialization.jsonObject(with: data),
                    options: [.prettyPrinted, .sortedKeys]
                )
                try formatted.write(to: url)
                feedbackMessage = "Exported to \(url.lastPathComponent)"
                feedbackIsError = false
            } catch {
                feedbackMessage = "Export error: \(error.localizedDescription)"
                feedbackIsError = true
            }
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "shards_export.csv"
        panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) { response in
            guard response == .OK, let url = panel.url else { return }
            var csv = "ID,DisplayName,CollectionID,Tags,Payload,CreatedAt,UpdatedAt\n"
            let dateFormatter = ISO8601DateFormatter()
            for shard in shards {
                let name = (shard.displayName ?? "").replacingOccurrences(of: "\"", with: "\"\"")
                let payload = shard.payload.replacingOccurrences(of: "\"", with: "\"\"")
                let tagNames = tags.filter { shard.tagIds.contains($0.id) }.map(\.name).joined(separator: ";")
                csv += "\"\(shard.id)\",\"\(name)\",\"\(shard.collectionId ?? "")\",\"\(tagNames)\",\"\(payload)\",\"\(dateFormatter.string(from: shard.createdAt))\",\"\(dateFormatter.string(from: shard.updatedAt))\"\n"
            }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                feedbackMessage = "Exported CSV."
                feedbackIsError = false
            } catch {
                feedbackMessage = "CSV error: \(error.localizedDescription)"
                feedbackIsError = true
            }
        }
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        if let backupType = UTType(filenameExtension: "shardsbackup", conformingTo: .json) {
            panel.allowedContentTypes = [.json, backupType]
        } else {
            panel.allowedContentTypes = [.json]
        }
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let package = try JSONDecoder().decode(ExportPackage.self, from: data)
                var imported = 0
                var collectionIDMap: [String: String] = [:]
                var tagIDMap: [String: String] = [:]

                for collectionExport in package.collections {
                    if let existing = collections.first(where: { $0.id == collectionExport.id }) {
                        existing.name = collectionExport.name
                        existing.icon = collectionExport.icon
                        existing.parentId = collectionExport.parentId
                        collectionIDMap[collectionExport.id] = existing.id
                    } else if let existing = collections.first(where: { $0.name.caseInsensitiveCompare(collectionExport.name) == .orderedSame }) {
                        existing.icon = collectionExport.icon
                        existing.parentId = collectionExport.parentId
                        collectionIDMap[collectionExport.id] = existing.id
                    } else {
                        let collection = ShardCollection(
                            id: collectionExport.id,
                            parentId: collectionExport.parentId,
                            name: collectionExport.name,
                            icon: collectionExport.icon,
                            createdAt: collectionExport.createdAt
                        )
                        context.insert(collection)
                        collectionIDMap[collectionExport.id] = collection.id
                    }
                }

                for tagExport in package.tags {
                    if let existing = tags.first(where: { $0.id == tagExport.id }) {
                        existing.name = tagExport.name
                        existing.colorHex = tagExport.colorHex
                        existing.symbol = tagExport.symbol
                        existing.isSystem = tagExport.isSystem
                        tagIDMap[tagExport.id] = existing.id
                    } else if let existing = tags.first(where: { $0.name.caseInsensitiveCompare(tagExport.name) == .orderedSame }) {
                        existing.colorHex = tagExport.colorHex
                        existing.symbol = tagExport.symbol
                        existing.isSystem = tagExport.isSystem
                        tagIDMap[tagExport.id] = existing.id
                    } else {
                        let tag = Tag(
                            id: tagExport.id,
                            name: tagExport.name,
                            colorHex: tagExport.colorHex,
                            symbol: tagExport.symbol,
                            isSystem: tagExport.isSystem
                        )
                        context.insert(tag)
                        tagIDMap[tagExport.id] = tag.id
                    }
                }

                for templateExport in package.templates {
                    if let existing = templates.first(where: { $0.id == templateExport.id }) {
                        existing.name = templateExport.name
                        existing.symbol = templateExport.symbol
                        existing.targetCollectionName = templateExport.targetCollectionName
                        existing.targetTagName = templateExport.targetTagName
                        existing.schemaFieldsJSON = templateExport.schemaFieldsJSON
                        existing.orderIndex = templateExport.orderIndex
                    } else if let existing = templates.first(where: { $0.name.caseInsensitiveCompare(templateExport.name) == .orderedSame }) {
                        existing.symbol = templateExport.symbol
                        existing.targetCollectionName = templateExport.targetCollectionName
                        existing.targetTagName = templateExport.targetTagName
                        existing.schemaFieldsJSON = templateExport.schemaFieldsJSON
                        existing.orderIndex = templateExport.orderIndex
                    } else {
                        context.insert(
                            PresetTemplate(
                                id: templateExport.id,
                                name: templateExport.name,
                                symbol: templateExport.symbol,
                                targetCollectionName: templateExport.targetCollectionName,
                                targetTagName: templateExport.targetTagName,
                                schemaFieldsJSON: templateExport.schemaFieldsJSON,
                                orderIndex: templateExport.orderIndex
                            )
                        )
                    }
                }

                for shardExport in package.shards {
                    let mappedCollectionId = shardExport.collectionId.flatMap { collectionIDMap[$0] ?? $0 }
                    let mappedTagIds = shardExport.tagIds.map { tagIDMap[$0] ?? $0 }

                    if let existing = shards.first(where: { $0.id == shardExport.id }) {
                        existing.collectionId = mappedCollectionId
                        existing.tagIds = mappedTagIds
                        existing.encryptionMode = EncryptionMode(rawValue: shardExport.encryptionMode) ?? .none
                        existing.isPinned = shardExport.isPinned
                        existing.displayName = shardExport.displayName
                        existing.deletedAt = shardExport.deletedAt
                        existing.payload = shardExport.payload
                        existing.createdAt = shardExport.createdAt
                        existing.updatedAt = shardExport.updatedAt
                    } else {
                        let shard = Shard(
                            id: shardExport.id,
                            collectionId: mappedCollectionId,
                            tagIds: mappedTagIds,
                            encryptionMode: EncryptionMode(rawValue: shardExport.encryptionMode) ?? .none,
                            isPinned: shardExport.isPinned,
                            displayName: shardExport.displayName,
                            deletedAt: shardExport.deletedAt,
                            payload: shardExport.payload,
                            createdAt: shardExport.createdAt,
                            updatedAt: shardExport.updatedAt
                        )
                        context.insert(shard)
                    }
                    imported += 1
                }

                try? context.save()
                feedbackMessage = "Imported \(imported) shard(s)."
                feedbackIsError = false
            } catch {
                feedbackMessage = "Import error: \(error.localizedDescription)"
                feedbackIsError = true
            }
        }
    }
}

private struct ImportedTemplate: Codable {
    var name, symbol, targetCollectionName: String
    var schema: PresetTemplateSchema

    func toPresetTemplate(orderIndex: Int) -> PresetTemplate {
        let data = (try? JSONEncoder().encode(schema)) ?? Data("{}".utf8)
        let schemaJSON = String(data: data, encoding: .utf8) ?? "{}"
        return PresetTemplate(name: name, symbol: symbol, targetCollectionName: targetCollectionName,
                              schemaFieldsJSON: schemaJSON, orderIndex: orderIndex)
    }
}
