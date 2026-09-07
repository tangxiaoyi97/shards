import AppKit
import Foundation
import SwiftData

extension Notification.Name {
    static let shardsWerePermanentlyDeleted = Notification.Name("shardsWerePermanentlyDeleted")
}

enum ShardBatchOperation: Equatable, Sendable {
    case setPinned(Bool)
    case addTag(String)
    case removeTag(String)
    case moveToTrash
    case restore

    fileprivate func apply(to shard: Shard, now: Date) -> Bool {
        switch self {
        case let .setPinned(isPinned):
            guard shard.isPinned != isPinned else { return false }
            shard.isPinned = isPinned
        case let .addTag(tagID):
            guard !shard.tagIds.contains(tagID) else { return false }
            shard.tagIds.append(tagID)
        case let .removeTag(tagID):
            guard shard.tagIds.contains(tagID) else { return false }
            shard.tagIds.removeAll { $0 == tagID }
        case .moveToTrash:
            guard shard.deletedAt == nil else { return false }
            shard.deletedAt = now
        case .restore:
            guard shard.deletedAt != nil else { return false }
            shard.deletedAt = nil
        }

        shard.updatedAt = now
        return true
    }

    fileprivate func actionName(count: Int) -> String {
        let noun = count == 1 ? "Shard" : "Shards"
        switch self {
        case let .setPinned(isPinned):
            return "\(isPinned ? "Pin" : "Unpin") \(count) \(noun)"
        case .addTag:
            return "Add Tag to \(count) \(noun)"
        case .removeTag:
            return "Remove Tag from \(count) \(noun)"
        case .moveToTrash:
            return "Move \(count) \(noun) to Trash"
        case .restore:
            return "Restore \(count) \(noun)"
        }
    }

    fileprivate var allowsLockedShards: Bool {
        if case .restore = self { return true }
        return false
    }
}

struct ShardBatchState: Equatable, Sendable {
    let id: String
    let tagIDs: [String]
    let isPinned: Bool
    let deletedAt: Date?
    let updatedAt: Date

    init(shard: Shard) {
        id = shard.id
        tagIDs = shard.tagIds
        isPinned = shard.isPinned
        deletedAt = shard.deletedAt
        updatedAt = shard.updatedAt
    }

    fileprivate func restore(on shard: Shard) {
        shard.tagIds = tagIDs
        shard.isPinned = isPinned
        shard.deletedAt = deletedAt
        shard.updatedAt = updatedAt
    }
}

struct ShardBatchChange: Equatable, Sendable {
    let before: ShardBatchState
    let after: ShardBatchState
}

struct ShardBatchReceipt: Equatable, Sendable {
    let changes: [ShardBatchChange]
    let skippedLockedIDs: [String]
    let missingIDs: [String]
    let actionName: String

    var changedIDs: [String] { changes.map(\.before.id) }
    var changedCount: Int { changes.count }
}

struct ShardPermanentDeleteReceipt: Equatable, Sendable {
    let deletedIDs: [String]
    let skippedLockedIDs: [String]
    let skippedLiveIDs: [String]
    let missingIDs: [String]
}

enum ShardBatchReplayDirection: Equatable, Sendable {
    case undo
    case redo
}

enum ShardBatchError: LocalizedError, Equatable {
    case missingTag
    case pendingChanges
    case stateConflict
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingTag:
            return "The selected tag no longer exists."
        case .pendingChanges:
            return "Save the current editor changes before continuing."
        case .stateConflict:
            return "The shards changed after this action, so Shards did not overwrite the newer changes."
        case let .persistenceFailed(message):
            return "The vault could not save this change. \(message)"
        }
    }
}

@MainActor
final class ShardBatchService {
    private let context: ModelContext
    private let now: () -> Date

    init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    func apply(
        _ operation: ShardBatchOperation,
        to shardIDs: [String],
        lockedTagID: String?
    ) throws -> ShardBatchReceipt {
        let uniqueIDs = Self.uniqued(shardIDs)
        let requestedIDs = Set(uniqueIDs)
        let allShards = try context.fetch(FetchDescriptor<Shard>())
        let shardByID = Dictionary(uniqueKeysWithValues: allShards.map { ($0.id, $0) })
        let missingIDs = uniqueIDs.filter { shardByID[$0] == nil }

        if case let .addTag(tagID) = operation {
            try validateTag(tagID)
        } else if case let .removeTag(tagID) = operation {
            try validateTag(tagID)
        }

        let timestamp = now()
        var changes: [ShardBatchChange] = []
        var skippedLockedIDs: [String] = []

        do {
            for id in uniqueIDs where requestedIDs.contains(id) {
                guard let shard = shardByID[id] else { continue }
                let isLocked = lockedTagID.map(shard.tagIds.contains) ?? false
                if isLocked && !operation.allowsLockedShards {
                    skippedLockedIDs.append(id)
                    continue
                }

                let before = ShardBatchState(shard: shard)
                guard operation.apply(to: shard, now: timestamp) else { continue }
                changes.append(ShardBatchChange(before: before, after: ShardBatchState(shard: shard)))
            }

            if !changes.isEmpty {
                try context.save()
            }
        } catch {
            context.rollback()
            if let batchError = error as? ShardBatchError { throw batchError }
            throw ShardBatchError.persistenceFailed(error.localizedDescription)
        }

        return ShardBatchReceipt(
            changes: changes,
            skippedLockedIDs: skippedLockedIDs,
            missingIDs: missingIDs,
            actionName: operation.actionName(count: changes.count)
        )
    }

