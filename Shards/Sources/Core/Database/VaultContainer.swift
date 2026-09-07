import Foundation
import SwiftData

@MainActor
class VaultContainer {
    static let shared = VaultContainer()

    enum Defaults {
        static let allCollectionID = "all"
        static let shardsCollectionName = "Shards"
        static let shardsCollectionLegacyName = "Inbox"
        static let shardsCollectionIcon = "triangle"
        static let passwordCollectionName = "Passwords"
        static let tokenCollectionName = "Tokens"
        static let clipboardTagName = "Clipboard"
        static let legacyTypeTagNames = ["Password", "Token"]
    }

    let container: ModelContainer
    private(set) var startupIssue: String?
    private(set) var isPersistentStoreAvailable = true
    static let vaultDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first!
        .appendingPathComponent("Shards", isDirectory: true)
    static let storeURL = vaultDirectory
        .appendingPathComponent("Shards.store")

    private init() {
        let schema = Schema([Shard.self, ShardCollection.self, Tag.self, PresetTemplate.self, ShardAttachment.self])
        let config = Self.makeConfiguration(schema: schema)
        let createdContainer: ModelContainer
        do {
            createdContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            do {
                isPersistentStoreAvailable = false
                startupIssue = "Shards could not open the persistent store. Editing is disabled so no temporary data can be mistaken for a successful save."
                let fallbackConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                createdContainer = try ModelContainer(for: schema, configurations: [fallbackConfig])
            } catch {
                fatalError("Failed to instantiate SwiftData ModelContainer: \(String(describing: error))")
            }
        }
        container = createdContainer

        guard isPersistentStoreAvailable else { return }
        do {
            try ProtectionService.shared.recoverPendingConfiguration(context: container.mainContext)
            try seedDefaultsIfNeeded()
        } catch {
            container.mainContext.rollback()
            isPersistentStoreAvailable = false
            startupIssue = "Shards opened the vault but could not validate its startup data. Editing is disabled to avoid partial migrations. \(error.localizedDescription)"
        }
    }

    private static func makeConfiguration(schema: Schema) -> ModelConfiguration {
        let directory = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ModelConfiguration(schema: schema, url: storeURL)
    }

    private func seedDefaultsIfNeeded() throws {
        let context = container.mainContext
        var needsSave = false

        if try context.fetchCount(FetchDescriptor<ShardCollection>()) == 0 {
            [
                ShardCollection(id: Defaults.allCollectionID, name: "All Shards", icon: "tray.full"),
                ShardCollection(name: Defaults.shardsCollectionName, icon: Defaults.shardsCollectionIcon),
                ShardCollection(name: Defaults.passwordCollectionName, icon: "key"),
                ShardCollection(name: Defaults.tokenCollectionName, icon: "network.badge.shield.half.filled")
            ].forEach(context.insert)
            needsSave = true
        }

        let tags = try context.fetch(FetchDescriptor<Tag>())
        if !tags.contains(where: { $0.name.caseInsensitiveCompare(Defaults.clipboardTagName) == .orderedSame }) {
            context.insert(Tag(name: Defaults.clipboardTagName, colorHex: "#D97706", symbol: "paperclip", isSystem: true))
            needsSave = true
        }

        let hiddenTagName = "Hidden"
        if !tags.contains(where: { $0.name.caseInsensitiveCompare(hiddenTagName) == .orderedSame }) {
            context.insert(Tag(name: hiddenTagName, colorHex: "#4B5563", symbol: "eye.slash", isSystem: true))
            needsSave = true
        }

        let lockedTagName = "Locked"
        if !tags.contains(where: { $0.name.caseInsensitiveCompare(lockedTagName) == .orderedSame }) {
            context.insert(Tag(name: lockedTagName, colorHex: "#6B7280", symbol: "lock.fill", isSystem: true))
            needsSave = true
        }

        if try context.fetchCount(FetchDescriptor<PresetTemplate>()) == 0 {
            defaultTemplates().forEach(context.insert)
            needsSave = true
        }

        if try seedWelcomeShardsIfNeeded(context: context) {
            needsSave = true
        }

        if try normalizeStoredDefaults(context: context) {
            needsSave = true
        }

        if needsSave {
            try context.save()
        }
    }

