import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Shards

private final class TestStateBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func update(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}

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

    @MainActor
    func testGlobalProtectionCommitsPayloadsBeforePublishingConfiguration() throws {
        let suiteName = "ShardsCoreTests.Protection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try makeInMemoryVault()
        let context = container.mainContext
        let shard = Shard(id: "global-round-trip", payload: "private content")
        context.insert(shard)
        try context.save()
        let protection = ProtectionService(defaults: defaults)

        try protection.enableGlobalProtection(password: "correct horse", context: context)

        XCTAssertTrue(defaults.bool(forKey: AppSettingKeys.globalProtectionEnabled))
        XCTAssertNotNil(defaults.data(forKey: AppSettingKeys.globalProtectionConfiguration))
        XCTAssertEqual(shard.encryptionMode, .global)
        XCTAssertTrue(shard.payload.hasPrefix("\(PasswordCipher.globalPrefix):"))
        let encryptedPayload = shard.payload
        let encryptedVerification = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<Shard>()).first(where: { $0.id == shard.id })
        )
        XCTAssertEqual(encryptedVerification.payload, encryptedPayload)

        try protection.disableGlobalProtection(password: "correct horse", context: context)

        XCTAssertFalse(defaults.bool(forKey: AppSettingKeys.globalProtectionEnabled))
        XCTAssertNil(defaults.data(forKey: AppSettingKeys.globalProtectionConfiguration))
        XCTAssertEqual(shard.encryptionMode, .none)
        XCTAssertEqual(shard.payload, "private content")
    }

    @MainActor
    func testLegacyGlobalProtectionSettingsMigrateToAtomicConfiguration() throws {
        let suiteName = "ShardsCoreTests.ProtectionLegacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let password = "legacy password"
        let salt = Data(repeating: 5, count: 16)
        defaults.set(salt.base64EncodedString(), forKey: AppSettingKeys.globalProtectionSalt)
        defaults.set(
            PasswordCipher.makeVerifier(password: password, salt: salt),
            forKey: AppSettingKeys.globalProtectionVerifier
        )
        defaults.set(true, forKey: AppSettingKeys.globalProtectionEnabled)

        let protection = ProtectionService(defaults: defaults)

        XCTAssertTrue(protection.globalProtectionEnabled)
        XCTAssertNotNil(defaults.data(forKey: AppSettingKeys.globalProtectionConfiguration))
        XCTAssertNoThrow(try protection.unlockGlobal(password: password))
    }

    @MainActor
    func testPendingGlobalProtectionConfigurationPromotesAfterDatabaseCommit() throws {
        let suiteName = "ShardsCoreTests.ProtectionRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try makeInMemoryVault()
        let context = container.mainContext
        let password = "recoverable password"
        let salt = Data(repeating: 7, count: 16)
        let pending = GlobalProtectionConfiguration(
            version: 3,
            state: .pendingEnable,
            salt: salt.base64EncodedString(),
            verifier: PasswordCipher.makeVerifier(password: password, salt: salt),
            preGlobalCount: 0,
            expectedPostGlobalCount: 1
        )
        defaults.set(try JSONEncoder().encode(pending), forKey: AppSettingKeys.globalProtectionConfiguration)

        let shard = Shard(
            id: "pending-protection-commit",
            encryptionMode: .global,
            payload: try PasswordCipher.encrypt(
                "recover me",
                password: password,
                prefix: PasswordCipher.globalPrefix
            )
        )
        context.insert(shard)
        try context.save()

        let protection = ProtectionService(defaults: defaults)
        XCTAssertFalse(protection.globalProtectionEnabled)
        try protection.recoverPendingConfiguration(context: context)
        XCTAssertTrue(protection.globalProtectionEnabled)
        try protection.unlockGlobal(password: password)
        XCTAssertEqual(try protection.plaintext(for: shard), "recover me")
    }

    @MainActor
    func testPendingGlobalProtectionConfigurationIsDiscardedWithoutDatabaseCommit() throws {
        let suiteName = "ShardsCoreTests.ProtectionRecoveryRollback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try makeInMemoryVault()
        let salt = Data(repeating: 9, count: 16)
        let pending = GlobalProtectionConfiguration(
            version: 3,
            state: .pendingEnable,
            salt: salt.base64EncodedString(),
            verifier: PasswordCipher.makeVerifier(password: "unused", salt: salt),
            preGlobalCount: 0,
            expectedPostGlobalCount: 1
        )
        defaults.set(try JSONEncoder().encode(pending), forKey: AppSettingKeys.globalProtectionConfiguration)

        let protection = ProtectionService(defaults: defaults)
        try protection.recoverPendingConfiguration(context: container.mainContext)

        XCTAssertFalse(protection.globalProtectionEnabled)
        XCTAssertNil(defaults.data(forKey: AppSettingKeys.globalProtectionConfiguration))
        XCTAssertFalse(defaults.bool(forKey: AppSettingKeys.globalProtectionEnabled))
    }

    @MainActor
    func testPendingZeroRowGlobalProtectionConfigurationFailsSafeToDisabled() throws {
        let suiteName = "ShardsCoreTests.ProtectionRecoveryZeroRows.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try makeInMemoryVault()
        let salt = Data(repeating: 10, count: 16)
        let pending = GlobalProtectionConfiguration(
            version: 3,
            state: .pendingEnable,
            salt: salt.base64EncodedString(),
            verifier: PasswordCipher.makeVerifier(password: "unused", salt: salt),
            preGlobalCount: 0,
            expectedPostGlobalCount: 0
        )
        defaults.set(try JSONEncoder().encode(pending), forKey: AppSettingKeys.globalProtectionConfiguration)

        let protection = ProtectionService(defaults: defaults)
        try protection.recoverPendingConfiguration(context: container.mainContext)

        XCTAssertFalse(protection.globalProtectionEnabled)
        XCTAssertNil(defaults.data(forKey: AppSettingKeys.globalProtectionConfiguration))
    }

    @MainActor
    func testPendingGlobalDisableCompletesAfterPlaintextDatabaseCommit() throws {
        let suiteName = "ShardsCoreTests.ProtectionDisableRecoveryCommitted.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try makeInMemoryVault()
        let context = container.mainContext
        let password = "disable recovery"
        let shard = Shard(id: "pending-disable-committed", payload: "private content")
        context.insert(shard)
        try context.save()

        let protection = ProtectionService(defaults: defaults)
        try protection.enableGlobalProtection(password: password, context: context)
        let enabledData = try XCTUnwrap(
            defaults.data(forKey: AppSettingKeys.globalProtectionConfiguration)
        )
        let enabled = try JSONDecoder().decode(
            GlobalProtectionConfiguration.self,
            from: enabledData
        )
        let pendingDisable = GlobalProtectionConfiguration(
            version: 3,
            state: .pendingDisable,
            salt: enabled.salt,
            verifier: enabled.verifier,
            preGlobalCount: 1,
            expectedPostGlobalCount: 0
        )
        defaults.set(
            try JSONEncoder().encode(pendingDisable),
            forKey: AppSettingKeys.globalProtectionConfiguration
        )

        // Simulate process interruption after context.save() has made every
        // row plaintext but before disableGlobalProtection clears its record.
        shard.payload = try PasswordCipher.decrypt(
            shard.payload,
            password: password,
            expectedPrefix: PasswordCipher.globalPrefix
        )
        shard.encryptionMode = .none
        try context.save()

        let recoveredProtection = ProtectionService(defaults: defaults)
        XCTAssertFalse(recoveredProtection.globalProtectionEnabled)
        XCTAssertTrue(defaults.bool(forKey: AppSettingKeys.globalProtectionEnabled))

        try recoveredProtection.recoverPendingConfiguration(
            context: ModelContext(container)
        )

        XCTAssertFalse(recoveredProtection.globalProtectionEnabled)
        XCTAssertNil(defaults.data(forKey: AppSettingKeys.globalProtectionConfiguration))
        XCTAssertFalse(defaults.bool(forKey: AppSettingKeys.globalProtectionEnabled))
        let persisted = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<Shard>())
                .first(where: { $0.id == shard.id })
        )
        XCTAssertEqual(persisted.encryptionMode, .none)
        XCTAssertEqual(persisted.payload, "private content")
    }

    @MainActor
    func testPendingGlobalDisableRestoresEnabledConfigurationWithoutDatabaseCommit() throws {
        let suiteName = "ShardsCoreTests.ProtectionDisableRecoveryUncommitted.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try makeInMemoryVault()
        let context = container.mainContext
        let password = "disable rollback recovery"
        let shard = Shard(id: "pending-disable-uncommitted", payload: "protected content")
        context.insert(shard)
        try context.save()

        let protection = ProtectionService(defaults: defaults)
        try protection.enableGlobalProtection(password: password, context: context)
        let encryptedPayload = shard.payload
        let enabledData = try XCTUnwrap(
            defaults.data(forKey: AppSettingKeys.globalProtectionConfiguration)
        )
        let enabled = try JSONDecoder().decode(
            GlobalProtectionConfiguration.self,
            from: enabledData
        )
        let pendingDisable = GlobalProtectionConfiguration(
            version: 3,
            state: .pendingDisable,
            salt: enabled.salt,
            verifier: enabled.verifier,
            preGlobalCount: 1,
            expectedPostGlobalCount: 0
        )
        defaults.set(
            try JSONEncoder().encode(pendingDisable),
            forKey: AppSettingKeys.globalProtectionConfiguration
        )

        let recoveredProtection = ProtectionService(defaults: defaults)
        XCTAssertFalse(recoveredProtection.globalProtectionEnabled)
        try recoveredProtection.recoverPendingConfiguration(
            context: ModelContext(container)
        )

        XCTAssertTrue(recoveredProtection.globalProtectionEnabled)
        try recoveredProtection.unlockGlobal(password: password)
        let persisted = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<Shard>())
                .first(where: { $0.id == shard.id })
        )
        XCTAssertEqual(persisted.encryptionMode, .global)
        XCTAssertEqual(persisted.payload, encryptedPayload)
        XCTAssertEqual(try recoveredProtection.plaintext(for: persisted), "protected content")
    }

    func testVersionTwoGlobalProtectionConfigurationDecodesExactExpectedCount() throws {
        let data = Data(
            """
            {
              "version": 2,
              "state": "pendingEnable",
              "salt": "legacy-salt",
              "verifier": "legacy-verifier",
              "expectedConvertedCount": 3
            }
            """.utf8
        )

        let configuration = try JSONDecoder().decode(GlobalProtectionConfiguration.self, from: data)

        XCTAssertEqual(configuration.preGlobalCount, 0)
        XCTAssertEqual(configuration.expectedPostGlobalCount, 3)
    }

    @MainActor
    func testVersionTwoPendingProtectionPromotesToReadableVersionThreeRecord() throws {
        let suiteName = "ShardsCoreTests.ProtectionV2Promotion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let password = "v2 recovery"
        let salt = Data(repeating: 14, count: 16)
        let pendingData = Data(
            """
            {
              "version": 2,
              "state": "pendingEnable",
              "salt": "\(salt.base64EncodedString())",
              "verifier": "\(PasswordCipher.makeVerifier(password: password, salt: salt))",
              "expectedConvertedCount": 1
            }
            """.utf8
        )
        defaults.set(pendingData, forKey: AppSettingKeys.globalProtectionConfiguration)
        let container = try makeInMemoryVault()
        let context = container.mainContext
        context.insert(
            Shard(
                id: "v2-promoted-global",
                encryptionMode: .global,
                payload: try PasswordCipher.encrypt(
                    "v2 secret",
                    password: password,
                    prefix: PasswordCipher.globalPrefix
                )
            )
        )
        try context.save()

        let protection = ProtectionService(defaults: defaults)
        try protection.recoverPendingConfiguration(context: context)

        let promotedData = try XCTUnwrap(
            defaults.data(forKey: AppSettingKeys.globalProtectionConfiguration)
        )
        let promoted = try JSONDecoder().decode(
            GlobalProtectionConfiguration.self,
            from: promotedData
        )
        XCTAssertEqual(promoted.version, 3)
        XCTAssertEqual(promoted.state, .enabled)
        XCTAssertTrue(protection.globalProtectionEnabled)
    }

    func testProtectionConfigurationRejectsIncompleteOrUnknownVersions() {
        let incompleteV3 = Data(
            """
            {
              "version": 3,
              "state": "pendingEnable",
              "salt": "salt",
              "verifier": "verifier"
            }
            """.utf8
        )
        let unknownVersion = Data(
            """
            {
              "version": 4,
              "state": "pendingEnable",
              "salt": "salt",
              "verifier": "verifier",
              "preGlobalCount": 0,
              "expectedPostGlobalCount": 1
            }
            """.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(GlobalProtectionConfiguration.self, from: incompleteV3)
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(GlobalProtectionConfiguration.self, from: unknownVersion)
        )
    }

    @MainActor
    func testPendingZeroCountProtectionRejectsUnexpectedGlobalRows() throws {
        let suiteName = "ShardsCoreTests.ProtectionRecoveryZeroMismatch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try makeInMemoryVault()
        let context = container.mainContext
        let salt = Data(repeating: 13, count: 16)
        let pending = GlobalProtectionConfiguration(
            version: 3,
            state: .pendingEnable,
            salt: salt.base64EncodedString(),
            verifier: PasswordCipher.makeVerifier(password: "unexpected", salt: salt),
            preGlobalCount: 0,
            expectedPostGlobalCount: 0
        )
        let pendingData = try JSONEncoder().encode(pending)
        defaults.set(pendingData, forKey: AppSettingKeys.globalProtectionConfiguration)
        context.insert(
            Shard(
                id: "unexpected-zero-count-global",
                encryptionMode: .global,
                payload: try PasswordCipher.encrypt(
                    "must remain protected",
                    password: "unexpected",
                    prefix: PasswordCipher.globalPrefix
                )
            )
        )
        try context.save()

        let protection = ProtectionService(defaults: defaults)
        XCTAssertThrowsError(try protection.recoverPendingConfiguration(context: context)) { error in
            guard let protectionError = error as? ProtectionError,
                  case .inconsistentGlobalProtectionState = protectionError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            defaults.data(forKey: AppSettingKeys.globalProtectionConfiguration),
            pendingData
        )
    }

    @MainActor
    func testPendingGlobalProtectionConfigurationRejectsPartialDatabaseCommit() throws {
        let suiteName = "ShardsCoreTests.ProtectionRecoveryMismatch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try makeInMemoryVault()
        let context = container.mainContext
        let salt = Data(repeating: 11, count: 16)
        let pending = GlobalProtectionConfiguration(
            version: 3,
            state: .pendingEnable,
            salt: salt.base64EncodedString(),
            verifier: PasswordCipher.makeVerifier(password: "partial", salt: salt),
            preGlobalCount: 0,
            expectedPostGlobalCount: 2
        )
        defaults.set(try JSONEncoder().encode(pending), forKey: AppSettingKeys.globalProtectionConfiguration)
        context.insert(
            Shard(
                id: "partial-global",
                encryptionMode: .global,
                payload: try PasswordCipher.encrypt(
                    "partially converted",
                    password: "partial",
                    prefix: PasswordCipher.globalPrefix
                )
            )
        )
        try context.save()

        let protection = ProtectionService(defaults: defaults)
        XCTAssertThrowsError(try protection.recoverPendingConfiguration(context: context)) { error in
            guard let protectionError = error as? ProtectionError,
                  case .inconsistentGlobalProtectionState = protectionError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertFalse(protection.globalProtectionEnabled)
        let preservedData = try XCTUnwrap(
            defaults.data(forKey: AppSettingKeys.globalProtectionConfiguration)
        )
        XCTAssertEqual(try JSONDecoder().decode(GlobalProtectionConfiguration.self, from: preservedData), pending)
    }

    @MainActor
    func testEnablingGlobalProtectionRejectsOrphanEncryptedRows() throws {
        let suiteName = "ShardsCoreTests.ProtectionOrphan.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try makeInMemoryVault()
        let context = container.mainContext
        let originalPayload = try PasswordCipher.encrypt(
            "existing secret",
            password: "old password",
            prefix: PasswordCipher.globalPrefix
        )
        context.insert(
            Shard(
                id: "orphan-global",
                encryptionMode: .global,
                payload: originalPayload
            )
        )
        try context.save()
        let protection = ProtectionService(defaults: defaults)

        XCTAssertThrowsError(
            try protection.enableGlobalProtection(password: "new password", context: context)
        ) { error in
            guard let protectionError = error as? ProtectionError,
                  case .inconsistentGlobalProtectionState = protectionError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertNil(defaults.data(forKey: AppSettingKeys.globalProtectionConfiguration))
        let persisted = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<Shard>()).first(where: { $0.id == "orphan-global" })
        )
        XCTAssertEqual(persisted.encryptionMode, .global)
        XCTAssertEqual(persisted.payload, originalPayload)
    }

    @MainActor
    func testEnablingGlobalProtectionNeverOverwritesAnExistingConfiguration() throws {
        let suiteName = "ShardsCoreTests.ProtectionExistingConfiguration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let protection = ProtectionService(defaults: defaults)
        let container = try makeInMemoryVault()
        let salt = Data(repeating: 12, count: 16)
        let existing = GlobalProtectionConfiguration(
            version: 3,
            state: .enabled,
            salt: salt.base64EncodedString(),
            verifier: PasswordCipher.makeVerifier(password: "existing", salt: salt),
            preGlobalCount: 0,
            expectedPostGlobalCount: 0
        )
        let existingData = try JSONEncoder().encode(existing)
        defaults.set(existingData, forKey: AppSettingKeys.globalProtectionConfiguration)

        XCTAssertThrowsError(
            try protection.enableGlobalProtection(
                password: "replacement",
                context: container.mainContext
            )
        ) { error in
            guard let protectionError = error as? ProtectionError,
                  case .inconsistentGlobalProtectionState = protectionError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(
            defaults.data(forKey: AppSettingKeys.globalProtectionConfiguration),
            existingData
        )
    }

    @MainActor
    func testProtectionRecoveryRejectsGlobalRowsWithoutConfiguration() throws {
        let suiteName = "ShardsCoreTests.ProtectionMissingConfiguration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try makeInMemoryVault()
        let context = container.mainContext
        context.insert(
            Shard(
                id: "unconfigured-global",
                encryptionMode: .global,
                payload: try PasswordCipher.encrypt(
                    "unavailable",
                    password: "unknown",
                    prefix: PasswordCipher.globalPrefix
                )
            )
        )
        try context.save()

        let protection = ProtectionService(defaults: defaults)
        XCTAssertThrowsError(try protection.recoverPendingConfiguration(context: context)) { error in
            guard let protectionError = error as? ProtectionError,
                  case .inconsistentGlobalProtectionState = protectionError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(protection.globalProtectionEnabled)
    }

    @MainActor
    func testProtectionRecoveryRejectsUnreadableAtomicConfiguration() throws {
        let suiteName = "ShardsCoreTests.ProtectionUnreadableConfiguration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let invalidData = Data("not a protection record".utf8)
        defaults.set(invalidData, forKey: AppSettingKeys.globalProtectionConfiguration)
        let protection = ProtectionService(defaults: defaults)

        XCTAssertThrowsError(
            try protection.recoverPendingConfiguration(context: makeInMemoryVault().mainContext)
        ) { error in
            guard let protectionError = error as? ProtectionError,
                  case .inconsistentGlobalProtectionState = protectionError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            defaults.data(forKey: AppSettingKeys.globalProtectionConfiguration),
            invalidData
        )
    }

    @MainActor
    func testGlobalProtectionDisableRollsBackEveryShardWhenOneCiphertextIsInvalid() throws {
        let suiteName = "ShardsCoreTests.ProtectionRollback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try makeInMemoryVault()
        let context = container.mainContext
        let first = Shard(id: "global-valid", payload: "first secret")
        let second = Shard(id: "global-corrupt", payload: "second secret")
        context.insert(first)
        context.insert(second)
        try context.save()
        let protection = ProtectionService(defaults: defaults)
        try protection.enableGlobalProtection(password: "rollback password", context: context)
        let firstEncryptedPayload = first.payload
        second.payload = "GLB1:not-valid"
        try context.save()

        XCTAssertThrowsError(
            try protection.disableGlobalProtection(password: "rollback password", context: context)
        )

        XCTAssertTrue(defaults.bool(forKey: AppSettingKeys.globalProtectionEnabled))
        XCTAssertTrue(protection.globalProtectionEnabled)
        let verificationContext = ModelContext(container)
        let persisted = try verificationContext.fetch(FetchDescriptor<Shard>())
        XCTAssertEqual(persisted.first(where: { $0.id == first.id })?.encryptionMode, .global)
        XCTAssertEqual(persisted.first(where: { $0.id == first.id })?.payload, firstEncryptedPayload)
        XCTAssertEqual(persisted.first(where: { $0.id == second.id })?.encryptionMode, .global)
        XCTAssertEqual(persisted.first(where: { $0.id == second.id })?.payload, "GLB1:not-valid")
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

    func testSchemaV2PreservesUnknownFieldTypesWithoutDiscardingTemplate() throws {
        let data = Data(#"{"fields":[{"key":"serial","name":"Serial","valueType":"vendorSerial"}]}"#.utf8)

        let decoded = try JSONDecoder().decode(PresetTemplateSchema.self, from: data)
        let field = try XCTUnwrap(decoded.fields.first)
        XCTAssertEqual(field.valueType, .custom("vendorSerial"))
        XCTAssertEqual(field.id, "serial")
        XCTAssertFalse(field.isRequired)

        let roundTripped = try JSONDecoder().decode(
            PresetTemplateSchema.self,
            from: JSONEncoder().encode(decoded)
        )
        XCTAssertEqual(roundTripped.fields.first?.valueType.rawValue, "vendorSerial")
    }

    func testLicenseKeyMetadataSurvivesPayloadRoundTrip() throws {
        let definition = PresetFieldDefinition(
            key: "license_key",
            name: "Activation Code",
            valueType: .licenseKey,
            isRequired: true
        )
        var field = definition.emptyValue
        field.value = "AAAA-BBBB-CCCC"
        let payload = PresetPayload(presetType: "License Key", fields: [field])

        let decoded = try JSONDecoder().decode(
            PresetPayload.self,
            from: JSONEncoder().encode(payload)
        )
        let decodedField = try XCTUnwrap(decoded.fields.first)

        XCTAssertEqual(decodedField.key, "license_key")
        XCTAssertEqual(decodedField.valueType, .licenseKey)
        XCTAssertEqual(decodedField.isSensitive, true)
        XCTAssertTrue(decodedField.isEffectivelySensitive)
        XCTAssertEqual(decoded.safePreviewText, "Sensitive content")
        XCTAssertFalse(decoded.safeSearchableContent.contains("AAAA-BBBB-CCCC"))
    }

    func testLegacyPayloadResolvesPrivacyFromSchemaByStableKeyOrName() throws {
        let legacyData = Data(#"{"presetType":"License","fields":[{"name":"Activation Code","value":"SECRET-123","isRequired":true}]}"#.utf8)
        let payload = try JSONDecoder().decode(PresetPayload.self, from: legacyData)
        let schema = PresetTemplateSchema(
            summary: "License",
            fields: [
                PresetFieldDefinition(
                    id: "new-schema-id",
                    key: "activation_code",
                    name: "Activation Code",
                    valueType: .licenseKey,
                    isRequired: true
                )
            ]
        )

        let resolved = payload.resolvingMetadata(using: schema)

        XCTAssertEqual(resolved.fields.first?.key, "activation_code")
        XCTAssertTrue(try XCTUnwrap(resolved.fields.first).isEffectivelySensitive)
        XCTAssertEqual(resolved.safePreviewText, "Sensitive content")
    }

    func testSafePreviewSkipsSensitiveFieldsAndSafeDisplayNameRejectsSecrets() {
        let schema = PresetTemplateSchema(
            summary: "License",
            titleFieldKey: "product",
            displayFormat: "{license_key}",
            fields: [
                PresetFieldDefinition(key: "product", name: "Product", valueType: .text),
                PresetFieldDefinition(key: "license_key", name: "License Key", valueType: .licenseKey)
            ]
        )
        let payload = PresetPayload(
            presetType: "License",
            fields: [
                PresetField(key: "license_key", name: "License Key", value: "SECRET-123", valueType: .licenseKey),
                PresetField(key: "product", name: "Product", value: "Acme Studio", valueType: .text)
            ]
        ).resolvingMetadata(using: schema)

        XCTAssertEqual(payload.safePreviewText, "Acme Studio")
        XCTAssertEqual(payload.titleCandidate, "Acme Studio")
        XCTAssertNil(schema.safeDisplayName(for: payload))
        XCTAssertTrue(payload.displayNameExposesSensitiveValue("Acme Studio - SECRET-123"))
        XCTAssertEqual(payload.redactedPlainTextContent, "License Key: ••••••••\nProduct: Acme Studio")
    }

    func testMalformedStructuredPayloadStaysHiddenByDefault() {
        let raw = #"{"presetType":"Token","fields":[{"name":"Token Content","value":["SECRET-123"]}]}"#

        guard case .malformedStructured = PresetPayload.decoding(raw) else {
            return XCTFail("A malformed structured payload must not fall back to plain text")
        }
    }

    func testOrdinaryJSONWithPresetTypeKeyRemainsPlainText() {
        let raw = #"{"presetType":"Note","custom":"must remain untouched"}"#

        guard case .plainText = PresetPayload.decoding(raw) else {
            return XCTFail("Ordinary JSON must not be rewritten as a structured shard")
        }
    }

    func testStructuredFieldsWithoutPresetTypeStayHidden() {
        let raw = #"{"fields":[{"name":"Token Content","value":"sk-secret"}]}"#

        guard case .malformedStructured = PresetPayload.decoding(raw) else {
            return XCTFail("A damaged structured secret must remain hidden")
        }
    }

    func testUnknownPresentationStyleSurvivesSchemaRoundTrip() throws {
        let data = Data(#"{"version":3,"summary":"Future","presentationStyle":"cards","fields":[]}"#.utf8)
        let schema = try JSONDecoder().decode(PresetTemplateSchema.self, from: data)
        let roundTripped = try JSONDecoder().decode(
            PresetTemplateSchema.self,
            from: JSONEncoder().encode(schema)
        )

        XCTAssertEqual(schema.presentationStyle, .custom("cards"))
        XCTAssertEqual(roundTripped.presentationStyle, .custom("cards"))
    }

    func testTemplateEditorPreservesUnknownSchemaMetadata() throws {
        let schemaJSON = #"{"version":3,"summary":"Original","useCases":["activation"],"outputNotes":"Keep this","futureTop":{"enabled":true},"fields":[{"id":"license_key","key":"license_key","name":"License Key","valueType":"vendorSecret","isRequired":true,"isSensitive":true,"validation":{"pattern":"[A-Z]+"}}]}"#
        let template = PresetTemplate(
            name: "Vendor License",
            symbol: "key",
            targetCollectionName: "Shards",
            schemaFieldsJSON: schemaJSON
        )
        var draft = TemplateEditorDraft.editing(template)
        draft.summary = "Edited"
        draft.fields[0].name = "Activation Code"

        let data = try XCTUnwrap(draft.encodedSchemaJSON().data(using: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let fields = try XCTUnwrap(object["fields"] as? [[String: Any]])
        let firstField = try XCTUnwrap(fields.first)

        XCTAssertEqual(object["version"] as? Int, 3)
        XCTAssertEqual(object["summary"] as? String, "Edited")
        XCTAssertEqual(object["useCases"] as? [String], ["activation"])
        XCTAssertEqual(object["outputNotes"] as? String, "Keep this")
        XCTAssertNotNil(object["futureTop"])
        XCTAssertEqual(firstField["name"] as? String, "Activation Code")
        XCTAssertNotNil(firstField["validation"])
    }

    func testSchemaCanStrengthenPrivacyForExistingPayload() throws {
        let payload = PresetPayload(
            presetType: "License",
            fields: [
                PresetField(
                    key: "activation_code",
                    name: "Activation Code",
                    value: "SECRET-123",
                    valueType: .text,
                    isSensitive: false
                )
            ]
        )
        let schema = PresetTemplateSchema(
            summary: "License",
            fields: [
                PresetFieldDefinition(
                    key: "activation_code",
                    name: "Activation Code",
                    valueType: .licenseKey
                )
            ]
        )

        let field = try XCTUnwrap(payload.resolvingMetadata(using: schema).fields.first)
        XCTAssertTrue(field.isEffectivelySensitive)
    }

    func testLegacySensitiveNamesRemainHiddenWithoutSchema() {
        for name in ["Token Content", "Password Value", "Activation Code", "License Key"] {
            XCTAssertTrue(
                PresetField(name: name, value: "SECRET").isEffectivelySensitive,
                "Expected \(name) to be treated as sensitive"
            )
        }
    }

    func testPayloadDecoderRepairsDuplicateFieldIDsDeterministically() throws {
        let data = Data(#"{"presetType":"Custom","fields":[{"id":"value","name":"First","value":"1"},{"id":"value","name":"Second","value":"2"}]}"#.utf8)

        let payload = try JSONDecoder().decode(PresetPayload.self, from: data)

        XCTAssertEqual(payload.fields.map(\.id), ["value", "value-2"])
    }

    func testTemplateIDSurvivesRenameForSchemaMatching() {
        let template = PresetTemplate(
            id: "template-id",
            name: "Renamed Template",
            symbol: "doc",
            targetCollectionName: "Shards",
            schemaFieldsJSON: "{}",
            orderIndex: 0
        )
        let payload = PresetPayload(
            presetType: "Old Template Name",
            fields: [],
            templateID: template.id
        )

        XCTAssertEqual([template].matchingTemplate(for: payload)?.id, template.id)
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

    func testQuickEntryModeTransferDoesNotCarrySensitiveValues() {
        let secret = PresetField(
            key: "license_key",
            name: "License Key",
            value: "AAAA-BBBB",
            valueType: .licenseKey,
            isSensitive: true
        )

        XCTAssertNil(
            QuickEntryModeTransferPolicy.seedText(
                from: "AAAA-BBBB",
                sourceField: secret
            )
        )
    }

    func testQuickEntryModeTransferCanCarryOrdinaryText() {
        let content = PresetField(
            key: "content",
            name: "Content",
            value: "A thought"
        )

        XCTAssertEqual(
            QuickEntryModeTransferPolicy.seedText(
                from: "A thought",
                sourceField: content
            ),
            "A thought"
        )
    }

    func testQuickEntryReturnSkipsBlankOptionalMiddleField() {
        let field = PresetField(name: "Licensee", value: "", isRequired: false)

        XCTAssertEqual(
            QuickEntryFormPolicy.submissionOutcome(
                field: field,
                input: "   ",
                currentIndex: 1,
                fieldCount: 4
            ),
            .advance(nextIndex: 2, skippedOptionalField: true)
        )
    }

    func testQuickEntryReturnSavesWhenLastOptionalFieldIsBlank() {
        let field = PresetField(name: "Note", value: "", isRequired: false)

        XCTAssertEqual(
            QuickEntryFormPolicy.submissionOutcome(
                field: field,
                input: "",
                currentIndex: 3,
                fieldCount: 4
            ),
            .save(skippedOptionalField: true)
        )
    }

    func testQuickEntryReturnBlocksBlankRequiredField() {
        let field = PresetField(name: "License Key", value: "", isRequired: true)

        XCTAssertEqual(
            QuickEntryFormPolicy.submissionOutcome(
                field: field,
                input: "\n",
                currentIndex: 2,
                fieldCount: 4
            ),
            .blocked(requiredFieldName: "License Key")
        )
    }

    func testTemplateEditorRejectsDuplicateStableKeys() {
        var draft = TemplateEditorDraft.blank(collectionName: "Shards")
        draft.name = "Project"
        draft.fields = [
            TemplateFieldDraft(key: "project", name: "Project"),
            TemplateFieldDraft(key: "project", name: "Duplicate")
        ]

        XCTAssertEqual(
            draft.validationMessage(existingTemplateNames: []),
            "Field keys must be unique."
        )
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
    func testDefaultRepositorySavePlacesShardInShardsCategory() throws {
        let container = try makeInMemoryVault()
        let context = container.mainContext
        let shardsCollection = ShardCollection(
            id: "shards-category",
            name: VaultContainer.Defaults.shardsCollectionName,
            icon: VaultContainer.Defaults.shardsCollectionIcon
        )
        context.insert(shardsCollection)
        try context.save()

        let repository = VaultRepository(container: container)
        let shard = try repository.saveRawText("Categorized by default")

        XCTAssertEqual(shard.collectionId, shardsCollection.id)
    }

    @MainActor
    func testRepositoryRejectsWritesWhenPersistentStoreIsUnavailable() throws {
        let container = try makeInMemoryVault()
        let repository = VaultRepository(container: container, writesAllowed: { false })

        XCTAssertThrowsError(try repository.saveRawText("Must not be temporary")) { error in
            guard case VaultRepositoryError.storeUnavailable = error else {
                return XCTFail("Expected storeUnavailable, received \(error)")
            }
        }
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Shard>()).isEmpty)
    }

    @MainActor
    func testRepositorySaveDoesNotCommitUnrelatedEditorDraft() throws {
        let container = try makeInMemoryVault()
        let mainContext = container.mainContext
        let existing = Shard(id: "existing-draft", payload: "Persisted")
        mainContext.insert(existing)
        try mainContext.save()
        existing.payload = "Unsaved editor draft"

        let repository = VaultRepository(container: container)
        let captured = try repository.saveRawText("Independent capture")

        XCTAssertTrue(mainContext.hasChanges)
        XCTAssertEqual(existing.payload, "Unsaved editor draft")
        let verificationContext = ModelContext(container)
        let persisted = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<Shard>()).first(where: { $0.id == existing.id })
        )
        XCTAssertEqual(persisted.payload, "Persisted")
        XCTAssertEqual(
            try verificationContext.fetch(FetchDescriptor<Shard>()).first(where: { $0.id == captured.id })?.payload,
            "Independent capture"
        )
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
        let liveID = live.id
        let trashID = trash.id
        let lockedTrashID = lockedTrash.id
        let lockedAttachmentID = lockedAttachment.id
        context.insert(lockedTag)
        [live, trash, lockedTrash].forEach(context.insert)
        [trashAttachment, lockedAttachment].forEach(context.insert)
        try context.save()

        let repository = VaultRepository(container: container)
        let receipt = try repository.permanentlyDelete(
            shardIDs: [liveID, trashID, lockedTrashID, "missing"],
            lockedTagID: lockedTag.id
        )

        XCTAssertEqual(receipt.deletedIDs, [trashID])
        XCTAssertEqual(receipt.skippedLiveIDs, [liveID])
        XCTAssertEqual(receipt.skippedLockedIDs, [lockedTrashID])
        XCTAssertEqual(receipt.missingIDs, ["missing"])
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Shard>()).map(\.id)), [liveID, lockedTrashID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ShardAttachment>()).map(\.id), [lockedAttachmentID])
    }

    @MainActor
    func testPermanentDeleteReceiptUsesStablePreDeletionIDs() throws {
        let container = try makeInMemoryVault()
        let context = container.mainContext
        let shard = Shard(id: "delete-order", deletedAt: Date(), payload: "Delete me")
        let shardID = shard.id
        context.insert(shard)
        try context.save()

        let receipt = try ShardBatchService(context: context).permanentlyDelete(
            shardIDs: [shardID],
            lockedTagID: nil
        )

        XCTAssertEqual(receipt.deletedIDs, [shardID])
        XCTAssertTrue(try context.fetch(FetchDescriptor<Shard>()).isEmpty)
    }

    @MainActor
    func testPermanentDeleteRefusesWhileMainContextHasPendingChanges() throws {
        let container = try makeInMemoryVault()
        let mainContext = container.mainContext
        let live = Shard(id: "live-draft-during-delete", payload: "Persisted")
        let trash = Shard(id: "isolated-permanent-delete", deletedAt: Date(), payload: "Trash")
        let trashID = trash.id
        mainContext.insert(live)
        mainContext.insert(trash)
        try mainContext.save()

        live.payload = "Unsaved draft"
        XCTAssertTrue(mainContext.hasChanges)
        let successNotificationCount = TestStateBox(0)
        let observer = NotificationCenter.default.addObserver(
            forName: .shardsWerePermanentlyDeleted,
            object: nil,
            queue: .main
        ) { _ in
            successNotificationCount.update { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let repository = VaultRepository(container: container)
        XCTAssertThrowsError(
            try repository.permanentlyDelete(shardIDs: [trashID], lockedTagID: nil)
        ) { error in
            XCTAssertEqual(error as? ShardBatchError, .pendingChanges)
        }
        XCTAssertTrue(mainContext.hasChanges)
        XCTAssertEqual(live.payload, "Unsaved draft")
        XCTAssertEqual(successNotificationCount.value, 0)

        let verificationContext = ModelContext(container)
        let persisted = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<Shard>()).first(where: { $0.id == live.id })
        )
        XCTAssertEqual(persisted.payload, "Persisted")
        XCTAssertTrue(
            try verificationContext.fetch(FetchDescriptor<Shard>()).contains(where: { $0.id == trashID })
        )
    }

    @MainActor
    func testDetailBindingAccessStopsBeforeDereferencingADeletedModel() throws {
        let container = try makeInMemoryVault()
        let context = container.mainContext
        let trash = Shard(id: "stale-detail-binding", deletedAt: Date(), payload: "Delete while editing")
        let trashID = trash.id
        context.insert(trash)
        try context.save()

        // This array models a TextField/TextEditor Binding that outlives the
        // detail selection for one render pass.
        let staleViewModels = [trash]
        let isActive = TestStateBox(true)
        let notifiedIDs = TestStateBox<[String]>([])
        var resolveCount = 0
        var writeCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .shardsWerePermanentlyDeleted,
            object: nil,
            queue: .main
        ) { notification in
            guard let shardIDs = notification.object as? [String] else { return }
            notifiedIDs.update { $0 = shardIDs }
            if shardIDs.contains(trashID) {
                isActive.update { $0 = false }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let binding = ShardDetailBindingAccess.binding(
            shardID: trashID,
            fallback: "Unavailable",
            isActive: { isActive.value },
            resolve: { id in
                resolveCount += 1
                return staleViewModels.first(where: { $0.id == id })
            },
            read: { $0.payload },
            write: { shard, value in
                writeCount += 1
                shard.payload = value
            }
        )
        XCTAssertEqual(binding.wrappedValue, "Delete while editing")
        let resolveCountBeforeDeletion = resolveCount

        let receipt = try VaultRepository(container: container).permanentlyDelete(
            shardIDs: [trashID],
            lockedTagID: nil
        )
        XCTAssertEqual(receipt.deletedIDs, [trashID])
        XCTAssertEqual(notifiedIDs.value, [trashID])
        XCTAssertFalse(isActive.value)

        // The success notification closes the selection gate before the old
        // Binding is accessed again. It must return without reading `id` (or
        // any other property) from the stale SwiftData model it still retains.
        XCTAssertEqual(binding.wrappedValue, "Unavailable")
        binding.wrappedValue = "Must not be written"
        XCTAssertEqual(resolveCount, resolveCountBeforeDeletion)
        XCTAssertEqual(writeCount, 0)
        XCTAssertFalse(context.hasChanges)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<Shard>()).isEmpty)
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

    func testSpotlightBuildsSearchableRawShardWithStableIdentifier() throws {
        let snapshot = makeSpotlightSnapshot(
            id: "raw-id",
            displayName: "Project thought",
            payload: "A distinctive local-first capture",
            tagNames: ["Ideas", "Ideas"]
        )

        let document = try XCTUnwrap(SpotlightDocumentBuilder.document(from: snapshot))

        XCTAssertEqual(document.itemIdentifier, "shard:raw-id")
        XCTAssertEqual(document.title, "Project thought")
        XCTAssertEqual(document.textContent, "A distinctive local-first capture")
        XCTAssertEqual(document.keywords, ["Ideas", "Shards", "Shard"])
        XCTAssertEqual(SpotlightItemIdentifier.shardID(from: document.itemIdentifier), "raw-id")
        XCTAssertNil(SpotlightItemIdentifier.shardID(from: "not-a-shard"))
    }

    func testSpotlightStructuredShardNeverIncludesSensitiveFieldsOrSensitiveTitle() throws {
        let schema = PresetTemplateSchema(
            summary: "API credential",
            presentationStyle: .table,
            displayFormat: "{platform} - {name}",
            fields: [
                PresetFieldDefinition(key: "platform", name: "Platform"),
                PresetFieldDefinition(key: "name", name: "Name"),
                PresetFieldDefinition(
                    key: "token_content",
                    name: "Token Content",
                    valueType: .secret,
                    isRequired: true
                )
            ]
        )
        let payload = PresetPayload(
            presetType: "Token",
            fields: [
                PresetField(key: "platform", name: "Platform", value: "Example Cloud"),
                PresetField(key: "name", name: "Name", value: "Production"),
                PresetField(
                    key: "token_content",
                    name: "Token Content",
                    value: "secret-token-value",
                    valueType: .secret,
                    isSensitive: true
                )
            ]
        )
        let payloadData = try JSONEncoder().encode(payload)
        let snapshot = makeSpotlightSnapshot(
            displayName: "Example Cloud - secret-token-value",
            payload: try XCTUnwrap(String(data: payloadData, encoding: .utf8)),
            collectionName: "Tokens",
            schema: schema
        )

        let document = try XCTUnwrap(SpotlightDocumentBuilder.document(from: snapshot))

        XCTAssertEqual(document.title, "Example Cloud - Production")
        XCTAssertTrue(document.textContent.contains("Example Cloud"))
        XCTAssertTrue(document.textContent.contains("Production"))
        XCTAssertFalse(document.title.contains("secret-token-value"))
        XCTAssertFalse(document.textContent.contains("secret-token-value"))
        XCTAssertFalse(document.contentDescription?.contains("secret-token-value") == true)
    }

    func testSpotlightExcludesFreeformTextFromSensitiveCollections() throws {
        XCTAssertNil(SpotlightDocumentBuilder.document(from: makeSpotlightSnapshot(
            payload: "plain-text-secret",
            collectionName: "Passwords"
        )))
        XCTAssertNil(SpotlightDocumentBuilder.document(from: makeSpotlightSnapshot(
            payload: "plain-text-secret",
            collectionName: "Tokens"
        )))
        XCTAssertNil(SpotlightDocumentBuilder.document(from: makeSpotlightSnapshot(
            payload: "AAAA-BBBB-CCCC",
            collectionName: "License Keys"
        )))
        XCTAssertNil(SpotlightDocumentBuilder.document(from: makeSpotlightSnapshot(
            payload: "中文敏感内容",
            collectionName: "许可证密钥"
        )))

        let shardPayload = PresetPayload(
            presetType: "Shard",
            fields: [PresetField(name: "Content", value: "structured-freeform-secret")]
        )
        let shardData = try JSONEncoder().encode(shardPayload)
        XCTAssertNil(SpotlightDocumentBuilder.document(from: makeSpotlightSnapshot(
            payload: try XCTUnwrap(String(data: shardData, encoding: .utf8)),
            collectionName: "Tokens"
        )))
    }

    func testSpotlightSchemaCanStrengthenImportedFieldPrivacy() throws {
        let schema = PresetTemplateSchema(
            summary: "License",
            fields: [
                PresetFieldDefinition(
                    key: "license_key",
                    name: "License Key",
                    valueType: .licenseKey,
                    isSensitive: true
                ),
                PresetFieldDefinition(key: "product", name: "Product")
            ]
        )
        let payload = PresetPayload(
            presetType: "License",
            fields: [
                PresetField(
                    key: "license_key",
                    name: "License Key",
                    value: "AAAA-BBBB-CCCC",
                    isSensitive: false
                ),
                PresetField(key: "product", name: "Product", value: "Example App")
            ]
        )
        let data = try JSONEncoder().encode(payload)
        let snapshot = makeSpotlightSnapshot(
            payload: try XCTUnwrap(String(data: data, encoding: .utf8)),
            schema: schema
        )

        let document = try XCTUnwrap(SpotlightDocumentBuilder.document(from: snapshot))

        XCTAssertFalse(document.textContent.contains("AAAA-BBBB-CCCC"))
        XCTAssertTrue(document.textContent.contains("Example App"))
    }

    func testSpotlightExcludesPrivateDeletedAndMalformedShards() {
        XCTAssertNil(SpotlightDocumentBuilder.document(from: makeSpotlightSnapshot(encryptionMode: .global)))
        XCTAssertNil(SpotlightDocumentBuilder.document(from: makeSpotlightSnapshot(encryptionMode: .perShard)))
        XCTAssertNil(SpotlightDocumentBuilder.document(from: makeSpotlightSnapshot(isHidden: true)))
        XCTAssertNil(SpotlightDocumentBuilder.document(from: makeSpotlightSnapshot(isLocked: true)))
        XCTAssertNil(SpotlightDocumentBuilder.document(from: makeSpotlightSnapshot(deletedAt: Date())))
        XCTAssertNil(SpotlightDocumentBuilder.document(from: makeSpotlightSnapshot(
            payload: #"{"presetType":"Token","fields":[{"name":"Token","value":"secret"}]}"#
                .replacingOccurrences(of: "]}", with: "")
        )))
    }

    private func makeSpotlightSnapshot(
        id: String = "spotlight-id",
        displayName: String? = nil,
        payload: String = "A searchable shard",
        collectionName: String = "Shards",
        tagNames: [String] = [],
        isHidden: Bool = false,
        isLocked: Bool = false,
        encryptionMode: EncryptionMode = .none,
        deletedAt: Date? = nil,
        schema: PresetTemplateSchema? = nil
    ) -> SpotlightShardSnapshot {
        SpotlightShardSnapshot(
            id: id,
            collectionID: "shards-collection",
            collectionName: collectionName,
            tagNames: tagNames,
            isHidden: isHidden,
            isLocked: isLocked,
            encryptionMode: encryptionMode,
            isPinned: false,
            displayName: displayName,
            deletedAt: deletedAt,
            payload: payload,
            schema: schema,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
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
