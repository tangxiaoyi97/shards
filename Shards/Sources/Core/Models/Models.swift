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

    var decodedSchema: PresetTemplateSchema? {
        if let data = schemaFieldsJSON.data(using: .utf8) {
            if let schema = try? JSONDecoder().decode(PresetTemplateSchema.self, from: data) {
                return schema
            }
            if let fields = try? JSONDecoder().decode([PresetField].self, from: data) {
                return PresetTemplateSchema.fromLegacyFields(fields, templateName: name)
            }
        }
        return nil
    }

    var schema: PresetTemplateSchema {
        decodedSchema ?? PresetTemplateSchema.empty(templateName: name)
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
    static let currentVersion = 2

    enum PresentationStyle: Codable, Hashable, Sendable {
        case plainText
        case table
        case custom(String)

        var rawValue: String {
            switch self {
            case .plainText: "plainText"
            case .table: "table"
            case let .custom(value): value
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "table":
                self = .table
            case "plaintext", "plain_text", "plain", "markdown", "":
                self = .plainText
            default:
                self = .custom(rawValue)
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

    init(
        version: Int = currentVersion,
        summary: String,
        useCases: [String] = [],
        outputNotes: String? = nil,
        presentationStyle: PresentationStyle = .table,
        titleFieldKey: String? = nil,
        displayFormat: String? = nil,
        fields: [PresetFieldDefinition]
    ) {
        self.version = version
        self.summary = summary
        self.useCases = useCases
        self.outputNotes = outputNotes
        self.presentationStyle = presentationStyle
        self.titleFieldKey = titleFieldKey
        self.displayFormat = displayFormat
        self.fields = fields
    }

    private enum CodingKeys: String, CodingKey {
        case version, summary, useCases, outputNotes, presentationStyle
        case titleFieldKey, displayFormat, fields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? "Custom shard"
        useCases = try container.decodeIfPresent([String].self, forKey: .useCases) ?? []
        outputNotes = try container.decodeIfPresent(String.self, forKey: .outputNotes)
        presentationStyle = try container.decodeIfPresent(PresentationStyle.self, forKey: .presentationStyle) ?? .table
        titleFieldKey = try container.decodeIfPresent(String.self, forKey: .titleFieldKey)
        displayFormat = try container.decodeIfPresent(String.self, forKey: .displayFormat)
        fields = try container.decodeIfPresent([PresetFieldDefinition].self, forKey: .fields) ?? []
    }

    static func empty(templateName: String) -> PresetTemplateSchema {
        PresetTemplateSchema(
            version: currentVersion,
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
            version: currentVersion,
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
    enum ValueType: Codable, Hashable, CaseIterable, Sendable {
        case text
        case secret
        case licenseKey
        case username
        case email
        case url
        case phone
        case number
        case date
        case note
        case code
        case custom(String)

        static let allCases: [ValueType] = [
            .text, .username, .email, .url, .phone, .number, .date,
            .note, .code, .secret, .licenseKey
        ]

        var rawValue: String {
            switch self {
            case .text: "text"
            case .secret: "secret"
            case .licenseKey: "licenseKey"
            case .username: "username"
            case .email: "email"
            case .url: "url"
            case .phone: "phone"
            case .number: "number"
            case .date: "date"
            case .note: "note"
            case .code: "code"
            case let .custom(value): value
            }
        }

        var displayName: String {
            switch self {
            case .text: "Text"
            case .secret: "Secret"
            case .licenseKey: "License Key"
            case .username: "Username"
            case .email: "Email"
            case .url: "URL"
            case .phone: "Phone"
            case .number: "Number"
            case .date: "Date"
            case .note: "Long Text"
            case .code: "Code"
            case let .custom(value): value
            }
        }

        var isSensitiveByDefault: Bool {
            self == .secret || self == .licenseKey
        }

        var isLongForm: Bool {
            self == .note
        }

        var usesMonospacedText: Bool {
            self == .secret || self == .licenseKey || self == .code
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "text": self = .text
            case "secret", "password": self = .secret
            case "licensekey", "license_key", "licencekey", "licence_key": self = .licenseKey
            case "username", "user_name": self = .username
            case "email": self = .email
            case "url", "link": self = .url
            case "phone", "telephone": self = .phone
            case "number", "numeric": self = .number
            case "date": self = .date
            case "note", "multiline", "longtext", "long_text": self = .note
            case "code", "source": self = .code
            default: self = .custom(rawValue)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    var id: String = UUID().uuidString
    var key: String
    var name: String
    var valueType: ValueType
    var placeholder: String?
    var isRequired: Bool
    var isSensitive: Bool
    var helpText: String?

    init(
        id: String? = nil,
        key: String,
        name: String,
        valueType: ValueType = .text,
        placeholder: String? = nil,
        isRequired: Bool = false,
        isSensitive: Bool? = nil,
        helpText: String? = nil
    ) {
        self.id = id ?? key
        self.key = key
        self.name = name
        self.valueType = valueType
        self.placeholder = placeholder
        self.isRequired = isRequired
        self.isSensitive = isSensitive ?? valueType.isSensitiveByDefault
        self.helpText = helpText
    }

    private enum CodingKeys: String, CodingKey {
        case id, key, name, valueType, placeholder, isRequired, isSensitive, helpText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name)
        key = try container.decodeIfPresent(String.self, forKey: .key)
            ?? decodedName?.normalizedFieldKey
            ?? "field"
        name = decodedName ?? key
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? key
        valueType = try container.decodeIfPresent(ValueType.self, forKey: .valueType) ?? .text
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired) ?? false
        isSensitive = try container.decodeIfPresent(Bool.self, forKey: .isSensitive)
            ?? valueType.isSensitiveByDefault
        helpText = try container.decodeIfPresent(String.self, forKey: .helpText)
    }

    var emptyValue: PresetField {
        PresetField(
            id: id,
            key: key,
            name: name,
            value: "",
            isRequired: isRequired,
            valueType: valueType,
            isSensitive: isSensitive,
            placeholder: placeholder,
            helpText: helpText
        )
    }
}

// MARK: - Payload
struct PresetField: Codable, Identifiable, Sendable {
    var id: String
    var key: String?
    var name: String
    var value: String
    var isRequired: Bool
    var valueType: PresetFieldDefinition.ValueType?
    var isSensitive: Bool?
    var placeholder: String?
    var helpText: String?

    init(
        id: String = UUID().uuidString,
        key: String? = nil,
        name: String,
        value: String,
        isRequired: Bool = false,
        valueType: PresetFieldDefinition.ValueType? = nil,
        isSensitive: Bool? = nil,
        placeholder: String? = nil,
        helpText: String? = nil
    ) {
        self.id = id
        self.key = key
        self.name = name
        self.value = value
        self.isRequired = isRequired
        self.valueType = valueType
        self.isSensitive = isSensitive
        self.placeholder = placeholder
        self.helpText = helpText
    }

    private enum CodingKeys: String, CodingKey {
        case id, key, name, value, isRequired, valueType, isSensitive, placeholder, helpText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? key
            ?? "Field"
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? key
            ?? name.normalizedFieldKey
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired) ?? false
        valueType = try container.decodeIfPresent(PresetFieldDefinition.ValueType.self, forKey: .valueType)
        isSensitive = try container.decodeIfPresent(Bool.self, forKey: .isSensitive)
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        helpText = try container.decodeIfPresent(String.self, forKey: .helpText)
    }
}

struct PresetPayload: Codable, Sendable {
    var presetType: String
    var fields: [PresetField]
    var preferredStyle: String?
    var templateID: String?

    init(
        presetType: String,
        fields: [PresetField],
        preferredStyle: String? = nil,
        templateID: String? = nil
    ) {
        self.presetType = presetType
        self.fields = Self.uniquelyIdentified(fields)
        self.preferredStyle = preferredStyle
        self.templateID = templateID
    }

    private enum CodingKeys: String, CodingKey {
        case presetType, fields, preferredStyle, templateID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.presetType) else {
            throw DecodingError.keyNotFound(
                CodingKeys.presetType,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "A structured shard requires a presetType."
                )
            )
        }
        guard container.contains(.fields) else {
            throw DecodingError.keyNotFound(
                CodingKeys.fields,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "A structured shard requires fields."
                )
            )
        }

        presetType = try container.decode(String.self, forKey: .presetType)
        fields = Self.uniquelyIdentified(
            try container.decode([PresetField].self, forKey: .fields)
        )
        preferredStyle = try container.decodeIfPresent(String.self, forKey: .preferredStyle)
        templateID = try container.decodeIfPresent(String.self, forKey: .templateID)
    }

    private static func uniquelyIdentified(_ fields: [PresetField]) -> [PresetField] {
        var usedIDs = Set<String>()
        return fields.enumerated().map { index, field in
            var field = field
            let baseID = field.id.isEmpty ? field.normalizedKey : field.id
            let stem = baseID.isEmpty ? "field-\(index + 1)" : baseID
            var candidate = stem
            var suffix = 2
            while usedIDs.contains(candidate) {
                candidate = "\(stem)-\(suffix)"
                suffix += 1
            }
            field.id = candidate
            usedIDs.insert(candidate)
            return field
        }
    }
}

enum PresetPayloadDecodingResult {
    case decoded(PresetPayload)
    case plainText
    case malformedStructured
}

struct PresetDisplayNameEvaluation: Equatable, Sendable {
    let value: String
    let includesSensitiveField: Bool
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
    var templateID: String? = nil
}

extension PresetTemplate {
    var smartDescriptor: SmartTemplateDescriptor {
        SmartTemplateDescriptor(
            name: name,
            orderIndex: orderIndex,
            categoryName: targetCollectionName,
            schema: schema,
            aiDescription: aiDescription,
            templateID: id
        )
    }

    var presentationStyle: PresetTemplateSchema.PresentationStyle {
        schema.presentationStyle
    }
}

extension Collection where Element == PresetTemplate {
    func matchingTemplate(for payload: PresetPayload) -> PresetTemplate? {
        if let templateID = payload.templateID,
           let match = first(where: { $0.id == templateID }) {
            return match
        }
        return first(where: {
            $0.name.caseInsensitiveCompare(payload.presetType) == .orderedSame
        })
    }
}

extension PresetField {
    var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedKey: String {
        (key.flatMap { $0.isEmpty ? nil : $0 } ?? name).normalizedFieldKey
    }

    var isEffectivelySensitive: Bool {
        if isSensitive == true || valueType?.isSensitiveByDefault == true {
            return true
        }

        let token = normalizedKey
        let sensitiveTokens = [
            "password", "passphrase", "token", "secret", "private_key",
            "api_key", "access_key", "license_key", "licence_key",
            "license_code", "licence_code", "activation_key", "activation_code",
            "recovery_key"
        ]
        return sensitiveTokens.contains(where: {
            token == $0
                || token.hasPrefix("\($0)_")
                || token.hasSuffix("_\($0)")
        })
    }

    var isEffectivelyLongForm: Bool {
        valueType?.isLongForm == true || ["content", "body", "text", "note", "notes"].contains(normalizedKey)
    }

    var usesMonospacedText: Bool {
        valueType?.usesMonospacedText == true || isEffectivelySensitive
    }

    func resolvingMetadata(from definition: PresetFieldDefinition?) -> PresetField {
        guard let definition else { return self }
        var resolved = self
        resolved.key = key ?? definition.key
        resolved.valueType = valueType ?? definition.valueType
        // A schema may strengthen the privacy policy after a shard was created.
        // Never let an older or imported `false` snapshot weaken that policy.
        resolved.isSensitive = isSensitive == true || definition.isSensitive
        resolved.placeholder = placeholder ?? definition.placeholder
        resolved.helpText = helpText ?? definition.helpText
        return resolved
    }
}

extension PresetTemplateSchema {
    func definition(matching field: PresetField) -> PresetFieldDefinition? {
        if let exact = fields.first(where: { $0.id == field.id }) {
            return exact
        }

        let fieldTokens = Set([field.key, field.name]
            .compactMap { $0?.normalizedFieldKey }
            .filter { !$0.isEmpty })
        return fields.first { definition in
            fieldTokens.contains(definition.key.normalizedFieldKey)
                || fieldTokens.contains(definition.name.normalizedFieldKey)
        }
    }

    func displayNameEvaluation(for payload: PresetPayload) -> PresetDisplayNameEvaluation? {
        guard var rendered = displayFormat?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rendered.isEmpty else { return nil }
        let resolvedPayload = payload.resolvingMetadata(using: self)
        var includesSensitiveField = false

        for field in resolvedPayload.fields {
            let placeholders = Set([field.key, field.name]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .map { "{\($0)}" })
            if field.isEffectivelySensitive,
               placeholders.contains(where: { placeholder in
                   rendered.range(of: placeholder, options: .caseInsensitive) != nil
               }) {
                includesSensitiveField = true
            }

            for placeholder in placeholders {
                rendered = rendered.replacingOccurrences(
                    of: placeholder,
                    with: field.trimmedValue,
                    options: .caseInsensitive
                )
            }
        }

        guard rendered.range(of: #"\{[^}]+\}"#, options: .regularExpression) == nil else {
            return nil
        }
        rendered = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rendered.isEmpty else { return nil }
        return PresetDisplayNameEvaluation(
            value: rendered,
            includesSensitiveField: includesSensitiveField
        )
    }

    func safeDisplayName(for payload: PresetPayload) -> String? {
        guard let evaluation = displayNameEvaluation(for: payload),
              !evaluation.includesSensitiveField else { return nil }
        return evaluation.value
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
    static func decoding(_ text: String) -> PresetPayloadDecodingResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return .plainText }

        guard let data = text.data(using: .utf8) else { return .plainText }
        if let payload = try? JSONDecoder().decode(PresetPayload.self, from: data) {
            return .decoded(payload)
        }

        if let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            let hasStructuredEnvelope = dictionary["presetType"] != nil
                && dictionary["fields"] != nil
            let hasFieldLikeRecords = (dictionary["fields"] as? [[String: Any]])?.contains { field in
                field["value"] != nil
                    && (field["name"] != nil || field["key"] != nil || field["id"] != nil)
            } == true
            if hasStructuredEnvelope || hasFieldLikeRecords {
                return .malformedStructured
            }
        }

        let hasStructuredEnvelope = trimmed.contains("\"presetType\"")
            && trimmed.contains("\"fields\"")
        let hasFieldLikeRecords = trimmed.contains("\"fields\"")
            && trimmed.contains("\"value\"")
            && (trimmed.contains("\"name\"")
                || trimmed.contains("\"key\"")
                || trimmed.contains("\"id\""))
        if trimmed.hasPrefix("{"), hasStructuredEnvelope || hasFieldLikeRecords {
            return .malformedStructured
        }
        return .plainText
    }

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
            if let field = fields.first(where: { $0.normalizedKey == key }) {
                return field
            }
        }
        return fields.first
    }

    func resolvingMetadata(using schema: PresetTemplateSchema?) -> PresetPayload {
        guard let schema else { return self }
        var resolved = self
        resolved.fields = fields.map { field in
            field.resolvingMetadata(from: schema.definition(matching: field))
        }
        return resolved
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

    var redactedPlainTextContent: String {
        if isRaw {
            return plainTextContent
        }

        return fields
            .filter { !$0.trimmedValue.isEmpty }
            .map { field in
                "\(field.name): \(field.isEffectivelySensitive ? "••••••••" : field.value)"
            }
            .joined(separator: "\n")
    }

    var safeSearchableContent: String {
        fields
            .filter { !$0.isEffectivelySensitive && !$0.trimmedValue.isEmpty }
            .map { "\($0.name) \($0.value)" }
            .joined(separator: "\n")
    }

    func displayNameExposesSensitiveValue(_ displayName: String) -> Bool {
        fields.contains { field in
            guard field.isEffectivelySensitive, !field.trimmedValue.isEmpty else { return false }
            return displayName == field.trimmedValue
                || (field.trimmedValue.count >= 4 && displayName.contains(field.trimmedValue))
        }
    }

    var safePreviewText: String {
        let preferredKeys = ["content", "body", "text", "note", "notes"]
        let visibleFields = fields.filter { !$0.isEffectivelySensitive && !$0.trimmedValue.isEmpty }
        let candidate = preferredKeys.compactMap { key in
            visibleFields.first(where: { $0.normalizedKey == key })
        }.first ?? visibleFields.first

        if let candidate {
            let clean = candidate.value
                .replacingOccurrences(of: "#", with: "")
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "~~", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = clean.components(separatedBy: .newlines)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            return String(firstLine.prefix(80))
        }

        return fields.contains(where: { $0.isEffectivelySensitive && !$0.trimmedValue.isEmpty })
            ? "Sensitive content"
            : ""
    }

    var titleCandidate: String? {
        if let titleField = fields.first(where: {
            ["title", "name"].contains($0.normalizedKey) && !$0.isEffectivelySensitive
        }),
           !titleField.trimmedValue.isEmpty {
            return titleField.trimmedValue
        }

        if let primaryTextField, !primaryTextField.isEffectivelySensitive,
           let textTitle = primaryTextField.value.displayTitleCandidate(),
           !textTitle.isEmpty {
            return textTitle
        }

        return fields
            .first(where: { !$0.isEffectivelySensitive && !$0.trimmedValue.isEmpty })?
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
            let platform = fields.first(where: {
                $0.normalizedKey == "platform" && !$0.isEffectivelySensitive
            })?.trimmedValue
            return platform.flatMap { $0.isEmpty ? nil : "\($0) Password" } ?? "Secure Password"
        case "token":
            let platform = fields.first(where: {
                $0.normalizedKey == "platform" && !$0.isEffectivelySensitive
            })?.trimmedValue
            return platform.flatMap { $0.isEmpty ? nil : "\($0) Token" } ?? "Secret Token"
        default:
            return titleCandidate ?? normalizedPresetType
        }
    }
}
