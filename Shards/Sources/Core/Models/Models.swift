import Foundation
import SwiftData

// MARK: - Encryption Mode
enum EncryptionMode: String, Codable, Sendable {
    case none
    case perShard
    case global
}

// MARK: - Models
@Model
class ShardCollection: Identifiable {
    @Attribute(.unique) var id: String
    var parentId: String?
    var name: String
    var icon: String
    var createdAt: Date

    init(id: String = UUID().uuidString, parentId: String? = nil, name: String, icon: String, createdAt: Date = Date()) {
        self.id = id
        self.parentId = parentId
        self.name = name
        self.icon = icon
        self.createdAt = createdAt
    }
}

@Model
class Tag: Identifiable {
    @Attribute(.unique) var id: String
    var name: String
    var colorHex: String
    var symbol: String
    var isSystem: Bool

    init(id: String = UUID().uuidString, name: String, colorHex: String, symbol: String, isSystem: Bool = false) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.symbol = symbol
        self.isSystem = isSystem
    }
}

@Model
class PresetTemplate: Identifiable {
    @Attribute(.unique) var id: String
    var name: String
    var symbol: String
    var targetCollectionName: String
    var targetTagName: String?
    var schemaFieldsJSON: String
    var orderIndex: Int

    init(
        id: String = UUID().uuidString,
        name: String,
        symbol: String,
        targetCollectionName: String,
        targetTagName: String? = nil,
        schemaFieldsJSON: String,
        orderIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.targetCollectionName = targetCollectionName
        self.targetTagName = targetTagName
        self.schemaFieldsJSON = schemaFieldsJSON
        self.orderIndex = orderIndex
    }

    var schema: PresetTemplateSchema {
        if let data = schemaFieldsJSON.data(using: .utf8) {
            if let schema = try? JSONDecoder().decode(PresetTemplateSchema.self, from: data) {
                return schema
            }
            if let fields = try? JSONDecoder().decode([PresetField].self, from: data) {
                return PresetTemplateSchema.fromLegacyFields(fields, templateName: name)
            }
        }
        return PresetTemplateSchema.empty(templateName: name)
    }

    var fields: [PresetField] {
        schema.fields.map(\.emptyValue)
    }

    var aiDescription: String {
        schema.aiDescription(templateName: name, categoryName: targetCollectionName)
    }
}

@Model
class Shard: Identifiable {
    @Attribute(.unique) var id: String
    var collectionId: String?
    var tagIds: [String]
    var encryptionMode: EncryptionMode
    var isPinned: Bool
    var displayName: String?
    var deletedAt: Date?
    var payload: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        collectionId: String? = nil,
        tagIds: [String] = [],
        encryptionMode: EncryptionMode = .none,
        isPinned: Bool = false,
        displayName: String? = nil,
        deletedAt: Date? = nil,
        payload: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.collectionId = collectionId
        self.tagIds = tagIds
        self.encryptionMode = encryptionMode
        self.isPinned = isPinned
        self.displayName = displayName
        self.deletedAt = deletedAt
        self.payload = payload
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
class ShardAttachment: Identifiable {
    @Attribute(.unique) var id: String
    var shardId: String
    var originalName: String
    var storedFileName: String
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        shardId: String,
        originalName: String,
        storedFileName: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.shardId = shardId
        self.originalName = originalName
        self.storedFileName = storedFileName
        self.createdAt = createdAt
    }
}

