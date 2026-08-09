import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Navigation Model

private enum VaultFilter: Hashable {
    case shards
    case pinnedShard(String)
    case category(String)
    case tag(String)
    case trash
}

// MARK: - Main Window

struct MainWindow: View {
    private static let untitledDisplayName = "untitled"

    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Shard.createdAt, order: .reverse) private var shards: [Shard]
    @Query(sort: \ShardCollection.createdAt, order: .forward) private var collections: [ShardCollection]
    @Query(sort: \Tag.name, order: .forward) private var tags: [Tag]
    @Query(sort: \PresetTemplate.orderIndex, order: .forward) private var templates: [PresetTemplate]

    @State private var keyboardMonitor = ModifierKeyMonitor()
    @StateObject private var protection = ProtectionService.shared

    @State private var searchText = ""
    @State private var activeFilter: VaultFilter = .shards
    @State private var selectedShardId: String?
    @State private var isHeaderCollapsed = false
    @State private var isTagPopoverPresented = false
    @State private var isEditorFocused = false

    // Sidebar collapse state
    @State private var isPinnedExpanded = true
    @State private var isCategoriesExpanded = true
    @State private var isTagsExpanded = true

    // Save state
    @State private var isDirty = false
    @State private var saveDebounceTask: Task<Void, Never>?
    @State private var showUnlockAlert = false
    @State private var isWindowActive = true
    @State private var protectionPrompt: ProtectionPrompt?
    @State private var protectionPassword = ""
    @State private var protectionPasswordConfirmation = ""
    @State private var protectionPromptMessage: String?
    @State private var globalUnlockPassword = ""
    @State private var globalUnlockMessage: String?
    @AppStorage("editor_stats_items") private var editorStatsItems = "words,characters"
    @AppStorage("editor_show_status_bar") private var showStatusBar = true
    @AppStorage("custom_accent_hex") private var customAccentHex = ""
    @AppStorage("vault_sidebar_compact") private var sidebarCompact = false

    // System tag names
    private let hiddenTagNames = ["Password", "Token"]
    private let systemHiddenTagName = "Hidden"
    private let lockedTagName = "Locked"

    private var selectedShard: Shard? {
        guard let selectedShardId else { return nil }
        return filteredShards.first(where: { $0.id == selectedShardId })
            ?? shards.first(where: { $0.id == selectedShardId })
    }

    private var isSelectedShardLocked: Bool {
        guard let shard = selectedShard else { return false }
        guard let lockedTagId = tags.first(where: { $0.name == lockedTagName })?.id else { return false }
        return shard.tagIds.contains(lockedTagId)
    }

    private var isSelectedShardProtected: Bool {
        guard let shard = selectedShard else { return false }
        return shard.encryptionMode == .perShard
    }

    private var isSelectedShardProtectionLocked: Bool {
        guard let shard = selectedShard else { return false }
        return shard.encryptionMode == .perShard && !protection.canAccess(shard)
    }

    private var canEditSelectedShard: Bool {
        guard let shard = selectedShard else { return false }
        return protection.canAccess(shard) && !shardIsLocked(shard)
    }

    private var sidebarTags: [Tag] {
        tags.filter { tag in
            if hiddenTagNames.contains(tag.name) { return false }
            if tag.name == systemHiddenTagName && !keyboardMonitor.isOptionPressed { return false }
            return true
        }
    }

    private var assignableTags: [Tag] {
        tags.filter { tag in
            if hiddenTagNames.contains(tag.name) { return false }
            if tag.name == systemHiddenTagName && !keyboardMonitor.isOptionPressed { return false }
            return true
        }
    }

    func assignableTags(for shard: Shard) -> [Tag] {
        tags.filter { tag in
            if hiddenTagNames.contains(tag.name) { return false }
            if tag.name == systemHiddenTagName {
                return keyboardMonitor.isOptionPressed || shard.tagIds.contains(tag.id)
            }
            return true
        }
    }

    private var sidebarCategories: [ShardCollection] {
        var seenNames = Set<String>()
        let categoryNames = templates
            .filter { !$0.targetCollectionName.isEmpty }
            .filter { seenNames.insert($0.targetCollectionName).inserted }
            .map(\.targetCollectionName)

        return categoryNames.compactMap { categoryName in
            collections.first(where: {
                $0.name == categoryName &&
                $0.id != VaultContainer.Defaults.allCollectionID &&
                $0.name != VaultContainer.Defaults.shardsCollectionName
            })
        }
    }

    private var filteredShards: [Shard] {
        shards
            .filter(matchesCurrentFilter)
            .filter(matchesSearch)
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    private var appAccentColor: Color {
        Color(hex: customAccentHex) ?? Color(red: 79/255, green: 70/255, blue: 229/255)
    }

    private var selectedShardShouldPersistWhenHidden: Bool {
        guard let selectedShardId else { return false }
        guard !keyboardMonitor.isOptionPressed else { return false }
        guard let hiddenTagID = tags.first(where: { $0.name == systemHiddenTagName })?.id else { return false }
        return shards.contains(where: { $0.id == selectedShardId && $0.tagIds.contains(hiddenTagID) })
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            AppBackgroundView()
                .ignoresSafeArea()

            splitView
                .opacity(isEditorFocused ? 0 : 1)
                .allowsHitTesting(!isEditorFocused)

            if isEditorFocused {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }

            if protection.requiresGlobalUnlock {
                globalProtectionOverlay
            }
        }
        .animation(.smooth(duration: 0.3), value: isEditorFocused)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            if isEditorFocused, selectedShard != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: toggleEditorFocus) {
                        Label(
                            "Exit Focus Mode",
                            systemImage: "arrow.down.right.and.arrow.up.left"
                        )
                    }
                    .labelStyle(.iconOnly)
                    .help("Exit focus mode")
                }
            }
        }
        .overlay {
            VStack {
                Button("Save") { saveCurrentShard() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Pin") { if let shard = selectedShard { togglePin(shard) } }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Delete") { if let shard = selectedShard { softDelete(shard) } }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if let startupIssue = VaultContainer.shared.startupIssue {
                Text(startupIssue)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
            }
        }
        .onChange(of: filteredShards.map(\.id)) { _, ids in
            guard let first = ids.first else {
                if !selectedShardShouldPersistWhenHidden {
                    selectedShardId = nil
                }
                return
            }
            if selectedShardShouldPersistWhenHidden {
                return
            }
            if selectedShardId == nil || !ids.contains(selectedShardId ?? "") {
                withAnimation(.spring(duration: 0.3)) {
                    selectedShardId = first
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.25)) { isWindowActive = false }
            protection.lockGlobalSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.25)) { isWindowActive = true }
        }
        .sheet(item: $protectionPrompt) { prompt in
            ProtectionPasswordSheet(
                prompt: prompt,
                password: $protectionPassword,
                confirmation: $protectionPasswordConfirmation,
                errorMessage: protectionPromptMessage,
                onCancel: resetProtectionPrompt,
                onSubmit: { handleProtectionPrompt(prompt) }
            )
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            sidebarContent
                .navigationTitle("Shards")
        } content: {
            shardListContent
                .navigationTitle(filterTitle)
                .toolbar {
                    if !isEditorFocused {
                        ToolbarItem(placement: .primaryAction) {
                            Button(action: createNewShard) {
                                Image(systemName: "square.and.pencil")
                            }
                            .help("Create new shard")
                        }
                    }
                }
        } detail: {
            detailContent
                .toolbar {
                    if !isEditorFocused, selectedShard != nil {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button(action: toggleEditorFocus) {
                                Label(
                                    "Focus Mode",
                                    systemImage: "arrow.up.left.and.arrow.down.right"
                                )
                            }
                            .labelStyle(.iconOnly)
                            .help("Focus mode")

                            Button(action: toggleDetailHeader) {
                                Label(
                                    isHeaderCollapsed ? "Expand Header" : "Collapse Header",
                                    systemImage: isHeaderCollapsed ? "chevron.down" : "chevron.up"
                                )
                            }
                            .labelStyle(.iconOnly)
                            .help(isHeaderCollapsed ? "Expand header" : "Collapse header")
                        }
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .background(.clear)
        .toolbar(removing: .sidebarToggle)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search shards…")
    }
}

