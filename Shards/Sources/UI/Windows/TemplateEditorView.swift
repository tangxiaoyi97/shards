import SwiftUI

struct TemplateFieldDraft: Identifiable, Equatable {
    var id: String
    var isExistingField: Bool
    var key: String
    var name: String
    var valueType: PresetFieldDefinition.ValueType
    var placeholder: String
    var isRequired: Bool
    var isSensitive: Bool
    var helpText: String

    init(
        id: String = UUID().uuidString,
        isExistingField: Bool = false,
        key: String,
        name: String,
        valueType: PresetFieldDefinition.ValueType = .text,
        placeholder: String = "",
        isRequired: Bool = false,
        isSensitive: Bool? = nil,
        helpText: String = ""
    ) {
        self.id = id
        self.isExistingField = isExistingField
        self.key = key
        self.name = name
        self.valueType = valueType
        self.placeholder = placeholder
        self.isRequired = isRequired
        self.isSensitive = isSensitive ?? valueType.isSensitiveByDefault
        self.helpText = helpText
    }

    init(definition: PresetFieldDefinition) {
        id = definition.id
        isExistingField = true
        key = definition.key
        name = definition.name
        valueType = definition.valueType
        placeholder = definition.placeholder ?? ""
        isRequired = definition.isRequired
        isSensitive = definition.isSensitive
        helpText = definition.helpText ?? ""
    }

    var definition: PresetFieldDefinition {
        PresetFieldDefinition(
            id: id,
            key: key.trimmingCharacters(in: .whitespacesAndNewlines).normalizedFieldKey,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            valueType: valueType,
            placeholder: placeholder.nilIfBlank,
            isRequired: isRequired,
            isSensitive: isSensitive,
            helpText: helpText.nilIfBlank
        )
    }
}

struct TemplateEditorDraft: Identifiable {
    let id = UUID()
    var templateID: String?
    var originalSchemaJSON: String?
    var name: String
    var symbol: String
    var targetCollectionName: String
    var summary: String
    var presentationStyle: PresetTemplateSchema.PresentationStyle
    var titleFieldKey: String
    var displayFormat: String
    var fields: [TemplateFieldDraft]

    static func blank(collectionName: String) -> TemplateEditorDraft {
        TemplateEditorDraft(
            templateID: nil,
            originalSchemaJSON: nil,
            name: "Custom Template",
            symbol: "rectangle.3.group",
            targetCollectionName: collectionName,
            summary: "A custom structured shard.",
            presentationStyle: .table,
            titleFieldKey: "title",
            displayFormat: "",
            fields: [
                TemplateFieldDraft(
                    key: "title",
                    name: "Title",
                    placeholder: "Title",
                    isRequired: true
                ),
                TemplateFieldDraft(
                    key: "content",
                    name: "Content",
                    valueType: .note,
                    placeholder: "Details"
                )
            ]
        )
    }

    static func licenseKey(collectionName: String) -> TemplateEditorDraft {
        TemplateEditorDraft(
            templateID: nil,
            originalSchemaJSON: nil,
            name: "License Key",
            symbol: "key.viewfinder",
            targetCollectionName: collectionName,
            summary: "Software license and activation details.",
            presentationStyle: .table,
            titleFieldKey: "product",
            displayFormat: "{product}",
            fields: [
                TemplateFieldDraft(key: "product", name: "Product", placeholder: "Application name", isRequired: true),
                TemplateFieldDraft(key: "licensee", name: "Licensee", valueType: .username, placeholder: "Name or account"),
                TemplateFieldDraft(key: "license_key", name: "License Key", valueType: .licenseKey, isRequired: true),
                TemplateFieldDraft(key: "expires_at", name: "Expires", valueType: .date, placeholder: "YYYY-MM-DD"),
                TemplateFieldDraft(key: "note", name: "Note", valueType: .note)
            ]
        )
    }

    static func editing(_ template: PresetTemplate) -> TemplateEditorDraft {
        let schema = template.schema
        return TemplateEditorDraft(
            templateID: template.id,
            originalSchemaJSON: template.schemaFieldsJSON,
            name: template.name,
            symbol: template.symbol,
            targetCollectionName: template.targetCollectionName,
            summary: schema.summary,
            presentationStyle: schema.presentationStyle,
            titleFieldKey: schema.titleFieldKey ?? "",
            displayFormat: schema.displayFormat ?? "",
            fields: schema.fields.map(TemplateFieldDraft.init)
        )
    }

