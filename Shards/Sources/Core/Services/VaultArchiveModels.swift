import Foundation

struct ShardExport: Codable, Sendable {
    var id: String
    var encryptionMode: String
    var collectionId: String?
    var tagIds: [String]
    var isPinned: Bool
    var displayName: String?
    var deletedAt: Date?
    var payload: String
    var createdAt: Date
    var updatedAt: Date

    init(shard: Shard) {
        id = shard.id
        collectionId = shard.collectionId
        tagIds = shard.tagIds
        encryptionMode = shard.encryptionMode.rawValue
        isPinned = shard.isPinned
        displayName = shard.displayName
        deletedAt = shard.deletedAt
        payload = shard.payload
        createdAt = shard.createdAt
        updatedAt = shard.updatedAt
    }
}

struct TagExport: Codable, Sendable {
    var id: String
    var name: String
    var colorHex: String
    var symbol: String
    var isSystem: Bool

    init(tag: Tag) {
        id = tag.id
        name = tag.name
        colorHex = tag.colorHex
        symbol = tag.symbol
        isSystem = tag.isSystem
    }
}

struct TemplateExport: Codable, Sendable {
    var id: String
    var name: String
    var symbol: String
    var targetCollectionName: String
    var targetTagName: String?
    var schemaFieldsJSON: String
    var orderIndex: Int

    init(template: PresetTemplate) {
        id = template.id
        name = template.name
        symbol = template.symbol
        targetCollectionName = template.targetCollectionName
        targetTagName = template.targetTagName
        schemaFieldsJSON = template.schemaFieldsJSON
        orderIndex = template.orderIndex
    }
}

struct CollectionExport: Codable, Sendable {
    var id: String
    var name: String
    var icon: String
    var parentId: String?
    var createdAt: Date

    init(collection: ShardCollection) {
        id = collection.id
        name = collection.name
        icon = collection.icon
        parentId = collection.parentId
        createdAt = collection.createdAt
    }
}

struct AttachmentExport: Codable, Sendable {
    var id: String
    var shardId: String
    var originalName: String
    var storedFileName: String
    var createdAt: Date

    init(attachment: ShardAttachment) {
        id = attachment.id
        shardId = attachment.shardId
        originalName = attachment.originalName
        storedFileName = attachment.storedFileName
        createdAt = attachment.createdAt
    }
}

struct ExportPackage: Codable, Sendable {
    var shards: [ShardExport]
    var tags: [TagExport]
    var templates: [TemplateExport]
    var collections: [CollectionExport]
    var exportedAt: Date
    var formatVersion: Int?
    var attachments: [AttachmentExport]?
    var reason: String?
    var appVersion: String?
    var appBuild: String?

    init(
        shards: [ShardExport],
        tags: [TagExport],
        templates: [TemplateExport],
        collections: [CollectionExport],
        exportedAt: Date,
        formatVersion: Int? = nil,
        attachments: [AttachmentExport]? = nil,
        reason: String? = nil,
        appVersion: String? = nil,
        appBuild: String? = nil
    ) {
        self.shards = shards
        self.tags = tags
        self.templates = templates
        self.collections = collections
        self.exportedAt = exportedAt
        self.formatVersion = formatVersion
        self.attachments = attachments
        self.reason = reason
        self.appVersion = appVersion
        self.appBuild = appBuild
    }
}