    func replay(_ receipt: ShardBatchReceipt, direction: ShardBatchReplayDirection) throws {
        guard !receipt.changes.isEmpty else { return }
        let allShards = try context.fetch(FetchDescriptor<Shard>())
        let shardByID = Dictionary(uniqueKeysWithValues: allShards.map { ($0.id, $0) })

        let resolved: [(shard: Shard, expected: ShardBatchState, target: ShardBatchState)] = try receipt.changes.map { change in
            guard let shard = shardByID[change.before.id] else {
                throw ShardBatchError.stateConflict
            }
            switch direction {
            case .undo:
                return (shard, change.after, change.before)
            case .redo:
                return (shard, change.before, change.after)
            }
        }

        guard resolved.allSatisfy({ ShardBatchState(shard: $0.shard) == $0.expected }) else {
            throw ShardBatchError.stateConflict
        }

        do {
            for item in resolved {
                item.target.restore(on: item.shard)
            }
            try context.save()
        } catch {
            context.rollback()
            if let batchError = error as? ShardBatchError { throw batchError }
            throw ShardBatchError.persistenceFailed(error.localizedDescription)
        }
    }

    func permanentlyDelete(
        shardIDs: [String],
        lockedTagID: String?
    ) throws -> ShardPermanentDeleteReceipt {
        let uniqueIDs = Self.uniqued(shardIDs)
        let allShards = try context.fetch(FetchDescriptor<Shard>())
        let shardByID = Dictionary(uniqueKeysWithValues: allShards.map { ($0.id, $0) })
        let missingIDs = uniqueIDs.filter { shardByID[$0] == nil }
        var eligible: [Shard] = []
        var skippedLockedIDs: [String] = []
        var skippedLiveIDs: [String] = []

        for id in uniqueIDs {
            guard let shard = shardByID[id] else { continue }
            if lockedTagID.map(shard.tagIds.contains) ?? false {
                skippedLockedIDs.append(id)
            } else if shard.deletedAt == nil {
                skippedLiveIDs.append(id)
            } else {
                eligible.append(shard)
            }
        }

        // Snapshot every value needed for the receipt before deleting the
        // SwiftData models. Persisted properties are invalid after deletion.
        let deletedIDs = eligible.map(\.id)

        do {
            if !deletedIDs.isEmpty {
                let eligibleIDs = Set(deletedIDs)
                let attachments = try context.fetch(FetchDescriptor<ShardAttachment>())
                for attachment in attachments where eligibleIDs.contains(attachment.shardId) {
                    context.delete(attachment)
                }
                eligible.forEach(context.delete)
                try context.save()
            }
        } catch {
            context.rollback()
            throw ShardBatchError.persistenceFailed(error.localizedDescription)
        }

        return ShardPermanentDeleteReceipt(
            deletedIDs: deletedIDs,
            skippedLockedIDs: skippedLockedIDs,
            skippedLiveIDs: skippedLiveIDs,
            missingIDs: missingIDs
        )
    }

    private func validateTag(_ id: String) throws {
        let tags = try context.fetch(FetchDescriptor<Tag>())
        guard tags.contains(where: { $0.id == id }) else {
            throw ShardBatchError.missingTag
        }
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

@MainActor
final class VaultBatchUndoController: NSObject {
    var onError: ((String) -> Void)?
    var prepareForReplay: (() -> Bool)?

    func register(
        _ receipt: ShardBatchReceipt,
        with undoManager: UndoManager?,
        repository: VaultRepository
    ) {
        guard !receipt.changes.isEmpty, let undoManager else { return }
        register(
            receipt,
            direction: .undo,
            with: undoManager,
            repository: repository
        )
    }

    private func register(
        _ receipt: ShardBatchReceipt,
        direction: ShardBatchReplayDirection,
        with undoManager: UndoManager,
        repository: VaultRepository
    ) {
        undoManager.registerUndo(withTarget: self) { target in
            target.perform(
                receipt,
                direction: direction,
                with: undoManager,
                repository: repository
            )
        }
        undoManager.setActionName(receipt.actionName)
    }

    private func perform(
        _ receipt: ShardBatchReceipt,
        direction: ShardBatchReplayDirection,
        with undoManager: UndoManager,
        repository: VaultRepository
    ) {
        guard prepareForReplay?() ?? true else { return }
        do {
            try repository.replayBatch(receipt, direction: direction)
            register(
                receipt,
                direction: direction == .undo ? .redo : .undo,
                with: undoManager,
                repository: repository
            )
        } catch {
            onError?(error.localizedDescription)
        }
    }
}