// MARK: - Sidebar

private extension MainWindow {
    var sidebarContent: some View {
        List(selection: $activeFilter) {
            Section("Locations") {
                sidebarRow(
                    label: "All Shards",
                    icon: VaultContainer.Defaults.shardsCollectionIcon,
                    filter: .shards,
                    count: shards.filter { $0.deletedAt == nil }.count
                )
                sidebarRow(
                    label: "Trash",
                    icon: "trash",
                    filter: .trash,
                    count: shards.filter { $0.deletedAt != nil }.count
                )
            }

            let pinned = filteredVisibleSidebarShards.filter { $0.isPinned }
            if !pinned.isEmpty {
                Section(isExpanded: $isPinnedExpanded) {
                    ForEach(pinned) { shard in
                        sidebarRow(
                            label: title(for: shard),
                            icon: "pin.fill",
                            filter: .pinnedShard(shard.id)
                        )
                    }
                } header: {
                    Text("Pinned")
                }
            }

            if !sidebarCategories.isEmpty {
                Section(isExpanded: $isCategoriesExpanded) {
                    ForEach(sidebarCategories) { collection in
                        let count = shards.filter { $0.collectionId == collection.id && $0.deletedAt == nil }.count
                        sidebarRow(
                            label: collection.name,
                            icon: collection.icon,
                            filter: .category(collection.id),
                            count: count
                        )
                    }
                } header: {
                    Text("Categories")
                }
            }

            if !sidebarTags.isEmpty {
                Section(isExpanded: $isTagsExpanded) {
                    ForEach(sidebarTags) { tag in
                        let count = shards.filter { $0.tagIds.contains(tag.id) && $0.deletedAt == nil }.count
                        sidebarRow(
                            label: tag.name,
                            icon: tag.symbol,
                            filter: .tag(tag.id),
                            count: count,
                            tintColor: Color(hex: tag.colorHex)
                        )
                    }
                } header: {
                    Text("Tags")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.clear)
        .tint(appAccentColor)
    }

    func sidebarRow(label: String, icon: String, filter: VaultFilter, count: Int = 0, tintColor: Color? = nil) -> some View {
        Label {
            Text(label)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tintColor ?? appAccentColor)
                .symbolRenderingMode(.hierarchical)
        }
        .badge(count > 0 ? count : 0)
        .tag(filter)
    }
}

// MARK: - Shard List

private extension MainWindow {
    var shardListContent: some View {
        List(selection: $selectedShardId) {
            ForEach(filteredShards) { shard in
                ShardListRow(
                    title: title(for: shard),
                    modeName: modeName(for: shard),
                    iconName: iconName(for: shard),
                    isPinned: shard.isPinned,
                    isDeleted: shard.deletedAt != nil,
                    isLocked: shardIsLocked(shard),
                    isProtected: shard.encryptionMode != .none,
                    tags: resolvedTags(for: shard),
                    dateString: listDateString(for: shard.updatedAt),
                    isCompact: sidebarCompact,
                    accentColor: appAccentColor,
                    contentPreview: contentPreview(for: shard)
                )
                .tag(shard.id)
                .contextMenu { shardContextMenu(for: shard) }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    leadingSwipeActions(for: shard)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    trailingSwipeActions(for: shard)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(.clear)
    }

    func contentPreview(for shard: Shard) -> String {
        guard let raw = accessiblePayloadText(for: shard) else {
            return shard.encryptionMode == .global ? "Vault protected" : "Protected content"
        }
        if let data = raw.data(using: .utf8),
           let preset = try? JSONDecoder().decode(PresetPayload.self, from: data) {
            let contentField = preset.fields.first(where: {
                let key = $0.name.lowercased()
                return key.contains("content") || key.contains("note") || key.contains("body")
            }) ?? preset.fields.first
            let text = contentField?.value ?? ""
            let clean = text
                .replacingOccurrences(of: "#", with: "")
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "~~", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = clean.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            return String(firstLine.prefix(80))
        }
        let clean = raw
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = clean.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        return String(firstLine.prefix(80))
    }
}

// MARK: - Detail View

private extension MainWindow {
    @ViewBuilder
    var detailContent: some View {
        if let shard = selectedShard {
            let isHidden = tags.first(where: { $0.name == systemHiddenTagName }).map { shard.tagIds.contains($0.id) } ?? false
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    detailHeader(for: shard)

                    detailPayload(for: shard)
                        .padding(.horizontal, 18)
                        .padding(.bottom, showStatusBar ? 54 : 18)
                        .blur(radius: isHidden && !isWindowActive ? 10 : 0)
                        .animation(.easeInOut(duration: reduceMotion ? 0 : 0.2), value: isWindowActive)
                }

                if shard.encryptionMode == .perShard && !protection.canAccess(shard) {
                    protectedShardOverlay(for: shard)
                }

                // Floating status pill
                if showStatusBar {
                    editorStatusBar(for: shard)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 20)
                        .padding(.bottom, 14)
                        .transition(.opacity)
                }
            }
            .background(.clear)
            .id(shard.id)
            .alert("Unlock Shard?", isPresented: $showUnlockAlert) {
                Button("Unlock", role: .destructive) { unlockCurrentShard() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove the Locked tag and allow editing this shard.")
            }
        } else {
            emptyStateView
        }
    }