    static func duplicating(_ template: PresetTemplate) -> TemplateEditorDraft {
        var copy = editing(template)
        copy.templateID = nil
        copy.name += " Copy"
        copy.fields = copy.fields.map { field in
            var copy = field
            copy.id = UUID().uuidString
            copy.isExistingField = false
            return copy
        }
        return copy
    }

    var schema: PresetTemplateSchema {
        PresetTemplateSchema(
            version: PresetTemplateSchema.currentVersion,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            useCases: [],
            outputNotes: nil,
            presentationStyle: presentationStyle,
            titleFieldKey: titleFieldKey.nilIfBlank?.normalizedFieldKey,
            displayFormat: displayFormat.nilIfBlank,
            fields: fields.map(\.definition)
        )
    }

    func encodedSchemaJSON() throws -> String {
        let editedData = try JSONEncoder().encode(schema)
        guard let originalSchemaJSON,
              let originalData = originalSchemaJSON.data(using: .utf8),
              let originalObject = try? JSONSerialization.jsonObject(with: originalData),
              var merged = originalObject as? [String: Any],
              let editedObject = try? JSONSerialization.jsonObject(with: editedData),
              let edited = editedObject as? [String: Any]
        else {
            guard let encoded = String(data: editedData, encoding: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            return encoded
        }

        if (merged["version"] as? Int ?? 1) <= PresetTemplateSchema.currentVersion {
            merged["version"] = PresetTemplateSchema.currentVersion
        }
        for key in ["summary", "presentationStyle", "titleFieldKey", "displayFormat"] {
            if let value = edited[key] {
                merged[key] = value
            } else {
                merged.removeValue(forKey: key)
            }
        }

        let originalFields = originalSchemaFields(from: merged)
        let editedFields = edited["fields"] as? [[String: Any]] ?? []
        merged["fields"] = editedFields.map { editedField in
            var mergedField = matchingOriginalField(for: editedField, in: originalFields) ?? [:]
            for key in ["id", "key", "name", "valueType", "placeholder", "isRequired", "isSensitive", "helpText"] {
                if let value = editedField[key] {
                    mergedField[key] = value
                } else {
                    mergedField.removeValue(forKey: key)
                }
            }
            return mergedField
        }

        let mergedData = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
        guard let encoded = String(data: mergedData, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return encoded
    }

    private func originalSchemaFields(from schemaObject: [String: Any]) -> [[String: Any]] {
        schemaObject["fields"] as? [[String: Any]] ?? []
    }

    private func matchingOriginalField(
        for editedField: [String: Any],
        in originalFields: [[String: Any]]
    ) -> [String: Any]? {
        let editedID = editedField["id"] as? String
        let editedKey = (editedField["key"] as? String)?.normalizedFieldKey
        return originalFields.first { originalField in
            if let editedID, !editedID.isEmpty,
               let originalID = originalField["id"] as? String,
               editedID == originalID {
                return true
            }
            guard let editedKey, !editedKey.isEmpty,
                  let originalKey = (originalField["key"] as? String)?.normalizedFieldKey else {
                return false
            }
            return editedKey == originalKey
        }
    }

    func validationMessage(existingTemplateNames: [String]) -> String? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedName.isEmpty { return "Enter a template name." }
        if existingTemplateNames.contains(where: {
            $0.caseInsensitiveCompare(normalizedName) == .orderedSame
        }) {
            return "A template with this name already exists."
        }
        if targetCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Choose a category."
        }
        if fields.isEmpty { return "Add at least one field." }

        let keys = fields.map { $0.key.trimmingCharacters(in: .whitespacesAndNewlines).normalizedFieldKey }
        if keys.contains(where: \.isEmpty) { return "Every field needs a key." }
        if Set(keys).count != keys.count { return "Field keys must be unique." }
        if fields.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Every field needs a label."
        }
        if let titleKey = titleFieldKey.nilIfBlank?.normalizedFieldKey,
           !keys.contains(titleKey) {
            return "The title field must reference an existing field key."
        }
        return nil
    }
}

