import AppKit
import SwiftData
import XCTest
@testable import Shards

final class ShardsCoreTests: XCTestCase {
    func testAppearanceMapsToExpectedColorScheme() {
        XCTAssertNil(AppAppearance.system.preferredColorScheme)
        XCTAssertEqual(AppAppearance.light.preferredColorScheme, .light)
        XCTAssertEqual(AppAppearance.dark.preferredColorScheme, .dark)
    }

    func testLegacyExportPackageDecodesWithoutBackupMetadata() throws {
        let data = Data(#"{"shards":[],"tags":[],"templates":[],"collections":[],"exportedAt":0}"#.utf8)

        let package = try JSONDecoder().decode(ExportPackage.self, from: data)

        XCTAssertNil(package.formatVersion)
        XCTAssertNil(package.attachments)
        XCTAssertNil(package.reason)
    }

    @MainActor
    func testVaultBackupCapturesDataAndSanitizesFilename() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Shard.self,
            Tag.self,
            PresetTemplate.self,
            ShardCollection.self,
            ShardAttachment.self,
            configurations: configuration
        )
        container.mainContext.insert(Shard(id: "test-shard", payload: "Local note"))

        let service = VaultBackupService(
            container: container,
            backupDirectoryURL: temporaryDirectory
        )
        let summary = try service.createBackup(reason: .preUpdate(targetVersion: "1.2/RC"))
        let data = try Data(contentsOf: summary.url)
        let package = try JSONDecoder().decode(ExportPackage.self, from: data)

        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.url.path))
        XCTAssertFalse(summary.url.lastPathComponent.contains("/"))
        XCTAssertEqual(package.formatVersion, 2)
        XCTAssertEqual(package.reason, "pre-update-1.2/RC")
        XCTAssertEqual(package.shards.map(\.id), ["test-shard"])
        XCTAssertEqual(package.shards.first?.payload, "Local note")
    }

    func testLegacyBackgroundMigrationCopiesExistingValues() {
        let suiteName = "ShardsCoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("gradient", forKey: AppSettingKeys.legacyEditorBackgroundStyle)
        defaults.set("#112233", forKey: AppSettingKeys.legacyEditorBackgroundColorHex)

        AppSettingsMigration.migrateLegacySettingsIfNeeded(
            defaults: defaults,
            legacyDomainNames: [],
            domainStore: defaults
        )

        XCTAssertEqual(defaults.string(forKey: AppSettingKeys.backgroundStyle), "gradient")
        XCTAssertEqual(defaults.string(forKey: AppSettingKeys.backgroundColorHex), "#112233")
    }

    func testBundleIdentifierMigrationCopiesLegacySettingsWithoutOverwritingNewValues() {
        let sourceSuiteName = "ShardsCoreTests.Legacy.\(UUID().uuidString)"
        let destinationSuiteName = "ShardsCoreTests.Current.\(UUID().uuidString)"
        guard let source = UserDefaults(suiteName: sourceSuiteName),
              let destination = UserDefaults(suiteName: destinationSuiteName)
        else {
            XCTFail("Expected isolated defaults suites")
            return
        }
        defer {
            source.removePersistentDomain(forName: sourceSuiteName)
            destination.removePersistentDomain(forName: destinationSuiteName)
        }

        source.set("gradient", forKey: AppSettingKeys.backgroundStyle)
        source.set("personal-token", forKey: AppSettingKeys.llmAPIToken)
        source.set("legacy-shortcut-value", forKey: "KeyboardShortcuts_toggleQuickEntry")
        destination.set("#123456", forKey: "custom_accent_hex")
        source.set("#ABCDEF", forKey: "custom_accent_hex")

        AppSettingsMigration.migrateBundleIdentifierSettingsIfNeeded(
            defaults: destination,
            legacyDomainNames: [sourceSuiteName],
            domainStore: source
        )

        XCTAssertEqual(destination.string(forKey: AppSettingKeys.backgroundStyle), "gradient")
        XCTAssertEqual(destination.string(forKey: AppSettingKeys.llmAPIToken), "personal-token")
        XCTAssertEqual(destination.string(forKey: "KeyboardShortcuts_toggleQuickEntry"), "legacy-shortcut-value")
        XCTAssertEqual(destination.string(forKey: "custom_accent_hex"), "#123456")
        XCTAssertEqual(destination.integer(forKey: AppSettingKeys.bundleIdentifierMigrationVersion), 1)
        XCTAssertEqual(source.string(forKey: AppSettingKeys.llmAPIToken), "personal-token")
    }

    func testBundleIdentifierMigrationRunsOnlyOnce() {
        let sourceSuiteName = "ShardsCoreTests.Legacy.\(UUID().uuidString)"
        let destinationSuiteName = "ShardsCoreTests.Current.\(UUID().uuidString)"
        guard let source = UserDefaults(suiteName: sourceSuiteName),
              let destination = UserDefaults(suiteName: destinationSuiteName)
        else {
            XCTFail("Expected isolated defaults suites")
            return
        }
        defer {
            source.removePersistentDomain(forName: sourceSuiteName)
            destination.removePersistentDomain(forName: destinationSuiteName)
        }

        source.set("first-token", forKey: AppSettingKeys.llmAPIToken)
        AppSettingsMigration.migrateBundleIdentifierSettingsIfNeeded(
            defaults: destination,
            legacyDomainNames: [sourceSuiteName],
            domainStore: source
        )

        source.set("changed-token", forKey: AppSettingKeys.llmAPIToken)
        AppSettingsMigration.migrateBundleIdentifierSettingsIfNeeded(
            defaults: destination,
            legacyDomainNames: [sourceSuiteName],
            domainStore: source
        )

        XCTAssertEqual(destination.string(forKey: AppSettingKeys.llmAPIToken), "first-token")
    }

    @MainActor
    func testVaultLocationDoesNotDependOnBundleIdentifier() {
        let vaultDirectory = VaultContainer.vaultDirectory
        XCTAssertEqual(vaultDirectory.lastPathComponent, "Shards")
        XCTAssertEqual(vaultDirectory.deletingLastPathComponent().lastPathComponent, "Application Support")
    }

    func testPasswordCipherRoundTrip() throws {
        let plaintext = "secret payload"
        let password = "vault-pass"

        let encrypted = try PasswordCipher.encrypt(plaintext, password: password, prefix: PasswordCipher.shardPrefix)
        let decrypted = try PasswordCipher.decrypt(encrypted, password: password, expectedPrefix: PasswordCipher.shardPrefix)

        XCTAssertEqual(decrypted, plaintext)
    }

    func testSmartInputNormalizesOpenAIBaseEndpoint() throws {
        let configuration = SmartInputConfiguration(
            endpointURL: "https://api.openai.com/v1",
            apiToken: "token",
            modelName: "gpt-4.1-mini",
            requestFormatString: "openai"
        )

        let url = try SmartInputService.normalizedEndpointURL(from: configuration)

        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    func testSmartInputNormalizesGeminiBaseEndpoint() throws {
        let configuration = SmartInputConfiguration(
            endpointURL: "https://generativelanguage.googleapis.com/v1beta",
            apiToken: "token",
            modelName: "gemini-2.0-flash",
            requestFormatString: "gemini"
        )

        let url = try SmartInputService.normalizedEndpointURL(from: configuration)

        XCTAssertEqual(
            url.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
        )
    }

    func testSmartInputParsesStructuredFieldValues() throws {
        let template = SmartTemplateDescriptor(
            name: "Password",
            orderIndex: 0,
            categoryName: "Security",
            schema: PresetTemplateSchema(
                version: 1,
                summary: "Password entry",
                useCases: ["Store login credentials"],
                outputNotes: nil,
                presentationStyle: .table,
                titleFieldKey: "platform",
                displayFormat: nil,
                fields: [
                    PresetFieldDefinition(key: "platform", name: "Platform", valueType: .text, placeholder: nil, isRequired: true, isSensitive: false, helpText: nil),
                    PresetFieldDefinition(key: "account", name: "Account", valueType: .email, placeholder: nil, isRequired: false, isSensitive: false, helpText: nil),
                    PresetFieldDefinition(key: "password", name: "Password", valueType: .secret, placeholder: nil, isRequired: true, isSensitive: true, helpText: nil)
                ]
            ),
            aiDescription: "Password template"
        )

        let response = """
        ```json
        {
          "template_name": "Password",
          "fields": {
            "platform": "GitHub",
            "account": "me@example.com",
            "password": "hunter2"
          }
        }
        ```
        """

        let result = try SmartInputService.parseSmartInputResult(response, rawInput: "github login", templates: [template])

        XCTAssertEqual(result.templateName, "Password")
        XCTAssertEqual(result.payload.presetType, "Password")
        XCTAssertEqual(result.payload.fields.first(where: { $0.name == "Platform" })?.value, "GitHub")
        XCTAssertEqual(result.payload.fields.first(where: { $0.name == "Account" })?.value, "me@example.com")
        XCTAssertEqual(result.payload.fields.first(where: { $0.name == "Password" })?.value, "hunter2")
    }

    func testSmartInputUsesFallbackContentForShardTemplate() throws {
        let template = SmartTemplateDescriptor(
            name: "Shard",
            orderIndex: 0,
            categoryName: "Shards",
            schema: PresetTemplateSchema(
                version: 1,
                summary: "Quick shard",
                useCases: ["Free-form notes"],
                outputNotes: nil,
                presentationStyle: .plainText,
                titleFieldKey: "content",
                displayFormat: nil,
                fields: [
                    PresetFieldDefinition(key: "content", name: "Content", valueType: .note, placeholder: nil, isRequired: true, isSensitive: false, helpText: nil)
                ]
            ),
            aiDescription: "Shard template"
        )

        let response = """
        {
          "template_name": "Shard",
          "content": "Line one\\nLine two"
        }
        """

        let result = try SmartInputService.parseSmartInputResult(response, rawInput: "ignored", templates: [template])

        XCTAssertEqual(result.templateName, "Shard")
        XCTAssertEqual(result.payload.fields.first?.value, "Line one\nLine two")
    }

    func testLegacyMarkdownPresentationStyleDecodesAsPlainText() throws {
        let data = Data(#"{"version":1,"summary":"Test","useCases":[],"presentationStyle":"markdown","fields":[]}"#.utf8)
        let schema = try JSONDecoder().decode(PresetTemplateSchema.self, from: data)

        XCTAssertEqual(schema.presentationStyle, .plainText)
    }

    func testDisplayTitleCandidateStripsFormattingPrefixes() {
        let text = """
        # Launch Plan

        - [x] Finalize scope
        [Spec](https://example.com)
        """

        XCTAssertEqual(text.displayTitleCandidate(), "Launch Plan")
    }

    func testPresetPayloadDisplayTitleUsesFirstMeaningfulTextLine() {
        let payload = PresetPayload(
            presetType: "Shard",
            fields: [
                PresetField(name: "Content", value: """

                ```swift
                let ignored = true
                ```

                1. Ship the editor refresh
                """)
            ]
        )

        XCTAssertEqual(payload.displayTitle, "Ship the editor refresh")
    }

    func testPlainTextContentFormatsStructuredFields() {
        let payload = PresetPayload(
            presetType: "Password",
            fields: [
                PresetField(name: "Platform", value: "GitHub"),
                PresetField(name: "Identity", value: "me@example.com"),
                PresetField(name: "Password", value: "hunter2")
            ]
        )

        XCTAssertEqual(
            payload.plainTextContent,
            "Platform: GitHub\nIdentity: me@example.com\nPassword: hunter2"
        )
    }

    func testGlassBackgroundRetainsVisibleSurfaceAtZeroOpacity() {
        let metrics = AppBackgroundMetrics.resolve(
            backgroundStyle: "glass",
            backgroundOpacity: 0,
            backgroundColorOpacity: 0
        )

        XCTAssertEqual(metrics.contentOpacity, 1)
        XCTAssertGreaterThan(metrics.glassSurfaceOpacity, 0)
        XCTAssertEqual(metrics.glassTintOpacity, 0)
    }

    func testTintedGlassUsesColorOpacityOnlyForTintLayer() {
        let metrics = AppBackgroundMetrics.resolve(
            backgroundStyle: "tinted_glass",
            backgroundOpacity: 0.2,
            backgroundColorOpacity: 0
        )

        XCTAssertEqual(metrics.contentOpacity, 1)
        XCTAssertGreaterThan(metrics.glassSurfaceOpacity, 0)
        XCTAssertEqual(metrics.glassTintOpacity, 0)
    }

    func testQuickEntryTabCyclesForwardThroughEveryMode() {
        let modes: [QuickEntryMode] = [
            .smart,
            .template("shard"),
            .template("token")
        ]

        XCTAssertEqual(
            QuickEntryModeCycle.next(from: .smart, in: modes, reverse: false),
            .template("shard")
        )
        XCTAssertEqual(
            QuickEntryModeCycle.next(from: .template("token"), in: modes, reverse: false),
            .smart
        )
    }

    func testQuickEntryShiftTabCyclesBackwardAndWraps() {
        let modes: [QuickEntryMode] = [
            .smart,
            .template("shard"),
            .template("token")
        ]

        XCTAssertEqual(
            QuickEntryModeCycle.next(from: .smart, in: modes, reverse: true),
            .template("token")
        )
        XCTAssertEqual(
            QuickEntryModeCycle.next(from: .template("token"), in: modes, reverse: true),
            .template("shard")
        )
        XCTAssertNil(QuickEntryModeCycle.next(from: .smart, in: [], reverse: false))
    }

    func testQuickEntryFadeTimingStaysShortAndUsesOpacityOnlyState() {
        let timing = QuickEntryFadeTiming.standard

        XCTAssertGreaterThan(timing.presentationDuration, 0)
        XCTAssertLessThanOrEqual(timing.presentationDuration, 0.2)
        XCTAssertGreaterThan(timing.dismissalDuration, 0)
        XCTAssertLessThanOrEqual(timing.dismissalDuration, 0.2)
        XCTAssertGreaterThan(timing.reducedMotionDuration, 0)
        XCTAssertLessThanOrEqual(
            timing.reducedMotionDuration,
            timing.dismissalDuration
        )
    }

    @MainActor
    func testQuickEntryPresentationStateCanFadeInAndOut() {
        let presentationState = QuickEntryPresentationState()

        XCTAssertFalse(presentationState.isContentVisible)

        presentationState.setContentVisible(true, duration: 0)
        XCTAssertTrue(presentationState.isContentVisible)

        presentationState.setContentVisible(false, duration: 0)
        XCTAssertFalse(presentationState.isContentVisible)
    }

    @MainActor
    func testQuickEntryDismissalHidesPanelAndResetsForNextPresentation() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: QuickEntryPanelMetrics.compactSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSView(
            frame: NSRect(origin: .zero, size: QuickEntryPanelMetrics.compactSize)
        )
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }

        let controller = QuickEntryPanelTransitionController(timing: .immediate)
        controller.beginPresentation()
        controller.present(reduceMotion: false)

        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(controller.presentationState.isContentVisible)

        controller.dismiss(
            panel: panel,
            completedCapture: true,
            reduceMotion: false
        )

        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(controller.presentationState.isContentVisible)
        XCTAssertFalse(controller.isDismissing)
        XCTAssertEqual(panel.alphaValue, 1)

        controller.beginPresentation()
        panel.orderFront(nil)
        controller.present(reduceMotion: false)

        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(controller.presentationState.isContentVisible)
    }

    @MainActor
    func testQuickEntryPanelRoutesEscapeBeforeResponderChain() throws {
        let panel = QuickEntryPanel(
            contentRect: NSRect(origin: .zero, size: QuickEntryPanelMetrics.compactSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        var dismissalCount = 0
        panel.onRequestDismissal = {
            dismissalCount += 1
        }

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        ))

        panel.sendEvent(event)

        XCTAssertEqual(dismissalCount, 1)
    }

    func testQuickEntryTransitionIgnoresStaleDismissalCompletion() throws {
        var state = QuickEntryTransitionState()
        state.beginPresentation()
        let staleGeneration = try XCTUnwrap(state.beginDismissal())

        state.beginPresentation()

        XCTAssertFalse(state.isDismissing)
        XCTAssertFalse(state.finishDismissal(generation: staleGeneration))
    }

    func testQuickEntryTransitionRejectsDuplicateDismissal() throws {
        var state = QuickEntryTransitionState()
        state.beginPresentation()
        let generation = try XCTUnwrap(state.beginDismissal())

        XCTAssertNil(state.beginDismissal())
        XCTAssertTrue(state.isCurrentDismissal(generation: generation))
        XCTAssertTrue(state.finishDismissal(generation: generation))
        XCTAssertFalse(state.isDismissing)
    }

    func testQuickEntryCompletedDismissalSupersedesInFlightResignKeyDismissal() throws {
        var state = QuickEntryTransitionState()
        state.beginPresentation()
        let resignKeyGeneration = try XCTUnwrap(state.beginDismissal())
        let completedCaptureGeneration = try XCTUnwrap(
            state.beginDismissal(replacingCurrent: true)
        )

        XCTAssertNotEqual(resignKeyGeneration, completedCaptureGeneration)
        XCTAssertFalse(state.isCurrentDismissal(generation: resignKeyGeneration))
        XCTAssertTrue(state.finishDismissal(generation: completedCaptureGeneration))
        XCTAssertFalse(state.isDismissing)
    }

    @MainActor
    func testBatchTagOperationSkipsLockedShardAndSupportsUndoRedo() throws {
        let container = try makeInMemoryVault()
        let context = container.mainContext
        let tag = Tag(id: "work", name: "Work", colorHex: "#336699", symbol: "briefcase")
        let lockedTag = Tag(id: "locked", name: "Locked", colorHex: "#666666", symbol: "lock.fill")
        let editable = Shard(id: "editable", payload: "Editable")
        let locked = Shard(id: "locked-shard", tagIds: [lockedTag.id], payload: "Locked")
        [tag, lockedTag].forEach(context.insert)
        [editable, locked].forEach(context.insert)
        try context.save()

        let repository = VaultRepository(container: container)
        let receipt = try repository.applyBatch(
            .addTag(tag.id),
            to: [editable.id, locked.id, editable.id],
            lockedTagID: lockedTag.id
        )

        XCTAssertEqual(receipt.changedIDs, [editable.id])
        XCTAssertEqual(receipt.skippedLockedIDs, [locked.id])
        XCTAssertTrue(editable.tagIds.contains(tag.id))
        XCTAssertFalse(locked.tagIds.contains(tag.id))

        let undoManager = UndoManager()
        let undoController = VaultBatchUndoController()
        undoController.register(receipt, with: undoManager, repository: repository)

        undoManager.undo()
        XCTAssertFalse(editable.tagIds.contains(tag.id))

        undoManager.redo()
        XCTAssertTrue(editable.tagIds.contains(tag.id))
    }

    @MainActor
    func testBatchRestoreAllowsLockedTrashItems() throws {
        let container = try makeInMemoryVault()
        let context = container.mainContext
        let lockedTag = Tag(id: "locked", name: "Locked", colorHex: "#666666", symbol: "lock.fill")
        let deletedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let shard = Shard(
            id: "locked-trash",
            tagIds: [lockedTag.id],
            deletedAt: deletedAt,
            payload: "Recover me"
        )
        context.insert(lockedTag)
        context.insert(shard)
        try context.save()

        let repository = VaultRepository(container: container)
        let receipt = try repository.applyBatch(
            .restore,
            to: [shard.id],
            lockedTagID: lockedTag.id
        )

        XCTAssertEqual(receipt.changedCount, 1)
        XCTAssertTrue(receipt.skippedLockedIDs.isEmpty)
        XCTAssertNil(shard.deletedAt)

        try repository.replayBatch(receipt, direction: .undo)
        XCTAssertEqual(shard.deletedAt, deletedAt)
    }

    @MainActor
    func testBatchUndoRefusesToOverwriteNewerMetadata() throws {
        let container = try makeInMemoryVault()
        let context = container.mainContext
        let shard = Shard(id: "conflict", payload: "Conflict")
        context.insert(shard)
        try context.save()

        let repository = VaultRepository(container: container)
        let receipt = try repository.applyBatch(.setPinned(true), to: [shard.id], lockedTagID: nil)
        shard.updatedAt = shard.updatedAt.addingTimeInterval(10)
        try context.save()

        XCTAssertThrowsError(try repository.replayBatch(receipt, direction: .undo)) { error in
            XCTAssertEqual(error as? ShardBatchError, .stateConflict)
        }
        XCTAssertTrue(shard.isPinned)
    }

    @MainActor
    func testBatchUndoValidatesEveryShardBeforeRestoringAny() throws {
        let container = try makeInMemoryVault()
        let context = container.mainContext
        let first = Shard(id: "first-conflict", payload: "First")
        let second = Shard(id: "second-conflict", payload: "Second")
        context.insert(first)
        context.insert(second)
        try context.save()

        let repository = VaultRepository(container: container)
        let receipt = try repository.applyBatch(
            .setPinned(true),
            to: [first.id, second.id],
            lockedTagID: nil
        )
        second.updatedAt = second.updatedAt.addingTimeInterval(10)
        try context.save()

        XCTAssertThrowsError(try repository.replayBatch(receipt, direction: .undo)) { error in
            XCTAssertEqual(error as? ShardBatchError, .stateConflict)
        }
        XCTAssertTrue(first.isPinned)
        XCTAssertTrue(second.isPinned)
    }

    @MainActor
    func testBatchMissingTagDoesNotMutateShard() throws {
        let container = try makeInMemoryVault()
        let context = container.mainContext
        let shard = Shard(id: "missing-tag", payload: "Untouched")
        context.insert(shard)
        try context.save()

        let repository = VaultRepository(container: container)
        XCTAssertThrowsError(
            try repository.applyBatch(.addTag("not-found"), to: [shard.id], lockedTagID: nil)
        ) { error in
            XCTAssertEqual(error as? ShardBatchError, .missingTag)
        }
        XCTAssertTrue(shard.tagIds.isEmpty)
    }

    @MainActor
    func testPermanentDeleteOnlyRemovesEligibleTrashAndAttachments() throws {
        let container = try makeInMemoryVault()
        let context = container.mainContext
        let lockedTag = Tag(id: "locked-delete", name: "Locked", colorHex: "#666666", symbol: "lock.fill")
        let live = Shard(id: "live", payload: "Live")
        let trash = Shard(id: "trash", deletedAt: Date(), payload: "Trash")
        let lockedTrash = Shard(id: "locked-trash-delete", tagIds: [lockedTag.id], deletedAt: Date(), payload: "Locked")
        let trashAttachment = ShardAttachment(id: "trash-attachment", shardId: trash.id, originalName: "trash.txt", storedFileName: "trash.txt")
        let lockedAttachment = ShardAttachment(id: "locked-attachment", shardId: lockedTrash.id, originalName: "locked.txt", storedFileName: "locked.txt")
        context.insert(lockedTag)
        [live, trash, lockedTrash].forEach(context.insert)
        [trashAttachment, lockedAttachment].forEach(context.insert)
        try context.save()

        let repository = VaultRepository(container: container)
        let receipt = try repository.permanentlyDelete(
            shardIDs: [live.id, trash.id, lockedTrash.id, "missing"],
            lockedTagID: lockedTag.id
        )

        XCTAssertEqual(receipt.deletedIDs, [trash.id])
        XCTAssertEqual(receipt.skippedLiveIDs, [live.id])
        XCTAssertEqual(receipt.skippedLockedIDs, [lockedTrash.id])
        XCTAssertEqual(receipt.missingIDs, ["missing"])
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Shard>()).map(\.id)), [live.id, lockedTrash.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ShardAttachment>()).map(\.id), [lockedAttachment.id])
    }

    @MainActor
    func testIsolatedBatchDoesNotCommitUnrelatedMainContextDraft() throws {
        let container = try makeInMemoryVault()
        let mainContext = container.mainContext
        let shard = Shard(id: "isolated", payload: "Persisted")
        mainContext.insert(shard)
        try mainContext.save()

        shard.payload = "Unsaved draft"
        XCTAssertTrue(mainContext.hasChanges)

        let repository = VaultRepository(container: container)
        let receipt = try repository.applyBatchInIsolatedContext(
            .setPinned(true),
            to: [shard.id],
            lockedTagID: nil
        )

        XCTAssertEqual(receipt.changedCount, 1)
        XCTAssertTrue(mainContext.hasChanges)
        XCTAssertEqual(shard.payload, "Unsaved draft")

        let verificationContext = ModelContext(container)
        let persisted = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<Shard>()).first(where: { $0.id == shard.id })
        )
        XCTAssertEqual(persisted.payload, "Persisted")
        XCTAssertTrue(persisted.isPinned)
    }

    @MainActor
    func testIsolatedBatchReplayDoesNotCommitUnrelatedMainContextDraft() throws {
        let container = try makeInMemoryVault()
        let mainContext = container.mainContext
        let shard = Shard(id: "isolated-undo", payload: "Persisted")
        mainContext.insert(shard)
        try mainContext.save()

        let repository = VaultRepository(container: container)
        let receipt = try repository.applyBatch(.setPinned(true), to: [shard.id], lockedTagID: nil)
        shard.payload = "Unsaved draft"

        XCTAssertThrowsError(try repository.replayBatch(receipt, direction: .undo)) { error in
            XCTAssertEqual(error as? ShardBatchError, .pendingChanges)
        }

        try repository.replayBatchInIsolatedContext(receipt, direction: .undo)

        XCTAssertTrue(mainContext.hasChanges)
        XCTAssertEqual(shard.payload, "Unsaved draft")
        let verificationContext = ModelContext(container)
        let persisted = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<Shard>()).first(where: { $0.id == shard.id })
        )
        XCTAssertEqual(persisted.payload, "Persisted")
        XCTAssertFalse(persisted.isPinned)
    }

    func testShardDragPayloadRoundTripsStableIDs() throws {
        let payload = ShardDragPayload(shardIDs: ["first", "second"])
        let data = try JSONEncoder().encode(payload)

        XCTAssertEqual(try JSONDecoder().decode(ShardDragPayload.self, from: data), payload)
        XCTAssertEqual(
            ShardDragPayload.normalizedIDs(from: [
                .init(shardIDs: ["second", "third"]),
                .init(shardIDs: ["first", "second"])
            ]),
            ["second", "third", "first"]
        )
    }

    func testShardSelectionPolicyRetainsVisibleMultiSelectionAndFallsBackToFirst() {
        XCTAssertEqual(
            ShardSelectionPolicy.reconciled(
                current: ["first", "hidden", "third"],
                visibleIDs: ["first", "second", "third"],
                preserveHiddenSingleSelection: false
            ),
            ["first", "third"]
        )
        XCTAssertEqual(
            ShardSelectionPolicy.reconciled(
                current: ["missing"],
                visibleIDs: ["first", "second"],
                preserveHiddenSingleSelection: false
            ),
            ["first"]
        )
        XCTAssertEqual(
            ShardSelectionPolicy.reconciled(
                current: ["hidden"],
                visibleIDs: [],
                preserveHiddenSingleSelection: true
            ),
            ["hidden"]
        )
        XCTAssertTrue(
            ShardSelectionPolicy.reconciled(
                current: ["missing"],
                visibleIDs: [],
                preserveHiddenSingleSelection: false
            ).isEmpty
        )
    }

    @MainActor
    func testRecentCaptureStorePersistsAndClearsOnlyMatchingID() throws {
        let suiteName = "ShardsCoreTests.RecentCapture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecentCaptureStore(defaults: defaults, notificationCenter: NotificationCenter())

        store.record(shardID: "latest")
        XCTAssertEqual(store.shardID, "latest")

        store.clear(ifMatching: "older")
        XCTAssertEqual(store.shardID, "latest")

        store.clear(ifMatching: "latest")
        XCTAssertNil(store.shardID)
    }

    @MainActor
    func testDefaultWelcomeShardsSeedHiddenGuideAsThirdShard() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let shards = VaultContainer.makeDefaultWelcomeShards(
            collectionId: "welcome",
            hiddenTagId: "hidden-tag",
            now: now
        )

        XCTAssertEqual(shards.count, 3)
        XCTAssertEqual(shards[0].collectionId, "welcome")
        XCTAssertTrue(shards[0].tagIds.isEmpty)
        XCTAssertTrue(shards[1].tagIds.isEmpty)
        XCTAssertEqual(shards[2].tagIds, ["hidden-tag"])
        XCTAssertTrue(shards[0].payload.contains("Welcome to Shards"))
        XCTAssertTrue(shards[1].payload.contains("Tags & Templates"))
        XCTAssertTrue(shards[2].payload.contains("Hold Option"))
        XCTAssertEqual(shards[0].createdAt, now)
        XCTAssertEqual(shards[1].createdAt, now.addingTimeInterval(-1))
        XCTAssertEqual(shards[2].createdAt, now.addingTimeInterval(-2))
    }

    @MainActor
    func testPDFExportWritesDocument() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let destinationURL = temporaryDirectory.appendingPathComponent("sample.pdf")

        try ShardExportService.shared.exportPDF(
            text: "Rendered content.",
            title: "Sample",
            to: destinationURL
        )

        let data = try Data(contentsOf: destinationURL)
        XCTAssertFalse(data.isEmpty)
    }

    @MainActor
    func testPlainTextExportWritesDocument() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let destinationURL = temporaryDirectory.appendingPathComponent("sample.txt")

        try ShardExportService.shared.exportPlainText("hello", to: destinationURL)

        let content = try String(contentsOf: destinationURL, encoding: .utf8)
        XCTAssertEqual(content, "hello")
    }

    @MainActor
    private func makeInMemoryVault() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Shard.self,
            Tag.self,
            PresetTemplate.self,
            ShardCollection.self,
            ShardAttachment.self,
            configurations: configuration
        )
    }
}