    var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Shard Selected", systemImage: "doc.text")
        } description: {
            Text("Choose a shard from the list, or create a new one")
        } actions: {
            Button("New Shard", action: createNewShard)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.clear)
    }

    func detailHeader(for shard: Shard) -> some View {
        let titleBinding = Binding(
            get: {
                if isExplicitUntitledTitle(shard) {
                    return ""
                }
                return shard.displayName ?? derivedTitle(for: shard)
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let nextDisplayName: String?
                if trimmed.isEmpty {
                    nextDisplayName = Self.untitledDisplayName
                } else if trimmed == derivedTitle(for: shard) {
                    nextDisplayName = nil
                } else {
                    nextDisplayName = trimmed
                }
                guard shard.displayName != nextDisplayName else { return }
                shard.displayName = nextDisplayName
                markDirty(for: shard)
            }
        )

        return VStack(alignment: .leading, spacing: 0) {
            if isHeaderCollapsed {
                HStack(spacing: 12) {
                    Image(systemName: iconName(for: shard))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(appAccentColor)
                        .symbolRenderingMode(.hierarchical)

                    TextField(Self.untitledDisplayName, text: titleBinding)
                        .font(.title3.weight(.semibold))
                        .textFieldStyle(.plain)
                        .lineLimit(1)
                        .disabled(!canEditSelectedShard)

                    Text("Edited \(detailDateString(for: shard.updatedAt))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 24)
                .frame(height: 52)
                .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Label(categoryName(for: shard), systemImage: iconName(for: shard))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appAccentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(appAccentColor.opacity(0.11), in: Capsule())

                    TextField(Self.untitledDisplayName, text: titleBinding)
                        .font(.largeTitle.weight(.semibold))
                        .textFieldStyle(.plain)
                        .lineLimit(1)
                        .disabled(!canEditSelectedShard)

                    FlowLayout(spacing: 6) {
                        Label("Created \(detailDateString(for: shard.createdAt))", systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Label("Edited \(detailDateString(for: shard.updatedAt))", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        let attachedTags = tags.filter { shard.tagIds.contains($0.id) }
                        ForEach(attachedTags) { tag in
                            tagChip(tag, shard: shard)
                        }

                        if canEditSelectedShard {
                            Button {
                                isTagPopoverPresented = true
                            } label: {
                                Label("Add Tag", systemImage: "plus")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(.quaternary.opacity(0.55), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $isTagPopoverPresented, arrowEdge: .top) {
                                tagPopover(for: shard)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 20)
                .transition(.opacity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.2))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.separator.opacity(0.35))
                .frame(height: 0.5)
        }
        .animation(.easeInOut(duration: reduceMotion ? 0 : 0.18), value: isHeaderCollapsed)
    }

    func toggleEditorFocus() {
        withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.2)) {
            isEditorFocused.toggle()
        }
    }

    func toggleDetailHeader() {
        withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.18)) {
            isHeaderCollapsed.toggle()
        }
    }

    func detailPayload(for shard: Shard) -> some View {
        PayloadRendererView(
            payloadText: Binding(
                get: {
                    (try? protection.plaintext(for: shard)) ?? ""
                },
                set: { newValue in
                    do {
                        shard.payload = try protection.encryptPayloadForPersistence(newValue, mode: shard.encryptionMode, shard: shard)
                    } catch {
                        protectionPromptMessage = error.localizedDescription
                    }
                    markDirty(for: shard)
                }
            ),
            shard: shard,
            onEdited: {}
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(!canEditSelectedShard)
    }

    var globalProtectionOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(appAccentColor)

                Text("Vault Locked")
                    .font(.title2.weight(.bold))

                Text("Enter the global protection password to view or edit encrypted shards.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                SecureField("Vault password", text: $globalUnlockPassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)

                if let globalUnlockMessage {
                    Text(globalUnlockMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Unlock Vault") {
                    unlockGlobalVault()
                }
                .buttonStyle(.borderedProminent)
                .disabled(globalUnlockPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(24)
            .frame(maxWidth: 380)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 10)
        }
    }

    func protectedShardOverlay(for shard: Shard) -> some View {
        ZStack {
            Color.black.opacity(0.14)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(appAccentColor)

                Text("Protected Shard")
                    .font(.title3.weight(.bold))

                Text("This shard requires its own password before the content can be viewed.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Unlock Protected Content") {
                    presentProtectionPrompt(.unlockProtected, for: shard)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

// MARK: - Editor Status Bar (Floating Pill)

private extension MainWindow {
    func editorStatusBar(for shard: Shard) -> some View {
        let accessibleText = (try? protection.plaintext(for: shard)) ?? ""
        let plainText = extractPlainText(from: accessibleText)
        let stats = computeStats(for: plainText)
        let items = editorStatsItems.split(separator: ",").map(String.init)

        return HStack(spacing: 14) {
            HStack(spacing: 10) {
                ForEach(items.prefix(4), id: \.self) { item in
                    if let value = stats[item] {
                        HStack(spacing: 4) {
                            Text("\(value)")
                                .font(.caption.monospacedDigit().weight(.semibold))
                            Text(statLabel(item))
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
                .frame(height: 14)

            Group {
                if shard.encryptionMode == .perShard && !protection.canAccess(shard) {
                    Button {
                        presentProtectionPrompt(.unlockProtected, for: shard)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "shield.lefthalf.filled")
                                .font(.caption2)
                            Text("Protected")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .help("Click to unlock this protected shard")
                } else if isSelectedShardLocked {
                    Button {
                        showUnlockAlert = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                            Text("Locked")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .help("Click to unlock this shard")
                } else if isDirty {
                    Button {
                        saveCurrentShard()
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(appAccentColor)
                                .frame(width: 6, height: 6)
                            Text("Edited")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Click to save (⌘S)")
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green.opacity(0.7))
                        Text("Saved")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .animation(.easeInOut(duration: reduceMotion ? 0 : 0.15), value: isDirty)
        }
        .padding(.horizontal, 13)
        .frame(height: 32)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator.opacity(0.45), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 3)
        .fixedSize()
    }

    func extractPlainText(from payload: String) -> String {
        if let data = payload.data(using: .utf8),
           let preset = try? JSONDecoder().decode(PresetPayload.self, from: data) {
            return preset.plainTextContent
        }
        return payload
    }

    func computeStats(for text: String) -> [String: Int] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.isEmpty ? 0 : trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let characters = trimmed.count
        let sentences = trimmed.isEmpty ? 0 : trimmed.components(separatedBy: CharacterSet(charactersIn: ".!?")).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let paragraphs = trimmed.isEmpty ? 0 : trimmed.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count

        return [
            "words": words,
            "characters": characters,
            "sentences": sentences,
            "paragraphs": paragraphs
        ]
    }

    func statLabel(_ key: String) -> String {
        switch key {
        case "words": return "Words"
        case "characters": return "Chars"
        case "sentences": return "Sentences"
        case "paragraphs": return "Paras"
        default: return key.capitalized
        }
    }
}

// MARK: - Tag UI

private extension MainWindow {
    func tagChip(_ tag: Tag, shard: Shard) -> some View {
        let color = Color(hex: tag.colorHex) ?? .secondary
        return Button { navigateToTag(tag, selectedShard: shard) } label: {
            HStack(spacing: 4) {
                Image(systemName: tag.symbol)
                    .font(.caption2.weight(.semibold))
                Text(tag.name)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { removeTag(tag, from: shard) } label: {
                Label("Remove Tag", systemImage: "tag.slash")
            }
        }
    }

    @ViewBuilder
    func tagPopover(for shard: Shard) -> some View {
        TagPopoverContent(
            shard: shard,
            availableTags: assignableTags(for: shard),
            accentColor: appAccentColor,
            onToggleTag: { tag in toggleTag(tag, on: shard) },
            onCreateTag: { name, symbol, colorHex in
                createTag(name: name, symbol: symbol, colorHex: colorHex, on: shard)
            }
        )
    }
}

// MARK: - Context Menu & Swipe Actions

private extension MainWindow {
    @ViewBuilder
    func shardContextMenu(for shard: Shard) -> some View {
        if shard.deletedAt != nil {
            Button(action: { recover(shard) }) {
                Label("Recover", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive, action: { permanentDelete(shard) }) {
                Label("Delete Permanently", systemImage: "xmark.bin")
            }
        } else {
            Button(action: { togglePin(shard) }) {
                Label(shard.isPinned ? "Unpin" : "Pin", systemImage: shard.isPinned ? "pin.slash" : "pin")
            }

            if shardIsLocked(shard) {
                Button(action: { unlock(shard) }) {
                    Label("Unlock Editing", systemImage: "lock.open")
                }
            } else {
                Button(action: { lock(shard) }) {
                    Label("Lock Editing", systemImage: "lock.fill")
                }
            }

            switch shard.encryptionMode {
            case .none:
                Button(action: { presentProtectionPrompt(.protect, for: shard) }) {
                    Label("Protect", systemImage: "shield.lefthalf.filled")
                }
            case .perShard:
                if protection.isShardUnlocked(shard) {
                    Button(action: { protection.lockShardSession(shard) }) {
                        Label("Lock Protected Content", systemImage: "shield")
                    }
                } else {
                    Button(action: { presentProtectionPrompt(.unlockProtected, for: shard) }) {
                        Label("Unlock Protected Content", systemImage: "shield.lefthalf.filled")
                    }
                }
                Button(action: { presentProtectionPrompt(.removeProtection, for: shard) }) {
                    Label("Remove Protection", systemImage: "shield.slash")
                }
            case .global:
                EmptyView()
            }

            Button(action: { copyToClipboard(shard) }) {
                Label("Copy Content", systemImage: "doc.on.doc")
            }
            Button(action: { duplicate(shard) }) {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }

            Divider()

            Button(action: { exportShardAsText(shard) }) {
                Label("Export as Text", systemImage: "square.and.arrow.up")
            }
            Button(action: { exportShardAsPDF(shard) }) {
                Label("Export as PDF", systemImage: "doc.richtext")
            }

            Divider()

            let currentTags = tags.filter { shard.tagIds.contains($0.id) }
            if !currentTags.isEmpty {
                ForEach(currentTags) { tag in
                    Button(action: { toggleTag(tag, on: shard) }) {
                        Label(tag.name, systemImage: tag.symbol)
                    }
                }
                Divider()
            }

            Button(role: .destructive, action: { softDelete(shard) }) {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    func leadingSwipeActions(for shard: Shard) -> some View {
        if shard.deletedAt == nil {
            Button(action: { togglePin(shard) }) {
                Label(shard.isPinned ? "Unpin" : "Pin", systemImage: shard.isPinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        } else {
            Button(action: { recover(shard) }) {
                Label("Recover", systemImage: "arrow.uturn.backward")
            }
            .tint(.green)
        }
    }

    @ViewBuilder
    func trailingSwipeActions(for shard: Shard) -> some View {
        if shard.deletedAt == nil {
            Button(role: .destructive, action: { softDelete(shard) }) {
                Label("Trash", systemImage: "trash")
            }
        } else {
            Button(role: .destructive, action: { permanentDelete(shard) }) {
                Label("Delete", systemImage: "xmark.bin")
            }
        }
    }
}

// MARK: - Helpers & Utilities

private extension MainWindow {
    var filterTitle: String {
        switch activeFilter {
        case .shards: return "All Shards"
        case let .pinnedShard(id):
            return shards.first(where: { $0.id == id }).map { title(for: $0) } ?? "Pinned"
        case let .category(id):
            return collections.first(where: { $0.id == id })?.name ?? "Category"
        case let .tag(id):
            return tags.first(where: { $0.id == id })?.name ?? "Tag"
        case .trash: return "Trash"
        }
    }

    func resolvedTags(for shard: Shard) -> [(name: String, symbol: String, colorHex: String)] {
        sidebarTags.filter { shard.tagIds.contains($0.id) }
            .map { (name: $0.name, symbol: $0.symbol, colorHex: $0.colorHex) }
    }

    func shardIsLocked(_ shard: Shard) -> Bool {
        guard let lockedTagId = tags.first(where: { $0.name == lockedTagName })?.id else { return false }
        return shard.tagIds.contains(lockedTagId)
    }

    // MARK: Filter Logic

    func matchesCurrentFilter(_ shard: Shard) -> Bool {
        let isTrashItem = shard.deletedAt != nil
        if activeFilter == .trash {
            guard isTrashItem else { return false }
        } else {
            guard !isTrashItem else { return false }
        }

        if !keyboardMonitor.isOptionPressed {
            let hiddenTagID = tags.first(where: { $0.name == systemHiddenTagName })?.id
            if let hiddenId = hiddenTagID, shard.tagIds.contains(hiddenId) {
                return false
            }
        }

        switch activeFilter {
        case let .tag(id): return shard.tagIds.contains(id)
        case .shards: return true
        case let .pinnedShard(id): return shard.id == id
        case let .category(id): return shard.collectionId == id
        case .trash: return true
        }
    }

    var filteredVisibleSidebarShards: [Shard] {
        shards
            .filter { $0.deletedAt == nil }
            .filter { shard in
                if keyboardMonitor.isOptionPressed { return true }
                guard let hiddenTagID = tags.first(where: { $0.name == systemHiddenTagName })?.id else { return true }
                return !shard.tagIds.contains(hiddenTagID)
            }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    func matchesSearch(_ shard: Shard) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        let shardTags = tags.filter { shard.tagIds.contains($0.id) }
        let searchablePayload = plainTextDocument(for: shard)?
            .lowercased()
            .contains(query) ?? false
        return title(for: shard).lowercased().contains(query)
            || searchablePayload
            || shardTags.contains(where: { $0.name.lowercased().contains(query) })
    }

    // MARK: Payload helpers

    func payload(for shard: Shard) -> PresetPayload? {
        guard let raw = accessiblePayloadText(for: shard),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PresetPayload.self, from: data)
    }

    func accessiblePayloadText(for shard: Shard) -> String? {
        switch shard.encryptionMode {
        case .none:
            return shard.payload
        case .global, .perShard:
            return try? protection.plaintext(for: shard)
        }
    }

    // MARK: Display helpers

    func title(for shard: Shard) -> String {
        if isExplicitUntitledTitle(shard) {
            return Self.untitledDisplayName
        }
        if let customName = shard.displayName, !customName.isEmpty { return customName }
        return derivedTitle(for: shard)
    }

    func isExplicitUntitledTitle(_ shard: Shard) -> Bool {
        shard.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(Self.untitledDisplayName) == .orderedSame
    }

    func derivedTitle(for shard: Shard) -> String {
        guard let raw = accessiblePayloadText(for: shard) else {
            return shard.encryptionMode == .perShard ? "Protected Shard" : "Vault Shard"
        }
        guard let payload = payload(for: shard) else {
            return PresetPayload.raw(raw).displayTitle
        }
        guard let template = templates.first(where: { $0.name.caseInsensitiveCompare(payload.presetType) == .orderedSame }),
              let titleFieldKey = template.schema.titleFieldKey,
              let field = payload.fields.first(where: { normalizedKey(for: $0.name) == titleFieldKey }),
              !field.trimmedValue.isEmpty else {
            return payload.displayTitle
        }
        let normalizedFieldName = normalizedKey(for: field.name)
        if ["content", "body", "text", "note"].contains(normalizedFieldName) {
            return field.value.displayTitleCandidate() ?? payload.displayTitle
        }
        return field.trimmedValue
    }

    func modeName(for shard: Shard) -> String {
        if shard.encryptionMode == .perShard && !protection.canAccess(shard) {
            return "Protected"
        }
        if shard.encryptionMode == .global && !protection.canAccess(shard) {
            return "Vault"
        }
        return payload(for: shard)?.normalizedPresetType ?? "Shard"
    }

    func iconName(for shard: Shard) -> String {
        if shard.encryptionMode != .none {
            return "shield.lefthalf.filled"
        }
        switch modeName(for: shard).lowercased() {
        case "password": return "key.fill"
        case "token": return "network.badge.shield.half.filled"
        case "shard", "note": return "triangle"
        default: return "doc.text"
        }
    }

    func normalizedKey(for name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "_")
    }

    func categoryName(for shard: Shard) -> String {
        collections.first(where: { $0.id == shard.collectionId })?.name ?? VaultContainer.Defaults.shardsCollectionName
    }

    // MARK: Date formatters

    func listDateString(for date: Date) -> String {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let dateYear = calendar.component(.year, from: date)
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = currentYear == dateYear ? "d. MMM · HH:mm" : "dd.MM.yy"
        return formatter.string(from: date)
    }

    func detailDateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "d MMM yyyy · HH:mm"
        return formatter.string(from: date)
    }

    // MARK: Save Strategy

    func markDirty(for shard: Shard) {
        isDirty = true
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            shard.updatedAt = Date()
            try? context.save()
            isDirty = false
        }
    }

    func saveCurrentShard() {
        saveDebounceTask?.cancel()
        guard let shard = selectedShard else { return }
        shard.updatedAt = Date()
        try? context.save()
        isDirty = false
    }

    // MARK: Actions

    func togglePin(_ shard: Shard) {
        withAnimation(.snappy(duration: 0.25)) {
            shard.isPinned.toggle()
            shard.updatedAt = Date()
            try? context.save()
        }
    }

    func toggleTag(_ tag: Tag, on shard: Shard) {
        withAnimation(.snappy(duration: 0.2)) {
            if shard.tagIds.contains(tag.id) {
                shard.tagIds.removeAll(where: { $0 == tag.id })
            } else {
                shard.tagIds.append(tag.id)
            }
            shard.updatedAt = Date()
            try? context.save()
        }
    }

    func removeTag(_ tag: Tag, from shard: Shard) {
        guard shard.tagIds.contains(tag.id) else { return }
        withAnimation(.snappy(duration: 0.2)) {
            shard.tagIds.removeAll(where: { $0 == tag.id })
            shard.updatedAt = Date()
            try? context.save()
        }
    }

    func lock(_ shard: Shard) {
        guard let lockedTagId = tags.first(where: { $0.name == lockedTagName })?.id else { return }
        if !shard.tagIds.contains(lockedTagId) {
            shard.tagIds.append(lockedTagId)
            shard.updatedAt = Date()
            try? context.save()
        }
    }

    func unlock(_ shard: Shard) {
        guard let lockedTagId = tags.first(where: { $0.name == lockedTagName })?.id else { return }
        shard.tagIds.removeAll(where: { $0 == lockedTagId })
        shard.updatedAt = Date()
        try? context.save()
    }

    func unlockCurrentShard() {
        guard let shard = selectedShard else { return }
        unlock(shard)
    }

    func presentProtectionPrompt(_ purpose: ProtectionPrompt.Purpose, for shard: Shard) {
        protectionPassword = ""
        protectionPasswordConfirmation = ""
        protectionPromptMessage = nil
        protectionPrompt = ProtectionPrompt(shardID: shard.id, purpose: purpose)
    }

    func resetProtectionPrompt() {
        protectionPrompt = nil
        protectionPassword = ""
        protectionPasswordConfirmation = ""
        protectionPromptMessage = nil
    }

    func handleProtectionPrompt(_ prompt: ProtectionPrompt) {
        guard let shard = shards.first(where: { $0.id == prompt.shardID }) else {
            resetProtectionPrompt()
            return
        }

        do {
            switch prompt.purpose {
            case .protect:
                guard protectionPassword == protectionPasswordConfirmation else {
                    protectionPromptMessage = "The passwords do not match."
                    return
                }
                try protection.protect(shard, password: protectionPassword)
            case .unlockProtected:
                try protection.unlockProtectedShard(shard, password: protectionPassword)
            case .removeProtection:
                try protection.removeProtection(from: shard, password: protectionPassword)
            }

            shard.updatedAt = Date()
            try context.save()
            resetProtectionPrompt()
        } catch {
            protectionPromptMessage = error.localizedDescription
        }
    }

    func unlockGlobalVault() {
        globalUnlockMessage = nil
        do {
            try protection.unlockGlobal(password: globalUnlockPassword)
            globalUnlockPassword = ""
        } catch {
            globalUnlockMessage = error.localizedDescription
        }
    }

    func navigateToTag(_ tag: Tag, selectedShard shard: Shard) {
        withAnimation(.snappy(duration: 0.2)) {
            activeFilter = .tag(tag.id)
            selectedShardId = shard.id
        }
    }

    func createTag(name: String, symbol: String, colorHex: String, on shard: Shard) {
        guard !name.isEmpty else { return }
        if let existingTag = assignableTags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            toggleTag(existingTag, on: shard)
        } else {
            let tag = Tag(name: name, colorHex: colorHex, symbol: symbol)
            context.insert(tag)
            shard.tagIds.append(tag.id)
            shard.updatedAt = Date()
            try? context.save()
        }
    }

    func copyToClipboard(_ shard: Shard) {
        guard let text = plainTextDocument(for: shard) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func duplicate(_ shard: Shard) {
        guard let accessibleText = accessiblePayloadText(for: shard) else { return }
        let newShard = Shard(
            collectionId: shard.collectionId,
            tagIds: shard.tagIds,
            encryptionMode: shard.encryptionMode,
            displayName: shard.displayName.map { $0 + " (Copy)" },
            payload: shard.payload
        )

        newShard.payload = (try? protection.duplicatedPayloadForSession(
            from: shard,
            to: newShard,
            plaintext: accessibleText
        )) ?? shard.payload

        context.insert(newShard)
        try? context.save()
        withAnimation(.snappy(duration: 0.2)) { selectedShardId = newShard.id }
    }

    func softDelete(_ shard: Shard) {
        guard !shardIsLocked(shard) else { return }
        withAnimation(.snappy(duration: 0.25)) {
            if selectedShardId == shard.id { selectedShardId = nil }
            shard.deletedAt = Date()
            try? context.save()
        }
    }

    func permanentDelete(_ shard: Shard) {
        guard !shardIsLocked(shard) else { return }
        withAnimation(.snappy(duration: 0.25)) {
            if selectedShardId == shard.id { selectedShardId = nil }
            context.delete(shard)
            try? context.save()
        }
    }

    func recover(_ shard: Shard) {
        withAnimation(.snappy(duration: 0.25)) {
            shard.deletedAt = nil
            try? context.save()
        }
    }

    func createNewShard() {
        let mode = protection.desiredEncryptionModeForNewShard()
        if mode == .global, protection.requiresGlobalUnlock {
            globalUnlockMessage = "Unlock the vault before creating a new shard."
            return
        }
        let shardsCollectionId = collections.first(where: {
            $0.name == VaultContainer.Defaults.shardsCollectionName
        })?.id
        let payload = PresetPayload(presetType: "Shard", fields: [
            PresetField(name: "Content", value: "", isRequired: true)
        ])
        let payloadJSON = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let finalPayload = (try? protection.encryptPayloadForPersistence(payloadJSON, mode: mode)) ?? payloadJSON
        let shard = Shard(
            collectionId: shardsCollectionId,
            encryptionMode: mode,
            payload: finalPayload
        )
        context.insert(shard)
        try? context.save()
        withAnimation(.snappy(duration: 0.2)) { selectedShardId = shard.id }
    }

    func plainTextDocument(for shard: Shard) -> String? {
        guard let accessibleText = accessiblePayloadText(for: shard) else { return nil }
        guard let payload = payload(for: shard) else { return accessibleText }
        return payload.plainTextContent
    }

    func exportShardAsText(_ shard: Shard) {
        guard let plainText = plainTextDocument(for: shard) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(title(for: shard).sanitizedFileName).txt"

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        do {
            try ShardExportService.shared.exportPlainText(plainText, to: destinationURL)
        } catch {
            presentExportError(error)
        }
    }

    func exportShardAsPDF(_ shard: Shard) {
        guard let plainText = plainTextDocument(for: shard) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.nameFieldStringValue = "\(title(for: shard).sanitizedFileName).pdf"

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        do {
            try ShardExportService.shared.exportPDF(
                text: plainText,
                title: title(for: shard),
                to: destinationURL
            )
        } catch {
            presentExportError(error)
        }
    }

    func presentExportError(_ error: Error) {
        NSAlert(error: error).runModal()
    }
}

// MARK: - Color Extensions

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        let length = hexSanitized.count
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        if length == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0
        } else if length == 8 {
            r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(rgb & 0x000000FF) / 255.0
        } else { return nil }
        self.init(red: r, green: g, blue: b, opacity: a)
    }
}

private extension String {
    var sanitizedFileName: String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let filtered = unicodeScalars.map { scalar in
            invalidCharacters.contains(scalar) ? Character("-") : Character(scalar)
        }
        let value = String(filtered).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Shard" : value
    }
}
