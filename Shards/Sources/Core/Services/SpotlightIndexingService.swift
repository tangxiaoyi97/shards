@preconcurrency import CoreSpotlight
import Combine
import Foundation
import SwiftData
import UniformTypeIdentifiers

struct SpotlightShardSnapshot: Sendable {
    let id: String
    let collectionID: String?
    let collectionName: String?
    let tagNames: [String]
    let isHidden: Bool
    let isLocked: Bool
    let encryptionMode: EncryptionMode
    let isPinned: Bool
    let displayName: String?
    let deletedAt: Date?
    let payload: String
    let schema: PresetTemplateSchema?
    let createdAt: Date
    let updatedAt: Date
}

struct SpotlightShardDocument: Equatable, Sendable {
    let shardID: String
    let itemIdentifier: String
    let title: String
    let textContent: String
    let contentDescription: String?
    let keywords: [String]
    let collectionID: String?
    let collectionName: String?
    let createdAt: Date
    let updatedAt: Date
    let isPinned: Bool
}

enum SpotlightItemIdentifier {
    private static let prefix = "shard:"

    static func make(shardID: String) -> String {
        prefix + shardID
    }

    static func shardID(from itemIdentifier: String) -> String? {
        guard itemIdentifier.hasPrefix(prefix) else { return nil }
        let shardID = String(itemIdentifier.dropFirst(prefix.count))
        return shardID.isEmpty ? nil : shardID
    }
}

enum SpotlightDocumentBuilder {
    static let domainIdentifier = "com.tangxiaoyi.Shards.vault"
    private static let maximumTextLength = 20_000
    private static let maximumDescriptionLength = 240

    static func document(from snapshot: SpotlightShardSnapshot) -> SpotlightShardDocument? {
        guard snapshot.deletedAt == nil,
              snapshot.encryptionMode == .none,
              !snapshot.isHidden,
              !snapshot.isLocked
        else { return nil }

        let title: String
        let textContent: String
        var typeKeyword = "Shard"

        switch PresetPayload.decoding(snapshot.payload) {
        case .malformedStructured:
            // An undecodable structured payload may contain secrets whose
            // metadata cannot be trusted, so it is deliberately fail-closed.
            return nil

        case .plainText:
            guard !isSensitiveFreeformCollection(snapshot.collectionName) else {
                return nil
            }
            let raw = PresetPayload.raw(snapshot.payload)
            title = normalizedTitle(snapshot.displayName) ?? raw.displayTitle
            textContent = snapshot.payload

        case let .decoded(decodedPayload):
            let payload = decodedPayload.resolvingMetadata(using: snapshot.schema)
            if isSensitiveFreeformCollection(snapshot.collectionName),
               payload.isRaw
                    || payload.normalizedPresetType.caseInsensitiveCompare("Shard") == .orderedSame {
                return nil
            }
            typeKeyword = payload.normalizedPresetType
            textContent = payload.safeSearchableContent

            let storedTitle = normalizedTitle(snapshot.displayName).flatMap { candidate in
                payload.displayNameExposesSensitiveValue(candidate) ? nil : candidate
            }
            let schemaTitle = snapshot.schema?.safeDisplayName(for: payload)
            title = storedTitle ?? schemaTitle ?? payload.displayTitle
        }

        let boundedText = String(textContent.prefix(maximumTextLength))
        let description = searchDescription(from: boundedText)
        let keywords = uniqueNonemptyValues(
            snapshot.tagNames + [snapshot.collectionName, typeKeyword].compactMap { $0 }
        )

        return SpotlightShardDocument(
            shardID: snapshot.id,
            itemIdentifier: SpotlightItemIdentifier.make(shardID: snapshot.id),
            title: title,
            textContent: boundedText,
            contentDescription: description,
            keywords: keywords,
            collectionID: snapshot.collectionID,
            collectionName: snapshot.collectionName,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            isPinned: snapshot.isPinned
        )
    }

    private static func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare("untitled") != .orderedSame,
              trimmed.caseInsensitiveCompare("untitled shard") != .orderedSame
        else { return nil }
        return trimmed
    }

    private static func searchDescription(from text: String) -> String? {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumDescriptionLength))
    }

    private static func uniqueNonemptyValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return seen.insert(key).inserted ? trimmed : nil
        }
    }

    private static func isSensitiveFreeformCollection(_ collectionName: String?) -> Bool {
        guard let collectionName else { return false }
        let foldedName = collectionName.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let tokens = Set(
            foldedName
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        let sensitiveTokens: Set<String> = [
            "password", "passwords", "passcode", "passcodes",
            "token", "tokens", "credential", "credentials",
            "secret", "secrets", "key", "keys", "license", "licenses",
            "serial", "serials", "activation", "api", "ssh"
        ]
        let sensitiveMarkers = ["密码", "口令", "密钥", "秘钥", "令牌", "凭据", "秘密", "许可证", "授权码"]

        return !tokens.isDisjoint(with: sensitiveTokens)
            || sensitiveMarkers.contains(where: foldedName.contains)
    }
}