// MARK: - Template Schema
struct PresetTemplateSchema: Codable, Sendable {
    enum PresentationStyle: String, Codable, Sendable {
        case plainText
        case table

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = (try? container.decode(String.self))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            switch rawValue {
            case "table":
                self = .table
            default:
                self = .plainText
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    var version: Int
    var summary: String
    var useCases: [String]
    var outputNotes: String?
    var presentationStyle: PresentationStyle
    var titleFieldKey: String?
    var displayFormat: String?
    var fields: [PresetFieldDefinition]

    static func empty(templateName: String) -> PresetTemplateSchema {
        PresetTemplateSchema(
            version: 1,
            summary: "\(templateName) shard",
            useCases: [],
            outputNotes: nil,
            presentationStyle: .plainText,
            titleFieldKey: nil,
            displayFormat: nil,
            fields: []
        )
    }

    static func fromLegacyFields(_ fields: [PresetField], templateName: String) -> PresetTemplateSchema {
        let normalizedFields = fields.map {
            PresetFieldDefinition(
                key: normalizedKey(for: $0.name),
                name: $0.name,
                valueType: inferredValueType(for: $0.name),
                placeholder: nil,
                isRequired: $0.isRequired,
                isSensitive: inferredIsSensitive(for: $0.name),
                helpText: nil
            )
        }
        let presentationStyle = inferredPresentationStyle(for: templateName, fields: normalizedFields)
        let titleFieldKey = inferredTitleFieldKey(for: templateName, fields: normalizedFields)
        return PresetTemplateSchema(
            version: 1,
            summary: "\(templateName) shard",
            useCases: [],
            outputNotes: nil,
            presentationStyle: presentationStyle,
            titleFieldKey: titleFieldKey,
            displayFormat: nil,
            fields: normalizedFields
        )
    }

    func aiDescription(templateName: String, categoryName: String) -> String {
        let fieldText = fields
            .map { field in
                var fragments = ["\(field.name): \(field.valueType.rawValue)"]
                if field.isRequired {
                    fragments.append("required")
                }
                if let helpText = field.helpText, !helpText.isEmpty {
                    fragments.append(helpText)
                }
                return fragments.joined(separator: ", ")
            }
            .joined(separator: "; ")

        let useCaseText = useCases.isEmpty ? "General use." : useCases.joined(separator: " / ")
        let notesText = outputNotes?.isEmpty == false ? " Notes: \(outputNotes!)." : ""
        let titleText = titleFieldKey.map { " Title field: \($0)." } ?? ""
        return "\(templateName) -> category \(categoryName). Summary: \(summary). Presentation: \(presentationStyle.rawValue). Use when: \(useCaseText). Fields: \(fieldText).\(titleText)\(notesText)"
    }

    private static func inferredPresentationStyle(
        for templateName: String,
        fields: [PresetFieldDefinition]
    ) -> PresentationStyle {
        if fields.count == 1,
           let field = fields.first,
           field.valueType == .note || field.key == "content" || field.key == "body" || field.key == "text" {
            return .plainText
        }
        return .table
    }

    private static func inferredTitleFieldKey(
        for templateName: String,
        fields: [PresetFieldDefinition]
    ) -> String? {
        if inferredPresentationStyle(for: templateName, fields: fields) != .table {
            return fields.first?.key
        }

        let preferredKeys = ["title", "name", "platform", "service", "account"]
        for preferredKey in preferredKeys {
            if let field = fields.first(where: { $0.key == preferredKey }) {
                return field.key
            }
        }
        return fields.first?.key
    }

    private static func inferredValueType(for fieldName: String) -> PresetFieldDefinition.ValueType {
        let normalizedName = fieldName.lowercased()
        if normalizedName.contains("email") {
            return .email
        }
        if normalizedName.contains("url") || normalizedName.contains("link") || normalizedName.contains("website") {
            return .url
        }
        if normalizedName.contains("note") || normalizedName.contains("content") || normalizedName.contains("body") || normalizedName.contains("text") {
            return .note
        }
        if inferredIsSensitive(for: fieldName) {
            return .secret
        }
        return .text
    }

    private static func inferredIsSensitive(for fieldName: String) -> Bool {
        let normalizedName = fieldName.lowercased()
        return normalizedName.contains("password") || normalizedName.contains("token") || normalizedName.contains("secret") || normalizedName.contains("key")
    }

    private static func normalizedKey(for fieldName: String) -> String {
        fieldName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }
}

struct PresetFieldDefinition: Codable, Identifiable, Sendable {
    enum ValueType: String, Codable, Sendable {
        case text
        case secret
        case email
        case url
        case note
    }

    var id: String = UUID().uuidString
    var key: String
    var name: String
    var valueType: ValueType
    var placeholder: String?
    var isRequired: Bool
    var isSensitive: Bool
    var helpText: String?

