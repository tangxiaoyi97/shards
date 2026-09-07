import Combine
import CryptoKit
import Foundation
import SwiftData

enum ProtectionError: LocalizedError {
    case emptyPassword
    case invalidPassword
    case globalProtectionDisabled
    case globalProtectionLocked
    case shardNotProtected
    case shardAlreadyProtected
    case shardLocked
    case configurationPersistenceFailed
    case inconsistentGlobalProtectionState

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "Password cannot be empty."
        case .invalidPassword:
            return "The password is incorrect."
        case .globalProtectionDisabled:
            return "Global protection is not enabled."
        case .globalProtectionLocked:
            return "Unlock the protected vault before saving or viewing content."
        case .shardNotProtected:
            return "This shard is not protected."
        case .shardAlreadyProtected:
            return "This shard is already protected."
        case .shardLocked:
            return "Unlock this protected shard before editing it."
        case .configurationPersistenceFailed:
            return "The protection configuration could not be saved. The vault was not changed."
        case .inconsistentGlobalProtectionState:
            return "The protected vault state is inconsistent. Editing is disabled to avoid encrypting content with the wrong password."
        }
    }
}

struct GlobalProtectionConfiguration: Codable, Equatable {
    enum State: String, Codable {
        case pendingEnable
        case pendingDisable
        case enabled
    }

    let version: Int
    let state: State
    let salt: String
    let verifier: String
    let preGlobalCount: Int
    let expectedPostGlobalCount: Int

    private enum CodingKeys: String, CodingKey {
        case version
        case state
        case salt
        case verifier
        case preGlobalCount
        case expectedPostGlobalCount
        case expectedConvertedCount
    }

    init(
        version: Int,
        state: State,
        salt: String,
        verifier: String,
        preGlobalCount: Int,
        expectedPostGlobalCount: Int
    ) {
        self.version = version
        self.state = state
        self.salt = salt
        self.verifier = verifier
        self.preGlobalCount = preGlobalCount
        self.expectedPostGlobalCount = expectedPostGlobalCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        state = try container.decode(State.self, forKey: .state)
        salt = try container.decode(String.self, forKey: .salt)
        verifier = try container.decode(String.self, forKey: .verifier)

        switch version {
        case 2:
            // Compatibility with the short-lived v2 record. Enabling was only
            // safe from a vault without existing global rows, so its converted
            // count is the expected post-transaction total.
            self.preGlobalCount = 0
            self.expectedPostGlobalCount = try container.decode(
                Int.self,
                forKey: .expectedConvertedCount
            )
        case 3:
            self.preGlobalCount = try container.decode(Int.self, forKey: .preGlobalCount)
            self.expectedPostGlobalCount = try container.decode(
                Int.self,
                forKey: .expectedPostGlobalCount
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported global protection configuration version."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(state, forKey: .state)
        try container.encode(salt, forKey: .salt)
        try container.encode(verifier, forKey: .verifier)
        try container.encode(preGlobalCount, forKey: .preGlobalCount)
        try container.encode(expectedPostGlobalCount, forKey: .expectedPostGlobalCount)
    }

    func promotedToEnabled() -> Self {
        Self(
            version: 3,
            state: .enabled,
            salt: salt,
            verifier: verifier,
            preGlobalCount: 0,
            expectedPostGlobalCount: 0
        )
    }
}

enum PasswordCipher {
    static let globalPrefix = "GLB1"
    static let shardPrefix = "PRT1"

    static func makeVerifier(password: String, salt: Data) -> String {
        let digest = SHA256.hash(data: salt + normalizedPasswordData(password) + Data("verifier".utf8))
        return Data(digest).base64EncodedString()
    }

    static func encrypt(_ plaintext: String, password: String, prefix: String) throws -> String {
        let salt = randomSalt()
        let key = deriveKey(password: password, salt: salt)
        guard let payload = plaintext.data(using: .utf8) else {
            throw ProtectionError.invalidPassword
        }

        let sealedBox = try AES.GCM.seal(payload, using: key)
        guard let combined = sealedBox.combined else {
            throw ProtectionError.invalidPassword
        }

        return "\(prefix):\(salt.base64EncodedString()):\(combined.base64EncodedString())"
    }

    static func decrypt(_ ciphertext: String, password: String, expectedPrefix: String) throws -> String {
        let parts = ciphertext.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == Substring(expectedPrefix),
              let salt = Data(base64Encoded: String(parts[1])),
              let combined = Data(base64Encoded: String(parts[2]))
        else {
            throw ProtectionError.invalidPassword
        }

        let key = deriveKey(password: password, salt: salt)
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        let decrypted = try AES.GCM.open(sealedBox, using: key)
        guard let plaintext = String(data: decrypted, encoding: .utf8) else {
            throw ProtectionError.invalidPassword
        }
        return plaintext
    }

    private static func randomSalt() -> Data {
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes)
    }

    private static func deriveKey(password: String, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: normalizedPasswordData(password)),
            salt: salt,
            info: Data("ShardsProtection".utf8),
            outputByteCount: 32
        )
    }

    private static func normalizedPasswordData(_ password: String) -> Data {
        Data(password.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }
}