    private func seedWelcomeShardsIfNeeded(context: ModelContext) throws -> Bool {
        guard try context.fetchCount(FetchDescriptor<Shard>()) == 0 else {
            return false
        }

        let collections = try context.fetch(FetchDescriptor<ShardCollection>())
        let tags = try context.fetch(FetchDescriptor<Tag>())
        let defaultCollectionId = collections.first(where: {
            $0.name.caseInsensitiveCompare(Defaults.shardsCollectionName) == .orderedSame
        })?.id ?? Defaults.allCollectionID
        let hiddenTagId = tags.first(where: {
            $0.name.caseInsensitiveCompare("Hidden") == .orderedSame
        })?.id

        Self.makeDefaultWelcomeShards(
            collectionId: defaultCollectionId,
            hiddenTagId: hiddenTagId
        ).forEach(context.insert)
        return true
    }

    static func makeDefaultWelcomeShards(
        collectionId: String?,
        hiddenTagId: String?,
        now: Date = Date()
    ) -> [Shard] {
        let entries: [(content: String, tagIds: [String])] = [
            (
                """
                👋 Welcome to Shards
                Press Command-N to create a shard.
                Double-click the menu bar icon to save clipboard text.
                Open Settings to adjust shortcuts and appearance.
                """,
                []
            ),
            (
                """
                🏷️ Tags & Templates
                Use tags to organize and filter your shards.
                Use Templates for structured entries like passwords or tokens.
                Quick Entry can save as Raw Text, Smart, or any Template.
                """,
                []
            ),
            (
                """
                🙈 Hidden Shards
                This shard uses the Hidden tag.
                Hold Option to reveal hidden shards and the Hidden tag.
                Release Option to hide them again.
                """,
                hiddenTagId.map { [$0] } ?? []
            )
        ]

        return entries.enumerated().map { index, entry in
            let timestamp = now.addingTimeInterval(TimeInterval(-index))
            return Shard(
                collectionId: collectionId,
                tagIds: entry.tagIds,
                payload: entry.content,
                createdAt: timestamp,
                updatedAt: timestamp
            )
        }
    }

    private func defaultTemplates() -> [PresetTemplate] {
        let shardSchema = PresetTemplateSchema(
            version: PresetTemplateSchema.currentVersion,
            summary: "General-purpose shard for freeform notes, snippets, and uncategorized text.",
            useCases: ["clipboard captures", "ideas", "draft notes"],
            outputNotes: "Prefer this when the input does not strongly match a more structured template.",
            presentationStyle: .plainText,
            titleFieldKey: "content",
            displayFormat: nil,
            fields: [
                PresetFieldDefinition(
                    key: "content",
                    name: "Content",
                    valueType: .note,
                    placeholder: "Write anything",
                    isRequired: true,
                    isSensitive: false,
                    helpText: "Primary content of the shard."
                )
            ]
        )

        let passwordSchema = PresetTemplateSchema(
            version: PresetTemplateSchema.currentVersion,
            summary: "Credential record for a login account.",
            useCases: ["website login", "app credentials", "service credentials"],
            outputNotes: "Use for username or email based credentials with an optional note.",
            presentationStyle: .table,
            titleFieldKey: "platform",
            displayFormat: "{platform} ({identity})",
            fields: [
                PresetFieldDefinition(key: "platform", name: "Platform", valueType: .text, placeholder: "GitHub", isRequired: true, isSensitive: false, helpText: "Service or product name."),
                PresetFieldDefinition(key: "identity", name: "Identity", valueType: .email, placeholder: "name@example.com", isRequired: true, isSensitive: false, helpText: "User name, email, or login identity."),
                PresetFieldDefinition(key: "password", name: "Password", valueType: .secret, placeholder: nil, isRequired: true, isSensitive: true, helpText: "Secret credential."),
                PresetFieldDefinition(key: "note", name: "Note", valueType: .note, placeholder: "Recovery hint, 2FA note...", isRequired: false, isSensitive: false, helpText: "Optional supporting detail.")
            ]
        )

        let tokenSchema = PresetTemplateSchema(
            version: PresetTemplateSchema.currentVersion,
            summary: "Machine token, API key, or bearer credential.",
            useCases: ["API key", "bearer token", "service integration token"],
            outputNotes: "Use for secrets intended for programmatic access instead of human login.",
            presentationStyle: .table,
            titleFieldKey: "platform",
            displayFormat: "{platform} - {name}",
            fields: [
                PresetFieldDefinition(key: "platform", name: "Platform", valueType: .text, placeholder: "OpenAI", isRequired: true, isSensitive: false, helpText: "Provider or service name."),
                PresetFieldDefinition(key: "name", name: "Name", valueType: .text, placeholder: "Production key", isRequired: false, isSensitive: false, helpText: "Friendly label for the token."),
                PresetFieldDefinition(key: "token_content", name: "Token Content", valueType: .secret, placeholder: nil, isRequired: true, isSensitive: true, helpText: "The token or API key itself.")
            ]
        )

        return [
            PresetTemplate(
                name: "Shard",
                symbol: "triangle",
                targetCollectionName: Defaults.shardsCollectionName,
                schemaFieldsJSON: encode(schema: shardSchema),
                orderIndex: 0
            ),
            PresetTemplate(
                name: "Password",
                symbol: "key.fill",
                targetCollectionName: Defaults.passwordCollectionName,
                schemaFieldsJSON: encode(schema: passwordSchema),
                orderIndex: 1
            ),
            PresetTemplate(
                name: "Token",
                symbol: "network.badge.shield.half.filled",
                targetCollectionName: Defaults.tokenCollectionName,
                schemaFieldsJSON: encode(schema: tokenSchema),
                orderIndex: 2
            )
        ]
    }