    var emptyValue: PresetField {
        PresetField(id: id, name: name, value: "", isRequired: isRequired)
    }
}

// MARK: - Payload
struct PresetField: Codable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var value: String
    var isRequired: Bool = false
}

struct PresetPayload: Codable, Sendable {
    var presetType: String
    var fields: [PresetField]
    var preferredStyle: String?
}

struct SmartInputResult: Sendable {
    var templateName: String?
    var payload: PresetPayload
}

struct SmartTemplateDescriptor: Sendable {
    var name: String
    var orderIndex: Int
    var categoryName: String
    var schema: PresetTemplateSchema
    var aiDescription: String
}

extension PresetTemplate {
    var smartDescriptor: SmartTemplateDescriptor {
        SmartTemplateDescriptor(
            name: name,
            orderIndex: orderIndex,
            categoryName: targetCollectionName,
            schema: schema,
            aiDescription: aiDescription
        )
    }

    var presentationStyle: PresetTemplateSchema.PresentationStyle {
        schema.presentationStyle
    }
}

extension PresetField {
    var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension String {
    var normalizedFieldKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }

    func displayTitleCandidate(maxLength: Int = 35) -> String? {
        var isInsideFencedCodeBlock = false

        for rawLine in components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                isInsideFencedCodeBlock.toggle()
                continue
            }
            guard !isInsideFencedCodeBlock else { continue }
            guard line.range(of: #"^\s*(?:[-*_]\s*){3,}$"#, options: .regularExpression) == nil else { continue }
            guard line.range(of: #"^\s*\|?(?:\s*:?-{3,}:?\s*\|)+\s*$"#, options: .regularExpression) == nil else { continue }

            line = line.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^>\s*"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*[-*+]\s+\[(?: |x|X)\]\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*[-*+]\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*\d+[.)]\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"!\[([^\]]*)\]\([^\)]*\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]*\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"<(https?://[^>]+)>"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"`{1,3}"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"(\*\*|__|~~|\*|_)"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: "|", with: " ")
            line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !line.isEmpty else { continue }
            let prefix = String(line.prefix(maxLength))
            return line.count > maxLength ? "\(prefix)..." : prefix
        }

        return nil
    }
}

extension PresetPayload {
    static func raw(_ text: String) -> PresetPayload {
        PresetPayload(
            presetType: "Raw",
            fields: [PresetField(name: "Content", value: text, isRequired: true)]
        )
    }

    var isRaw: Bool {
        presetType.caseInsensitiveCompare("Raw") == .orderedSame
    }

    var normalizedPresetType: String {
        presetType.caseInsensitiveCompare("Note") == .orderedSame ? "Shard" : presetType
    }

    var primaryTextField: PresetField? {
        let preferredKeys = ["content", "body", "text", "note"]
        for key in preferredKeys {
            if let field = fields.first(where: { $0.name.normalizedFieldKey == key }) {
                return field
            }
        }
        return fields.first
    }

    var plainTextContent: String {
        if isRaw {
            return fields.first(where: { $0.name.normalizedFieldKey == "content" })?.value ?? ""
        }

        if fields.count == 1, let first = fields.first {
            return first.value
        }

        return fields
            .filter { !$0.trimmedValue.isEmpty }
            .map { "\($0.name): \($0.value)" }
            .joined(separator: "\n")
    }

    var titleCandidate: String? {
        if let titleField = fields.first(where: { ["title", "name"].contains($0.name.normalizedFieldKey) }),
           !titleField.trimmedValue.isEmpty {
            return titleField.trimmedValue
        }

        if let primaryTextField,
           let textTitle = primaryTextField.value.displayTitleCandidate(),
           !textTitle.isEmpty {
            return textTitle
        }

        return fields
            .first(where: { !$0.trimmedValue.isEmpty })?
            .trimmedValue
    }

    var displayTitle: String {
        if isRaw {
            return titleCandidate ?? "Untitled Shard"
        }

        switch normalizedPresetType.lowercased() {
        case "shard":
            return titleCandidate ?? "Untitled Shard"
        case "password":
            let platform = fields.first(where: { $0.name == "Platform" })?.trimmedValue
            return platform.flatMap { $0.isEmpty ? nil : "\($0) Password" } ?? "Secure Password"
        case "token":
            let platform = fields.first(where: { $0.name == "Platform" })?.trimmedValue
            return platform.flatMap { $0.isEmpty ? nil : "\($0) Token" } ?? "Secret Token"
        default:
            return titleCandidate ?? normalizedPresetType
        }
    }
}