@MainActor
final class ProtectionService: ObservableObject {
    static let shared = ProtectionService()

    @Published private(set) var globalProtectionEnabled = false
    @Published private(set) var globalUnlocked = true

    private let defaults: UserDefaults
    private var globalSessionPassword: String?
    private var shardSessionPasswords: [String: String] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refreshConfiguration()
    }

    var requiresGlobalUnlock: Bool {
        globalProtectionEnabled && globalSessionPassword == nil
    }

    func refreshConfiguration() {
        globalProtectionEnabled = protectionConfiguration()?.state == .enabled
        if !globalProtectionEnabled {
            globalUnlocked = true
            globalSessionPassword = nil
        } else {
            globalUnlocked = globalSessionPassword != nil
        }
    }

    /// Resolves process-interruption windows in global protection by comparing
    /// a durable pending configuration with the SwiftData transaction result.
    /// Exact before/after row counts distinguish a committed conversion from
    /// an interrupted one. Any mixed state is preserved and rejected rather
    /// than guessing which password encrypted which rows.
    func recoverPendingConfiguration(context: ModelContext) throws {
        guard let configuration = storedConfiguration() else {
            let hasUnreadableConfiguration = defaults.object(
                forKey: AppSettingKeys.globalProtectionConfiguration
            ) != nil
            guard !hasUnreadableConfiguration,
                  try globalShardCount(in: context) == 0
            else {
                throw ProtectionError.inconsistentGlobalProtectionState
            }
            refreshConfiguration()
            return
        }
        guard configuration.state != .enabled else {
            refreshConfiguration()
            return
        }

        let globalCount = try globalShardCount(in: context)

        switch configuration.state {
        case .pendingEnable:
            guard configuration.preGlobalCount >= 0,
                  configuration.expectedPostGlobalCount >= configuration.preGlobalCount
            else {
                throw ProtectionError.inconsistentGlobalProtectionState
            }

            if configuration.expectedPostGlobalCount == configuration.preGlobalCount {
                // A zero-row conversion cannot be distinguished from an intent
                // written immediately before a crash. Disabling is the safer and
                // fully recoverable outcome because no payload changed.
                guard globalCount == configuration.preGlobalCount else {
                    throw ProtectionError.inconsistentGlobalProtectionState
                }
                guard clearConfiguration() else {
                    throw ProtectionError.configurationPersistenceFailed
                }
            } else if globalCount == configuration.expectedPostGlobalCount {
                guard persistConfiguration(configuration.promotedToEnabled(), mirrorLegacy: true) else {
                    throw ProtectionError.configurationPersistenceFailed
                }
            } else if globalCount == configuration.preGlobalCount {
                guard clearConfiguration() else {
                    throw ProtectionError.configurationPersistenceFailed
                }
            } else {
                throw ProtectionError.inconsistentGlobalProtectionState
            }

        case .pendingDisable:
            guard configuration.preGlobalCount >= 0,
                  configuration.expectedPostGlobalCount == 0
            else {
                throw ProtectionError.inconsistentGlobalProtectionState
            }

            if globalCount == configuration.expectedPostGlobalCount {
                // The plaintext transaction committed. Finish disabling while
                // keeping the pending record durable until legacy mirrors are gone.
                guard clearConfiguration() else {
                    throw ProtectionError.configurationPersistenceFailed
                }
            } else if globalCount == configuration.preGlobalCount {
                // The transaction never committed. Restore the enabled record;
                // all global rows still use the verifier's password.
                guard persistConfiguration(configuration.promotedToEnabled(), mirrorLegacy: true) else {
                    throw ProtectionError.configurationPersistenceFailed
                }
            } else {
                // Some, but not all, rows changed. Do not guess or discard the
                // verifier because doing so could expose or strand payloads.
                throw ProtectionError.inconsistentGlobalProtectionState
            }

        case .enabled:
            break
        }
        refreshConfiguration()
    }

    func desiredEncryptionModeForNewShard() -> EncryptionMode {
        globalProtectionEnabled ? .global : .none
    }

    func canAccess(_ shard: Shard) -> Bool {
        switch shard.encryptionMode {
        case .none:
            return true
        case .global:
            return globalSessionPassword != nil
        case .perShard:
            return shardSessionPasswords[shard.id] != nil
        }
    }

    func isShardUnlocked(_ shard: Shard) -> Bool {
        shardSessionPasswords[shard.id] != nil
    }

    func lockGlobalSession() {
        guard globalProtectionEnabled else { return }
        globalSessionPassword = nil
        globalUnlocked = false
        shardSessionPasswords.removeAll()
    }

    func lockShardSession(_ shard: Shard) {
        shardSessionPasswords.removeValue(forKey: shard.id)
    }

    func forgetShardSessions(withIDs shardIDs: some Sequence<String>) {
        for shardID in shardIDs {
            shardSessionPasswords.removeValue(forKey: shardID)
        }
    }

    func unlockGlobal(password: String) throws {
        guard globalProtectionEnabled else {
            throw ProtectionError.globalProtectionDisabled
        }
        guard verifyGlobalPassword(password) else {
            throw ProtectionError.invalidPassword
        }
        globalSessionPassword = normalizedPassword(password)
        globalUnlocked = true
    }

    func enableGlobalProtection(password: String, context: ModelContext) throws {
        let normalized = normalizedPassword(password)
        guard !normalized.isEmpty else {
            throw ProtectionError.emptyPassword
        }

        let shards = try context.fetch(FetchDescriptor<Shard>())
        let preGlobalCount = shards.lazy.filter { $0.encryptionMode == .global }.count
        let existingConfiguration = storedConfiguration()
        let hasConfigurationRecord = defaults.object(
            forKey: AppSettingKeys.globalProtectionConfiguration
        ) != nil
        guard !globalProtectionEnabled,
              existingConfiguration == nil,
              !hasConfigurationRecord,
              preGlobalCount == 0
        else {
            throw ProtectionError.inconsistentGlobalProtectionState
        }

        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let verifier = PasswordCipher.makeVerifier(password: normalized, salt: salt)
        let convertibleShards = shards.filter { $0.encryptionMode == .none }
        let pendingConfiguration = GlobalProtectionConfiguration(
            version: 3,
            state: .pendingEnable,
            salt: salt.base64EncodedString(),
            verifier: verifier,
            preGlobalCount: preGlobalCount,
            expectedPostGlobalCount: preGlobalCount + convertibleShards.count
        )
        guard persistConfiguration(pendingConfiguration, mirrorLegacy: false) else {
            clearConfiguration()
            throw ProtectionError.configurationPersistenceFailed
        }

        do {
            let timestamp = Date()
            for shard in convertibleShards {
                shard.payload = try PasswordCipher.encrypt(
                    shard.payload,
                    password: normalized,
                    prefix: PasswordCipher.globalPrefix
                )
                shard.encryptionMode = .global
                shard.updatedAt = timestamp
            }
            try context.save()
        } catch {
            context.rollback()
            clearConfiguration()
            throw error
        }

        let enabledConfiguration = GlobalProtectionConfiguration(
            version: 3,
            state: .enabled,
            salt: salt.base64EncodedString(),
            verifier: verifier,
            preGlobalCount: 0,
            expectedPostGlobalCount: 0
        )
        // The durable pending record was written before the database commit.
        // If this final promotion cannot be flushed immediately, the current
        // session remains usable and startup recovery will promote it later.
        _ = persistConfiguration(enabledConfiguration, mirrorLegacy: true)
        globalSessionPassword = normalized
        globalProtectionEnabled = true
        globalUnlocked = true
    }

    func disableGlobalProtection(password: String, context: ModelContext) throws {
        let normalized = normalizedPassword(password)
        guard let enabledConfiguration = protectionConfiguration(),
              verifyGlobalPassword(normalized)
        else {
            throw ProtectionError.invalidPassword
        }

        let shards = try context.fetch(FetchDescriptor<Shard>())
        let preGlobalCount = shards.lazy.filter { $0.encryptionMode == .global }.count
        let pendingConfiguration = GlobalProtectionConfiguration(
            version: 3,
            state: .pendingDisable,
            salt: enabledConfiguration.salt,
            verifier: enabledConfiguration.verifier,
            preGlobalCount: preGlobalCount,
            expectedPostGlobalCount: 0
        )
        guard persistConfiguration(pendingConfiguration, mirrorLegacy: true) else {
            _ = persistConfiguration(enabledConfiguration, mirrorLegacy: true)
            throw ProtectionError.configurationPersistenceFailed
        }

        do {
            let timestamp = Date()
            for shard in shards where shard.encryptionMode == .global {
                shard.payload = try PasswordCipher.decrypt(
                    shard.payload,
                    password: normalized,
                    expectedPrefix: PasswordCipher.globalPrefix
                )
                shard.encryptionMode = .none
                shard.updatedAt = timestamp
            }
            try context.save()
        } catch {
            context.rollback()
            guard persistConfiguration(enabledConfiguration, mirrorLegacy: true) else {
                throw ProtectionError.configurationPersistenceFailed
            }
            throw error
        }

        globalSessionPassword = nil
        globalProtectionEnabled = false
        globalUnlocked = true

        // Clear the compatibility mirrors first and the pending record last.
        // If the process stops after SwiftData commits, startup recovery sees
        // pendingDisable and safely finishes this step.
        guard clearConfiguration() else {
            throw ProtectionError.configurationPersistenceFailed
        }
    }

    func plaintext(for shard: Shard) throws -> String {
        switch shard.encryptionMode {
        case .none:
            return shard.payload
        case .global:
            guard let password = globalSessionPassword else {
                throw ProtectionError.globalProtectionLocked
            }
            return try PasswordCipher.decrypt(
                shard.payload,
                password: password,
                expectedPrefix: PasswordCipher.globalPrefix
            )
        case .perShard:
            guard let password = shardSessionPasswords[shard.id] else {
                throw ProtectionError.shardLocked
            }
            return try PasswordCipher.decrypt(
                shard.payload,
                password: password,
                expectedPrefix: PasswordCipher.shardPrefix
            )
        }
    }

    func encryptPayloadForPersistence(_ plaintext: String, mode: EncryptionMode, shard: Shard? = nil) throws -> String {
        switch mode {
        case .none:
            return plaintext
        case .global:
            guard let password = globalSessionPassword else {
                throw ProtectionError.globalProtectionLocked
            }
            return try PasswordCipher.encrypt(plaintext, password: password, prefix: PasswordCipher.globalPrefix)
        case .perShard:
            guard let shard, let password = shardSessionPasswords[shard.id] else {
                throw ProtectionError.shardLocked
            }
            return try PasswordCipher.encrypt(plaintext, password: password, prefix: PasswordCipher.shardPrefix)
        }
    }

    func duplicatedPayloadForSession(from source: Shard, to target: Shard, plaintext: String) throws -> String {
        switch source.encryptionMode {
        case .none:
            return plaintext
        case .global:
            guard let password = globalSessionPassword else {
                throw ProtectionError.globalProtectionLocked
            }
            return try PasswordCipher.encrypt(plaintext, password: password, prefix: PasswordCipher.globalPrefix)
        case .perShard:
            guard let password = shardSessionPasswords[source.id] else {
                throw ProtectionError.shardLocked
            }
            shardSessionPasswords[target.id] = password
            return try PasswordCipher.encrypt(plaintext, password: password, prefix: PasswordCipher.shardPrefix)
        }
    }

    func protect(_ shard: Shard, password: String) throws {
        let normalized = normalizedPassword(password)
        guard !normalized.isEmpty else {
            throw ProtectionError.emptyPassword
        }
        guard shard.encryptionMode != .perShard else {
            throw ProtectionError.shardAlreadyProtected
        }

        let plaintext = try plaintext(for: shard)
        shard.payload = try PasswordCipher.encrypt(plaintext, password: normalized, prefix: PasswordCipher.shardPrefix)
        shard.encryptionMode = .perShard
        shard.updatedAt = Date()
        shardSessionPasswords[shard.id] = normalized
    }

    func unlockProtectedShard(_ shard: Shard, password: String) throws {
        let normalized = normalizedPassword(password)
        guard shard.encryptionMode == .perShard else {
            throw ProtectionError.shardNotProtected
        }
        _ = try PasswordCipher.decrypt(shard.payload, password: normalized, expectedPrefix: PasswordCipher.shardPrefix)
        shardSessionPasswords[shard.id] = normalized
    }

    func removeProtection(from shard: Shard, password: String) throws {
        let normalized = normalizedPassword(password)
        guard shard.encryptionMode == .perShard else {
            throw ProtectionError.shardNotProtected
        }

        let plaintext = try PasswordCipher.decrypt(
            shard.payload,
            password: normalized,
            expectedPrefix: PasswordCipher.shardPrefix
        )
        shardSessionPasswords.removeValue(forKey: shard.id)

        if globalProtectionEnabled {
            guard let globalPassword = globalSessionPassword else {
                throw ProtectionError.globalProtectionLocked
            }
            shard.payload = try PasswordCipher.encrypt(
                plaintext,
                password: globalPassword,
                prefix: PasswordCipher.globalPrefix
            )
            shard.encryptionMode = .global
        } else {
            shard.payload = plaintext
            shard.encryptionMode = .none
        }
        shard.updatedAt = Date()
    }

    private func verifyGlobalPassword(_ password: String) -> Bool {
        guard let configuration = protectionConfiguration(),
              let salt = Data(base64Encoded: configuration.salt)
        else { return false }

        return PasswordCipher.makeVerifier(password: normalizedPassword(password), salt: salt)
            == configuration.verifier
    }

    private func protectionConfiguration() -> GlobalProtectionConfiguration? {
        let configuration = storedConfiguration()
        return configuration?.state == .enabled ? configuration : nil
    }

    private func storedConfiguration() -> GlobalProtectionConfiguration? {
        if let data = defaults.data(forKey: AppSettingKeys.globalProtectionConfiguration),
           let configuration = try? JSONDecoder().decode(GlobalProtectionConfiguration.self, from: data) {
            return configuration
        }

        // One-time compatibility read for existing v1 installations. The new
        // single-record format becomes authoritative as soon as it is written.
        guard defaults.bool(forKey: AppSettingKeys.globalProtectionEnabled),
              let salt = defaults.string(forKey: AppSettingKeys.globalProtectionSalt),
              Data(base64Encoded: salt) != nil,
              let verifier = defaults.string(forKey: AppSettingKeys.globalProtectionVerifier)
        else { return nil }

        let migrated = GlobalProtectionConfiguration(
            version: 3,
            state: .enabled,
            salt: salt,
            verifier: verifier,
            preGlobalCount: 0,
            expectedPostGlobalCount: 0
        )
        _ = persistConfiguration(migrated, mirrorLegacy: true)
        return migrated
    }

    @discardableResult
    private func persistConfiguration(
        _ configuration: GlobalProtectionConfiguration,
        mirrorLegacy: Bool
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(configuration) else { return false }
        defaults.set(data, forKey: AppSettingKeys.globalProtectionConfiguration)
        guard defaults.synchronize() else { return false }

        if mirrorLegacy {
            // These keys remain as a compatibility mirror only. `enabled` is
            // deliberately last; the atomic v2 record above is authoritative.
            defaults.set(configuration.salt, forKey: AppSettingKeys.globalProtectionSalt)
            defaults.set(configuration.verifier, forKey: AppSettingKeys.globalProtectionVerifier)
            defaults.set(true, forKey: AppSettingKeys.globalProtectionEnabled)
        }
        return true
    }

    @discardableResult
    private func clearConfiguration() -> Bool {
        // Keep the atomic pending record until the legacy enabled mirror has
        // durably disappeared. Otherwise a crash between removals could make
        // plaintext rows look protected again through the compatibility path.
        defaults.removeObject(forKey: AppSettingKeys.globalProtectionEnabled)
        defaults.removeObject(forKey: AppSettingKeys.globalProtectionSalt)
        defaults.removeObject(forKey: AppSettingKeys.globalProtectionVerifier)
        guard defaults.synchronize() else { return false }

        defaults.removeObject(forKey: AppSettingKeys.globalProtectionConfiguration)
        return defaults.synchronize()
    }

    private func globalShardCount(in context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<Shard>())
            .lazy
            .filter { $0.encryptionMode == .global }
            .count
    }

    private func normalizedPassword(_ password: String) -> String {
        password.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