struct SpotlightProjection: Sendable {
    let documents: [SpotlightShardDocument]
}

@ModelActor
actor SpotlightSnapshotProvider {
    func projection() throws -> SpotlightProjection {
        let shards = try modelContext.fetch(FetchDescriptor<Shard>())
        let tags = try modelContext.fetch(FetchDescriptor<Tag>())
        let collections = try modelContext.fetch(FetchDescriptor<ShardCollection>())
        let templates = try modelContext.fetch(FetchDescriptor<PresetTemplate>())

        let tagsByID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        let collectionsByID = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
        let templatesByID = Dictionary(uniqueKeysWithValues: templates.map { ($0.id, $0) })
        let templatesByName = Dictionary(
            templates.map { ($0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let documents = shards.compactMap { shard -> SpotlightShardDocument? in
            let resolvedTags = shard.tagIds.compactMap { tagsByID[$0] }
            let schema: PresetTemplateSchema?
            if case let .decoded(payload) = PresetPayload.decoding(shard.payload) {
                if let templateID = payload.templateID, let template = templatesByID[templateID] {
                    schema = template.schema
                } else {
                    let key = payload.presetType.folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: .current
                    )
                    schema = templatesByName[key]?.schema
                }
            } else {
                schema = nil
            }

            let snapshot = SpotlightShardSnapshot(
                id: shard.id,
                collectionID: shard.collectionId,
                collectionName: shard.collectionId.flatMap { collectionsByID[$0]?.name },
                tagNames: resolvedTags.map(\.name),
                isHidden: resolvedTags.contains { $0.name.caseInsensitiveCompare("Hidden") == .orderedSame },
                isLocked: resolvedTags.contains { $0.name.caseInsensitiveCompare("Locked") == .orderedSame },
                encryptionMode: shard.encryptionMode,
                isPinned: shard.isPinned,
                displayName: shard.displayName,
                deletedAt: shard.deletedAt,
                payload: shard.payload,
                schema: schema,
                createdAt: shard.createdAt,
                updatedAt: shard.updatedAt
            )
            return SpotlightDocumentBuilder.document(from: snapshot)
        }

        return SpotlightProjection(documents: documents)
    }
}

protocol SpotlightIndexWriting: Sendable {
    var isAvailable: Bool { get async }
    func replaceAll(with documents: [SpotlightShardDocument]) async throws
    func reconcile(
        documents: [SpotlightShardDocument],
        removing itemIdentifiers: [String]
    ) async throws
    func purge() async throws
}

private final class SpotlightReindexAcknowledgement: @unchecked Sendable {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func call() {
        handler()
    }
}

private final class CoreSpotlightReindexDelegate: NSObject, CSSearchableIndexDelegate, @unchecked Sendable {
    func searchableIndex(
        _ searchableIndex: CSSearchableIndex,
        reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void
    ) {
        forward(acknowledgementHandler)
    }

    func searchableIndex(
        _ searchableIndex: CSSearchableIndex,
        reindexSearchableItemsWithIdentifiers identifiers: [String],
        acknowledgementHandler: @escaping () -> Void
    ) {
        // The personal vault is intentionally reconciled as one small unit.
        // This also removes stale identifiers the system may still remember.
        forward(acknowledgementHandler)
    }

    private func forward(_ acknowledgementHandler: @escaping () -> Void) {
        let acknowledgement = SpotlightReindexAcknowledgement(acknowledgementHandler)
        Task { @MainActor in
            SpotlightIndexingService.shared.handleSystemReindexRequest(
                acknowledgement
            )
        }
    }
}

actor CoreSpotlightIndexWriter: SpotlightIndexWriting {
    private static let batchSize = 100
    private let index: CSSearchableIndex
    private let reindexDelegate: CoreSpotlightReindexDelegate

    init() {
        let reindexDelegate = CoreSpotlightReindexDelegate()
        let index = CSSearchableIndex(name: "ShardsVault")
        index.indexDelegate = reindexDelegate
        self.reindexDelegate = reindexDelegate
        self.index = index
    }

    var isAvailable: Bool {
        CSSearchableIndex.isIndexingAvailable()
    }

    func replaceAll(with documents: [SpotlightShardDocument]) async throws {
        try await index.deleteAllSearchableItems()
        try await indexDocuments(documents)
    }

    func reconcile(
        documents: [SpotlightShardDocument],
        removing itemIdentifiers: [String]
    ) async throws {
        if !itemIdentifiers.isEmpty {
            try await index.deleteSearchableItems(withIdentifiers: itemIdentifiers)
        }
        try await indexDocuments(documents)
    }

    func purge() async throws {
        try await index.deleteAllSearchableItems()
    }

    private func indexDocuments(_ documents: [SpotlightShardDocument]) async throws {
        var start = 0
        while start < documents.count {
            let end = min(start + Self.batchSize, documents.count)
            let items = documents[start..<end].map(makeSearchableItem)
            try await index.indexSearchableItems(items)
            start = end
        }
    }

    private func makeSearchableItem(from document: SpotlightShardDocument) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .plainText)
        attributes.identifier = document.shardID
        attributes.title = document.title
        attributes.displayName = document.title
        attributes.textContent = document.textContent
        attributes.contentDescription = document.contentDescription
        attributes.keywords = document.keywords
        attributes.containerIdentifier = document.collectionID
        attributes.containerTitle = document.collectionName
        attributes.contentCreationDate = document.createdAt
        attributes.contentModificationDate = document.updatedAt
        attributes.metadataModificationDate = document.updatedAt
        attributes.userCreated = true
        attributes.userOwned = true
        attributes.kind = "Shard"
        attributes.rankingHint = document.isPinned ? 80 : 50

        let item = CSSearchableItem(
            uniqueIdentifier: document.itemIdentifier,
            domainIdentifier: SpotlightDocumentBuilder.domainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture
        return item
    }
}

@MainActor
final class SpotlightIndexingService: ObservableObject {
    static let shared = SpotlightIndexingService()

    @Published private(set) var statusMessage = "Off"
    @Published private(set) var indexedItemCount = 0
    @Published private(set) var isWorking = false

    private let defaults: UserDefaults
    private let writer: any SpotlightIndexWriting
    private var container: ModelContainer?
    private var snapshotProvider: SpotlightSnapshotProvider?
    private var persistentStoreAvailable = false
    private var saveObserver: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var pendingRebuild = false
    private var pendingPurge = false
    private var forceFullRebuild = false
    private var consecutiveFailureCount = 0
    private var systemReindexAcknowledgements: [SpotlightReindexAcknowledgement] = []
    private var hasCompletedInitialRebuild = false
    private var indexedItemIdentifiers = Set<String>()

    init(
        defaults: UserDefaults = .standard,
        writer: any SpotlightIndexWriting = CoreSpotlightIndexWriter()
    ) {
        self.defaults = defaults
        self.writer = writer
    }

    var isEnabled: Bool {
        defaults.bool(forKey: AppSettingKeys.spotlightIndexingEnabled)
    }

    func start(container: ModelContainer, persistentStoreAvailable: Bool) {
        guard self.container == nil else { return }
        self.container = container
        self.persistentStoreAvailable = persistentStoreAvailable
        if persistentStoreAvailable {
            snapshotProvider = SpotlightSnapshotProvider(modelContainer: container)
        }

        if saveObserver == nil {
            // ModelContext posts on the saving thread. Deliver on the main
            // queue so the observer never crosses the service's actor boundary.
            saveObserver = NotificationCenter.default.addObserver(
                forName: ModelContext.didSave,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRebuild()
                }
            }
        }

        guard persistentStoreAvailable else {
            statusMessage = "Vault unavailable"
            schedulePurge()
            return
        }

        if isEnabled {
            scheduleRebuild(immediately: true, full: true)
        } else {
            statusMessage = "Off"
            schedulePurge()
        }
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: AppSettingKeys.spotlightIndexingEnabled)
        if enabled, persistentStoreAvailable {
            scheduleRebuild(immediately: true, full: true)
        } else {
            schedulePurge()
        }
    }

    func rebuildNow() {
        guard isEnabled, persistentStoreAvailable else { return }
        scheduleRebuild(immediately: true, full: true)
    }

    fileprivate func handleSystemReindexRequest(
        _ acknowledgement: SpotlightReindexAcknowledgement
    ) {
        systemReindexAcknowledgements.append(acknowledgement)
        if isEnabled, persistentStoreAvailable {
            scheduleRebuild(immediately: true, full: true)
        } else {
            schedulePurge()
        }
    }

    func scheduleRebuild(immediately: Bool = false, full: Bool = false) {
        guard isEnabled, persistentStoreAvailable, snapshotProvider != nil else { return }
        pendingRebuild = true
        forceFullRebuild = forceFullRebuild || full
        retryTask?.cancel()
        retryTask = nil

        // A save that arrives while Core Spotlight is writing simply marks the
        // queue dirty. The worker will reconcile again before it becomes idle.
        guard workerTask == nil else { return }

        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if !immediately {
                do {
                    try await Task.sleep(for: .milliseconds(600))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self.debounceTask = nil
            self.startWorkerIfNeeded()
        }
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil, pendingPurge || (isEnabled && pendingRebuild) else { return }
        workerTask = Task { @MainActor [weak self] in
            await self?.drainPendingWork()
        }
    }

    private func drainPendingWork() async {
        isWorking = true
        var shouldRetry = false

        while !Task.isCancelled {
            if pendingPurge {
                pendingPurge = false
                statusMessage = "Removing index…"
                guard await performPurge() else {
                    pendingPurge = true
                    shouldRetry = true
                    break
                }
                continue
            }

            guard isEnabled, pendingRebuild else { break }
            pendingRebuild = false
            let replaceAll = forceFullRebuild || !hasCompletedInitialRebuild
            forceFullRebuild = false
            statusMessage = "Updating…"

            guard await performRebuild(replaceAll: replaceAll) else {
                pendingRebuild = true
                forceFullRebuild = forceFullRebuild || replaceAll
                shouldRetry = true
                break
            }
        }

        isWorking = false
        workerTask = nil
        if shouldRetry {
            scheduleRetry()
        } else {
            consecutiveFailureCount = 0
            acknowledgeSystemReindexRequestsIfSettled()
        }
    }

    private func performRebuild(replaceAll: Bool) async -> Bool {
        guard let snapshotProvider else { return true }
        guard await writer.isAvailable else {
            statusMessage = "Unavailable on this Mac"
            return false
        }

        do {
            let projection = try await snapshotProvider.projection()
            try Task.checkCancellation()
            let nextIdentifiers = Set(projection.documents.map(\.itemIdentifier))

            if replaceAll {
                try await writer.replaceAll(with: projection.documents)
                hasCompletedInitialRebuild = true
            } else {
                let removals = Array(indexedItemIdentifiers.subtracting(nextIdentifiers))
                try await writer.reconcile(
                    documents: projection.documents,
                    removing: removals
                )
            }

            indexedItemIdentifiers = nextIdentifiers
            indexedItemCount = projection.documents.count
            statusMessage = projection.documents.isEmpty
                ? "Up to date — no eligible shards"
                : "Up to date — \(projection.documents.count) indexed"
            return true
        } catch is CancellationError {
            return false
        } catch {
            statusMessage = "Will retry — \(error.localizedDescription)"
            return false
        }
    }

    private func performPurge() async -> Bool {
        guard await writer.isAvailable else {
            statusMessage = isEnabled ? "Unavailable on this Mac" : "Off — removal pending"
            return false
        }

        do {
            try await writer.purge()
            indexedItemIdentifiers = []
            indexedItemCount = 0
            hasCompletedInitialRebuild = false
            if !persistentStoreAvailable {
                statusMessage = "Vault unavailable"
            } else {
                statusMessage = isEnabled ? "Ready to rebuild" : "Off"
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            statusMessage = "Could not remove index — \(error.localizedDescription)"
            return false
        }
    }

    private func schedulePurge() {
        debounceTask?.cancel()
        debounceTask = nil
        retryTask?.cancel()
        retryTask = nil
        pendingRebuild = false
        forceFullRebuild = false
        pendingPurge = true
        startWorkerIfNeeded()
    }

    private func scheduleRetry() {
        consecutiveFailureCount += 1
        let delaySeconds = min(60, 5 * (1 << min(consecutiveFailureCount - 1, 3)))
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delaySeconds))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.startWorkerIfNeeded()
        }
    }

    private func acknowledgeSystemReindexRequestsIfSettled() {
        guard !pendingPurge, !pendingRebuild else { return }
        let acknowledgements = systemReindexAcknowledgements
        systemReindexAcknowledgements.removeAll(keepingCapacity: true)
        acknowledgements.forEach { $0.call() }
    }
}

@MainActor
final class SpotlightOpenRequestStore {
    static let shared = SpotlightOpenRequestStore()

    private var pendingShardID: String?

    func requestOpen(shardID: String) {
        pendingShardID = shardID
        NotificationCenter.default.post(name: .openShardRequested, object: shardID)
    }

    func peek() -> String? {
        pendingShardID
    }

    func clear(ifMatching shardID: String) {
        guard pendingShardID == shardID else { return }
        pendingShardID = nil
    }
}
