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
}
