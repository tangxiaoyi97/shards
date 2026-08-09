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
        }
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

    private let defaults = UserDefaults.standard
    private var globalSessionPassword: String?
    private var shardSessionPasswords: [String: String] = [:]

    private init() {
        refreshConfiguration()
    }

    var requiresGlobalUnlock: Bool {
        globalProtectionEnabled && globalSessionPassword == nil
    }

    func refreshConfiguration() {
        globalProtectionEnabled = defaults.bool(forKey: AppSettingKeys.globalProtectionEnabled)
        if !globalProtectionEnabled {
            globalUnlocked = true
            globalSessionPassword = nil
        } else {
            globalUnlocked = globalSessionPassword != nil
        }
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

        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        defaults.set(true, forKey: AppSettingKeys.globalProtectionEnabled)
        defaults.set(salt.base64EncodedString(), forKey: AppSettingKeys.globalProtectionSalt)
        defaults.set(
            PasswordCipher.makeVerifier(password: normalized, salt: salt),
            forKey: AppSettingKeys.globalProtectionVerifier
        )
        globalSessionPassword = normalized
        globalProtectionEnabled = true
        globalUnlocked = true

        let shards = (try? context.fetch(FetchDescriptor<Shard>())) ?? []
        for shard in shards where shard.encryptionMode == .none {
            shard.payload = try PasswordCipher.encrypt(shard.payload, password: normalized, prefix: PasswordCipher.globalPrefix)
            shard.encryptionMode = .global
            shard.updatedAt = Date()
        }
        try context.save()
    }

    func disableGlobalProtection(password: String, context: ModelContext) throws {
        let normalized = normalizedPassword(password)
        guard verifyGlobalPassword(normalized) else {
            throw ProtectionError.invalidPassword
        }

        let shards = (try? context.fetch(FetchDescriptor<Shard>())) ?? []
        for shard in shards where shard.encryptionMode == .global {
            shard.payload = try PasswordCipher.decrypt(shard.payload, password: normalized, expectedPrefix: PasswordCipher.globalPrefix)
            shard.encryptionMode = .none
            shard.updatedAt = Date()
        }
        try context.save()

        defaults.removeObject(forKey: AppSettingKeys.globalProtectionEnabled)
        defaults.removeObject(forKey: AppSettingKeys.globalProtectionSalt)
        defaults.removeObject(forKey: AppSettingKeys.globalProtectionVerifier)

        globalSessionPassword = nil
        globalProtectionEnabled = false
        globalUnlocked = true
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
        guard let saltString = defaults.string(forKey: AppSettingKeys.globalProtectionSalt),
              let verifier = defaults.string(forKey: AppSettingKeys.globalProtectionVerifier),
              let salt = Data(base64Encoded: saltString)
        else { return false }

        return PasswordCipher.makeVerifier(password: normalizedPassword(password), salt: salt) == verifier
    }

    private func normalizedPassword(_ password: String) -> String {
        password.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