struct TemplateEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TemplateEditorDraft

    let collectionNames: [String]
    let existingTemplateNames: [String]
    let onSave: (TemplateEditorDraft) throws -> Void

    init(
        draft: TemplateEditorDraft,
        collectionNames: [String],
        existingTemplateNames: [String],
        onSave: @escaping (TemplateEditorDraft) throws -> Void
    ) {
        _draft = State(initialValue: draft)
        self.collectionNames = collectionNames
        self.existingTemplateNames = existingTemplateNames
        self.onSave = onSave
    }

    @State private var saveErrorMessage: String?

    private var validationMessage: String? {
        draft.validationMessage(existingTemplateNames: existingTemplateNames)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: draft.symbol.nilIfBlank ?? "rectangle.3.group")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.templateID == nil ? "New Template" : "Edit Template")
                        .font(.title2.weight(.semibold))
                    Text("Schema v\(PresetTemplateSchema.currentVersion) keeps field type and privacy metadata with each shard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section("Template") {
                    TextField("Name", text: $draft.name)
                        .disabled(draft.templateID != nil)
                        .help(draft.templateID == nil ? "Template name" : "Duplicate the template to use a different name")
                    TextField("SF Symbol", text: $draft.symbol)
                    Picker("Category", selection: $draft.targetCollectionName) {
                        ForEach(collectionNames, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Summary", text: $draft.summary)
                    Picker("Presentation", selection: $draft.presentationStyle) {
                        Text("Structured Table").tag(PresetTemplateSchema.PresentationStyle.table)
                        Text("Plain Text").tag(PresetTemplateSchema.PresentationStyle.plainText)
                        if case let .custom(value) = draft.presentationStyle {
                            Text("Custom (\(value))").tag(draft.presentationStyle)
                        }
                    }
                    Picker("Title Field", selection: $draft.titleFieldKey) {
                        Text("Automatic").tag("")
                        ForEach(draft.fields) { field in
                            Text(field.name.nilIfBlank ?? field.key).tag(field.key.normalizedFieldKey)
                        }
                    }
                    TextField("Display format (optional), e.g. {product}", text: $draft.displayFormat)
                }

                Section("Fields") {
                    ForEach($draft.fields) { $field in
                        TemplateFieldEditorRow(
                            field: $field,
                            canDelete: draft.fields.count > 1,
                            onDelete: { removeField(id: field.id) }
                        )
                    }

                    Button {
                        draft.fields.append(
                            TemplateFieldDraft(key: "field_\(draft.fields.count + 1)", name: "New Field")
                        )
                    } label: {
                        Label("Add Field", systemImage: "plus")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let saveErrorMessage {
                    Text(saveErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text("Sensitive and License Key fields stay hidden until you reveal them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Template") {
                    do {
                        saveErrorMessage = nil
                        try onSave(draft)
                        dismiss()
                    } catch {
                        saveErrorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil)
            }
            .padding(16)
        }
        .frame(width: 680, height: 680)
    }

    private func removeField(id: String) {
        guard draft.fields.count > 1 else { return }
        draft.fields.removeAll(where: { $0.id == id })
    }
}

private struct TemplateFieldEditorRow: View {
    @Binding var field: TemplateFieldDraft
    let canDelete: Bool
    let onDelete: () -> Void

    private var selectableTypes: [PresetFieldDefinition.ValueType] {
        let known = PresetFieldDefinition.ValueType.allCases
        return known.contains(field.valueType) ? known : known + [field.valueType]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                TextField("Label", text: $field.name)
                TextField("Stable key", text: $field.key)
                    .font(.system(.body, design: .monospaced))
                    .disabled(field.isExistingField)
                    .help(field.isExistingField ? "Stable keys cannot change after a template is saved" : "Used to keep existing shards compatible")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .disabled(!canDelete)
                .accessibilityLabel("Remove \(field.name) field")
            }

            HStack(spacing: 14) {
                Picker("Type", selection: Binding(
                    get: { field.valueType },
                    set: { newValue in
                        field.valueType = newValue
                        if newValue.isSensitiveByDefault { field.isSensitive = true }
                    }
                )) {
                    ForEach(selectableTypes, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .frame(maxWidth: 220)

                Toggle("Required", isOn: $field.isRequired)
                    .toggleStyle(.checkbox)
                Toggle("Sensitive", isOn: $field.isSensitive)
                    .toggleStyle(.checkbox)
                    .disabled(field.valueType.isSensitiveByDefault)
                Spacer()
            }

            HStack(spacing: 10) {
                TextField("Placeholder (optional)", text: $field.placeholder)
                TextField("Help text (optional)", text: $field.helpText)
            }
        }
        .padding(.vertical, 6)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