    private func encode(schema: PresetTemplateSchema) -> String {
        let data = (try? JSONEncoder().encode(schema)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func normalizeStoredDefaults(context: ModelContext) throws -> Bool {
        var didChange = false
        let collections = try context.fetch(FetchDescriptor<ShardCollection>())
        let templates = try context.fetch(FetchDescriptor<PresetTemplate>())
        let tags = try context.fetch(FetchDescriptor<Tag>())
        let shards = try context.fetch(FetchDescriptor<Shard>())

        if let legacyShardsCollection = collections.first(where: { $0.name == Defaults.shardsCollectionLegacyName }) {
            legacyShardsCollection.name = Defaults.shardsCollectionName
            legacyShardsCollection.icon = Defaults.shardsCollectionIcon
            didChange = true
        }

        if let shardsCollection = collections.first(where: { $0.name == Defaults.shardsCollectionName }),
           shardsCollection.icon != Defaults.shardsCollectionIcon {
            shardsCollection.icon = Defaults.shardsCollectionIcon
            didChange = true
        }

        if let shardsCollection = collections.first(where: {
            $0.name.caseInsensitiveCompare(Defaults.shardsCollectionName) == .orderedSame
        }) {
            let validCollectionIDs = Set(
                collections
                    .filter { $0.id != Defaults.allCollectionID }
                    .map(\.id)
            )
            for shard in shards where shard.collectionId.map({
                !validCollectionIDs.contains($0)
            }) ?? true {
                shard.collectionId = shardsCollection.id
                didChange = true
            }
        }

        for shard in shards {
            var seenTagIDs = Set<String>()
            let uniqueTagIDs = shard.tagIds.filter { seenTagIDs.insert($0).inserted }
            if uniqueTagIDs != shard.tagIds {
                shard.tagIds = uniqueTagIDs
                didChange = true
            }
        }

        for template in templates {
            if template.name == "Smart" {
                context.delete(template)
                didChange = true
                continue
            }

            if template.name == "Note" {
                template.name = "Shard"
                didChange = true
            }

            if template.targetCollectionName == Defaults.shardsCollectionLegacyName {
                template.targetCollectionName = Defaults.shardsCollectionName
                didChange = true
            }

            if template.targetTagName != nil {
                template.targetTagName = nil
                didChange = true
            }

            if let normalizedTemplate = normalizedBuiltinTemplate(template) {
                if template.symbol != normalizedTemplate.symbol {
                    template.symbol = normalizedTemplate.symbol
                    didChange = true
                }
                if template.targetCollectionName != normalizedTemplate.targetCollectionName {
                    template.targetCollectionName = normalizedTemplate.targetCollectionName
                    didChange = true
                }
                if template.orderIndex != normalizedTemplate.orderIndex {
                    template.orderIndex = normalizedTemplate.orderIndex
                    didChange = true
                }
                if template.schemaFieldsJSON != normalizedTemplate.schemaFieldsJSON {
                    template.schemaFieldsJSON = normalizedTemplate.schemaFieldsJSON
                    didChange = true
                }
                continue
            }

            // Custom schemas are intentionally preserved byte-for-byte here.
            // Decode/encode normalization would discard forward-compatible keys
            // (for example future validation or options metadata).
        }

        let collectionByName = Dictionary(uniqueKeysWithValues: collections.map { ($0.name, $0) })
        for legacyTag in tags where Defaults.legacyTypeTagNames.contains(legacyTag.name) {
            let targetCollectionName = legacyTag.name == "Password" ? Defaults.passwordCollectionName : Defaults.tokenCollectionName
            let targetCollectionId = collectionByName[targetCollectionName]?.id

            for shard in shards where shard.tagIds.contains(legacyTag.id) {
                shard.tagIds.removeAll(where: { $0 == legacyTag.id })
                if let targetCollectionId {
                    shard.collectionId = targetCollectionId
                }
                shard.updatedAt = Date()
                didChange = true
            }

            context.delete(legacyTag)
            didChange = true
        }

        for shard in shards {
            guard case let .decoded(decodedPayload) = PresetPayload.decoding(shard.payload) else {
                continue
            }
            var payload = decodedPayload

            var payloadChanged = false
            if payload.presetType.caseInsensitiveCompare("Note") == .orderedSame {
                payload.presetType = "Shard"
                payloadChanged = true
            }

            if payloadChanged,
               let encodedPayload = try? JSONEncoder().encode(payload),
               let payloadString = String(data: encodedPayload, encoding: .utf8) {
                shard.payload = payloadString
                didChange = true
            }
        }

        return didChange
    }

    private func normalizedBuiltinTemplate(_ template: PresetTemplate) -> PresetTemplate? {
        let builtinTemplate = defaultTemplates().first {
            $0.name.caseInsensitiveCompare(template.name) == .orderedSame
        }
        guard let builtinTemplate else { return nil }
        return PresetTemplate(
            id: template.id,
            name: builtinTemplate.name,
            symbol: builtinTemplate.symbol,
            targetCollectionName: builtinTemplate.targetCollectionName,
            schemaFieldsJSON: builtinTemplate.schemaFieldsJSON,
            orderIndex: builtinTemplate.orderIndex
        )
    }
}

@MainActor
protocol VaultRepositoryProtocol {
    @discardableResult
    func save(
        payload: PresetPayload,
        collectionId: String?,
        tagIds: [String],
        encryptionMode: EncryptionMode
    ) throws -> Shard

    @discardableResult
    func saveRawText(
        _ text: String,
        collectionId: String?,
        tagIds: [String],
        encryptionMode: EncryptionMode
    ) throws -> Shard

    func applyBatch(
        _ operation: ShardBatchOperation,
        to shardIDs: [String],
        lockedTagID: String?
    ) throws -> ShardBatchReceipt

    func replayBatch(
        _ receipt: ShardBatchReceipt,
        direction: ShardBatchReplayDirection
    ) throws

    func applyBatchInIsolatedContext(
        _ operation: ShardBatchOperation,
        to shardIDs: [String],
        lockedTagID: String?
    ) throws -> ShardBatchReceipt

    func replayBatchInIsolatedContext(
        _ receipt: ShardBatchReceipt,
        direction: ShardBatchReplayDirection
    ) throws

    func shard(withID id: String) throws -> Shard?

    func permanentlyDelete(
        shardIDs: [String],
        lockedTagID: String?
    ) throws -> ShardPermanentDeleteReceipt
}

@MainActor
final class VaultRepository: VaultRepositoryProtocol {
    static let shared = VaultRepository(
        container: VaultContainer.shared.container,
        writesAllowed: { VaultContainer.shared.isPersistentStoreAvailable }
    )

    private let container: ModelContainer
    private let writesAllowed: () -> Bool

    init(container: ModelContainer, writesAllowed: @escaping () -> Bool = { true }) {
        self.container = container
        self.writesAllowed = writesAllowed
    }

    @discardableResult
    func save(
        payload: PresetPayload,
        collectionId: String? = VaultContainer.Defaults.allCollectionID,
        tagIds: [String] = [],
        encryptionMode: EncryptionMode = .none
    ) throws -> Shard {
        try ensureWritesAllowed()
        let encodedPayload: String

        if payload.isRaw {
            encodedPayload = payload.fields.first(where: { $0.name == "Content" })?.trimmedValue ?? ""
        } else {
            let data = try JSONEncoder().encode(payload)
            guard let json = String(data: data, encoding: .utf8) else {
                throw VaultRepositoryError.invalidEncoding
            }
            encodedPayload = json
        }

        var finalPayload = encodedPayload
        if encryptionMode != .none {
            finalPayload = try ProtectionService.shared.encryptPayloadForPersistence(encodedPayload, mode: encryptionMode)
        }

        let isolatedContext = ModelContext(container)
        var calculatedDisplayName: String? = nil
        let fetchDescriptor = FetchDescriptor<PresetTemplate>()
        let templates = try isolatedContext.fetch(fetchDescriptor)
        if let match = templates.matchingTemplate(for: payload) {
            calculatedDisplayName = match.schema.safeDisplayName(for: payload)
        }

        let resolvedCollectionID: String?
        if collectionId == nil || collectionId == VaultContainer.Defaults.allCollectionID {
            let collections = try isolatedContext.fetch(FetchDescriptor<ShardCollection>())
            resolvedCollectionID = collections.first(where: {
                $0.name.caseInsensitiveCompare(VaultContainer.Defaults.shardsCollectionName) == .orderedSame
            })?.id
        } else {
            resolvedCollectionID = collectionId
        }

        let shard = Shard(
            collectionId: resolvedCollectionID,
            tagIds: tagIds,
            encryptionMode: encryptionMode,
            displayName: calculatedDisplayName,
            payload: finalPayload
        )
        isolatedContext.insert(shard)
        do {
            try isolatedContext.save()
        } catch {
            isolatedContext.rollback()
            throw error
        }

        return shard
    }

    @discardableResult
    func saveRawText(
        _ text: String,
        collectionId: String? = VaultContainer.Defaults.allCollectionID,
        tagIds: [String] = [],
        encryptionMode: EncryptionMode = .none
    ) throws -> Shard {
        try save(payload: .raw(text), collectionId: collectionId, tagIds: tagIds, encryptionMode: encryptionMode)
    }

    func applyBatch(
        _ operation: ShardBatchOperation,
        to shardIDs: [String],
        lockedTagID: String? = nil
    ) throws -> ShardBatchReceipt {
        try ensureWritesAllowed()
        return try ShardBatchService(context: container.mainContext).apply(
            operation,
            to: shardIDs,
            lockedTagID: lockedTagID
        )
    }

    func replayBatch(
        _ receipt: ShardBatchReceipt,
        direction: ShardBatchReplayDirection
    ) throws {
        try ensureWritesAllowed()
        guard !container.mainContext.hasChanges else {
            throw ShardBatchError.pendingChanges
        }
        try ShardBatchService(context: container.mainContext).replay(receipt, direction: direction)
    }

    func applyBatchInIsolatedContext(
        _ operation: ShardBatchOperation,
        to shardIDs: [String],
        lockedTagID: String? = nil
    ) throws -> ShardBatchReceipt {
        try ensureWritesAllowed()
        let isolatedContext = ModelContext(container)
        return try ShardBatchService(context: isolatedContext).apply(
            operation,
            to: shardIDs,
            lockedTagID: lockedTagID
        )
    }

    func replayBatchInIsolatedContext(
        _ receipt: ShardBatchReceipt,
        direction: ShardBatchReplayDirection
    ) throws {
        try ensureWritesAllowed()
        let isolatedContext = ModelContext(container)
        try ShardBatchService(context: isolatedContext).replay(receipt, direction: direction)
    }

    func shard(withID id: String) throws -> Shard? {
        let readContext = ModelContext(container)
        return try readContext.fetch(FetchDescriptor<Shard>()).first(where: { $0.id == id })
    }

    func permanentlyDelete(
        shardIDs: [String],
        lockedTagID: String? = nil
    ) throws -> ShardPermanentDeleteReceipt {
        try ensureWritesAllowed()
        guard !container.mainContext.hasChanges else {
            throw ShardBatchError.pendingChanges
        }
        let isolatedContext = ModelContext(container)
        let receipt = try ShardBatchService(context: isolatedContext).permanentlyDelete(
            shardIDs: shardIDs,
            lockedTagID: lockedTagID
        )
        NotificationCenter.default.post(
            name: .shardsWerePermanentlyDeleted,
            object: receipt.deletedIDs
        )
        ProtectionService.shared.forgetShardSessions(withIDs: receipt.deletedIDs)
        return receipt
    }

    private func ensureWritesAllowed() throws {
        guard writesAllowed() else {
            throw VaultRepositoryError.storeUnavailable
        }
    }
}

enum VaultRepositoryError: LocalizedError {
    case invalidEncoding
    case storeUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "Unable to encode the shard payload."
        case .storeUnavailable:
            return "The persistent vault is unavailable. Shards did not write to temporary storage."
        }
    }
}
