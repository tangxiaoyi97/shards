import Foundation

struct SmartInputConfiguration: Sendable {
    enum RequestFormat: String, Sendable {
        case openai
        case anthropic
        case gemini
    }

    var endpointURL: String
    var apiToken: String
    var modelName: String
    var requestFormat: RequestFormat

    init(endpointURL: String, apiToken: String, modelName: String, requestFormatString: String) {
        self.endpointURL = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requestFormat = RequestFormat(rawValue: requestFormatString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .openai
    }

    var isComplete: Bool {
        !endpointURL.isEmpty && !apiToken.isEmpty && !modelName.isEmpty
    }
}

enum SmartInputError: LocalizedError {
    case missingConfiguration
    case invalidEndpoint
    case invalidResponse
    case emptyResponse
    case requestFailed(statusCode: Int, message: String?)
    case malformedModelOutput

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Smart Mode requires an endpoint, token, and model."
        case .invalidEndpoint:
            return "The Smart Mode endpoint URL is invalid."
        case .invalidResponse:
            return "The LLM provider returned an unsupported response."
        case .emptyResponse:
            return "The LLM provider returned an empty response."
        case let .requestFailed(statusCode, message):
            if let message, !message.isEmpty {
                return "The LLM provider rejected the request (\(statusCode)): \(message)"
            }
            return "The LLM provider rejected the request (\(statusCode))."
        case .malformedModelOutput:
            return "The LLM response could not be converted into a shard payload."
        }
    }

    var quickEntryStatusText: String {
        switch self {
        case .missingConfiguration:
            return "Fail: Configure Smart"
        case .invalidEndpoint:
            return "Fail: Invalid endpoint"
        case .invalidResponse, .emptyResponse, .malformedModelOutput:
            return "Fail: Bad LLM reply"
        case .requestFailed:
            return "Fail: Provider error"
        }
    }
}

actor SmartInputService {
    static let shared = SmartInputService()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func process(
        rawInput: String,
        templates: [SmartTemplateDescriptor],
        configuration: SmartInputConfiguration
    ) async throws -> SmartInputResult {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableTemplates = templates.sorted { $0.orderIndex < $1.orderIndex }

        guard !trimmed.isEmpty else {
            return SmartInputResult(templateName: nil, payload: .raw(""))
        }
        guard configuration.isComplete else {
            throw SmartInputError.missingConfiguration
        }
        guard !usableTemplates.isEmpty else {
            return SmartInputResult(templateName: nil, payload: .raw(trimmed))
        }

        let endpointURL = try Self.normalizedEndpointURL(from: configuration)
        let request = try Self.buildRequest(
            endpointURL: endpointURL,
            configuration: configuration,
            rawInput: trimmed,
            templates: usableTemplates
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SmartInputError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SmartInputError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: Self.extractProviderErrorMessage(from: data)
            )
        }

        let responseText = try Self.extractResponseText(from: data, format: configuration.requestFormat)
        return try Self.parseSmartInputResult(responseText, rawInput: trimmed, templates: usableTemplates)
    }

    nonisolated static func normalizedEndpointURL(from configuration: SmartInputConfiguration) throws -> URL {
        guard var components = URLComponents(string: configuration.endpointURL),
              components.scheme != nil,
              components.host != nil
        else {
            throw SmartInputError.invalidEndpoint
        }

        switch configuration.requestFormat {
        case .openai:
            components.path = normalizedPath(components.path, appending: "/chat/completions")
        case .anthropic:
            components.path = normalizedPath(components.path, appending: "/messages")
        case .gemini:
            let encodedModel = configuration.modelName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? configuration.modelName
            let suffix = "/models/\(encodedModel):generateContent"
            let basePath = trimmedTrailingSlash(for: components.path)
            if basePath.contains(":generateContent") {
                components.path = basePath
            } else if basePath.isEmpty {
                components.path = "/v1beta\(suffix)"
            } else {
                components.path = "\(basePath)\(suffix)"
            }
        }

        guard let url = components.url else {
            throw SmartInputError.invalidEndpoint
        }
        return url
    }

    nonisolated static func parseSmartInputResult(
        _ responseText: String,
        rawInput: String,
        templates: [SmartTemplateDescriptor]
    ) throws -> SmartInputResult {
        let jsonString = try extractJSONObjectString(from: responseText)
        let json = try jsonObject(from: Data(jsonString.utf8))
        guard let root = json as? [String: Any] else {
            throw SmartInputError.malformedModelOutput
        }

        let fallbackContent = firstString(
            in: root,
            keys: ["content", "fallback_content", "fallbackContent", "raw_text", "rawText", "text"]
        ) ?? rawInput

        let matchedTemplate = matchedTemplate(
            named: firstString(in: root, keys: ["template_name", "templateName", "template"]),
            templates: templates
        )

        guard let matchedTemplate else {
            return SmartInputResult(templateName: nil, payload: .raw(fallbackContent))
        }

        guard !matchedTemplate.schema.fields.isEmpty else {
            return SmartInputResult(templateName: matchedTemplate.name, payload: .raw(fallbackContent))
        }

        let mappedFields = mappedFields(from: root, template: matchedTemplate, fallbackContent: fallbackContent)
        return SmartInputResult(
            templateName: matchedTemplate.name,
            payload: PresetPayload(
                presetType: matchedTemplate.name,
                fields: mappedFields,
                preferredStyle: matchedTemplate.schema.presentationStyle.rawValue,
                templateID: matchedTemplate.templateID
            )
        )
    }

    private static func buildRequest(
        endpointURL: URL,
        configuration: SmartInputConfiguration,
        rawInput: String,
        templates: [SmartTemplateDescriptor]
    ) throws -> URLRequest {
        let systemPrompt = buildSystemPrompt(for: templates)
        let userPrompt = buildUserPrompt(for: rawInput)

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        switch configuration.requestFormat {
        case .openai:
            request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try jsonData(
                [
                    "model": configuration.modelName,
                    "temperature": 0.2,
                    "messages": [
                        ["role": "system", "content": systemPrompt],
                        ["role": "user", "content": userPrompt]
                    ]
                ]
            )
        case .anthropic:
            request.setValue(configuration.apiToken, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try jsonData(
                [
                    "model": configuration.modelName,
                    "temperature": 0.2,
                    "max_tokens": 1200,
                    "system": systemPrompt,
                    "messages": [
                        [
                            "role": "user",
                            "content": [
                                [
                                    "type": "text",
                                    "text": userPrompt
                                ]
                            ]
                        ]
                    ]
                ]
            )
        case .gemini:
            request.setValue(configuration.apiToken, forHTTPHeaderField: "x-goog-api-key")
            request.httpBody = try jsonData(
                [
                    "system_instruction": [
                        "parts": [
                            ["text": systemPrompt]
                        ]
                    ],
                    "contents": [
                        [
                            "role": "user",
                            "parts": [
                                ["text": userPrompt]
                            ]
                        ]
                    ],
                    "generationConfig": [
                        "temperature": 0.2,
                        "responseMimeType": "application/json"
                    ]
                ]
            )
        }

        return request
    }

    private static func buildSystemPrompt(for templates: [SmartTemplateDescriptor]) -> String {
        let templateDescriptions = templates
            .map { template in
                let fieldsDescription = template.schema.fields.map { field in
                    var details = ["name=\(field.name)", "key=\(field.key)", "type=\(field.valueType.rawValue)"]
                    if field.isRequired {
                        details.append("required=true")
                    }
                    if field.isSensitive {
                        details.append("sensitive=true")
                    }
                    if let helpText = field.helpText, !helpText.isEmpty {
                        details.append("help=\(helpText)")
                    }
                    return details.joined(separator: ", ")
                }
                .joined(separator: " | ")

                let useCases = template.schema.useCases.isEmpty ? "general" : template.schema.useCases.joined(separator: ", ")
                let fieldsLine = fieldsDescription.isEmpty ? "no explicit fields; preserve as content" : fieldsDescription
                return """
                Template: \(template.name)
                Category: \(template.categoryName)
                Summary: \(template.schema.summary)
                Presentation: \(template.schema.presentationStyle.rawValue)
                Use cases: \(useCases)
                Fields: \(fieldsLine)
                """
            }
            .joined(separator: "\n\n")

        return """
        You convert raw quick-capture text into a structured payload for the Shards app.
        Pick the single best matching template from the provided list when the fit is clear. Otherwise use null.
        Never invent passwords, tokens, emails, URLs, usernames, or other hidden values. Use empty strings for missing values.
        Preserve original wording for notes and text content.
        Respond with JSON only. Do not wrap the response in code fences.
        Use this schema:
        {
          "template_name": "Exact template name from the list, or null",
          "fields": {
            "field key or field name": "value"
          },
          "content": "fallback free-form content when useful"
        }

        Templates:
        \(templateDescriptions)
        """
    }

    private static func buildUserPrompt(for rawInput: String) -> String {
        """
        Raw input:
        \(rawInput)
        """
    }

    private static func mappedFields(
        from root: [String: Any],
        template: SmartTemplateDescriptor,
        fallbackContent: String
    ) -> [PresetField] {
        let rawFieldValues = fieldValueMap(from: root)
        let normalizedValues = Dictionary(uniqueKeysWithValues: rawFieldValues.map { (normalize($0.key), $0.value) })
        var fields = template.schema.fields.map(\.emptyValue)

        for index in fields.indices {
            let definition = template.schema.fields[index]
            let candidateKeys = [definition.key, definition.name].map(normalize)
            if let value = candidateKeys.compactMap({ normalizedValues[$0] }).first {
                fields[index].value = value
            }
        }

        if let noteFieldIndex = noteFieldIndex(in: template.schema.fields),
           fields[noteFieldIndex].trimmedValue.isEmpty {
            fields[noteFieldIndex].value = fallbackContent
        }

        if fields.allSatisfy({ $0.trimmedValue.isEmpty }),
           let firstIndex = fields.indices.first {
            fields[firstIndex].value = fallbackContent
        }

        return fields
    }

    private static func matchedTemplate(
        named candidateName: String?,
        templates: [SmartTemplateDescriptor]
    ) -> SmartTemplateDescriptor? {
        guard let candidateName = candidateName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidateName.isEmpty
        else {
            return nil
        }

        return templates.first(where: { $0.name.caseInsensitiveCompare(candidateName) == .orderedSame })
    }

    private static func fieldValueMap(from root: [String: Any]) -> [String: String] {
        for key in ["fields", "field_values", "fieldValues"] {
            if let dictionary = dictionaryValue(root[key]) {
                return dictionary
            }
            if let array = root[key] as? [Any] {
                let mapped = dictionaryFromFieldArray(array)
                if !mapped.isEmpty {
                    return mapped
                }
            }
        }

        if let payload = root["payload"] as? [String: Any] {
            for key in ["fields", "field_values", "fieldValues"] {
                if let dictionary = dictionaryValue(payload[key]) {
                    return dictionary
                }
                if let array = payload[key] as? [Any] {
                    let mapped = dictionaryFromFieldArray(array)
                    if !mapped.isEmpty {
                        return mapped
                    }
                }
            }
        }

        let reservedKeys = Set([
            "template_name", "templateName", "template",
            "content", "fallback_content", "fallbackContent", "raw_text", "rawText", "text",
            "payload"
        ])
        return root.reduce(into: [String: String]()) { partialResult, pair in
            guard !reservedKeys.contains(pair.key), let stringValue = stringValue(from: pair.value) else { return }
            partialResult[pair.key] = stringValue
        }
    }

    private static func dictionaryValue(_ value: Any?) -> [String: String]? {
        guard let dictionary = value as? [String: Any] else { return nil }
        var mapped: [String: String] = [:]
        for (key, value) in dictionary {
            mapped[key] = stringValue(from: value) ?? ""
        }
        return mapped
    }

    private static func dictionaryFromFieldArray(_ fields: [Any]) -> [String: String] {
        fields.reduce(into: [String: String]()) { partialResult, element in
            guard let field = element as? [String: Any],
                  let key = firstString(in: field, keys: ["name", "key", "field"]),
                  !key.isEmpty
            else {
                return
            }
            partialResult[key] = firstString(in: field, keys: ["value", "content", "text"]) ?? ""
        }
    }

    private static func noteFieldIndex(in fields: [PresetFieldDefinition]) -> Int? {
        fields.firstIndex {
            $0.valueType == .note || ["content", "body", "text", "note"].contains(normalize($0.key))
        }
    }

    private static func extractResponseText(from data: Data, format: SmartInputConfiguration.RequestFormat) throws -> String {
        let json = try jsonObject(from: data)
        guard let root = json as? [String: Any] else {
            throw SmartInputError.invalidResponse
        }

        let text: String?
        switch format {
        case .openai:
            if let choices = root["choices"] as? [Any],
               let firstChoice = choices.first as? [String: Any] {
                text = extractedText(from: firstChoice["message"]) ?? extractedText(from: firstChoice["delta"])
            } else {
                text = nil
            }
        case .anthropic:
            text = extractedText(from: root["content"])
        case .gemini:
            if let candidates = root["candidates"] as? [Any],
               let firstCandidate = candidates.first as? [String: Any] {
                text = extractedText(from: firstCandidate["content"])
            } else {
                text = nil
            }
        }

        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw SmartInputError.emptyResponse
        }
        return text
    }

    private static func extractProviderErrorMessage(from data: Data) -> String? {
        guard let json = try? jsonObject(from: data),
              let root = json as? [String: Any]
        else {
            return nil
        }

        if let error = root["error"] as? [String: Any] {
            return firstString(in: error, keys: ["message", "type", "code"])
        }

        return firstString(in: root, keys: ["message", "detail", "error"])
    }

    private static func extractedText(from value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let dictionary = value as? [String: Any] {
            for key in ["text", "content", "message", "parts"] {
                if let nested = extractedText(from: dictionary[key]), !nested.isEmpty {
                    return nested
                }
            }
            if let textDictionary = dictionary["text"] as? [String: Any],
               let value = textDictionary["value"] as? String {
                return value
            }
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { element -> String? in
                if let text = element as? String {
                    return text
                }
                if let dictionary = element as? [String: Any] {
                    if let text = dictionary["text"] as? String {
                        return text
                    }
                    if let textDictionary = dictionary["text"] as? [String: Any],
                       let value = textDictionary["value"] as? String {
                        return value
                    }
                    return extractedText(from: dictionary["parts"]) ?? extractedText(from: dictionary["content"])
                }
                return nil
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        return nil
    }

    private static func extractJSONObjectString(from text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutFences = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if withoutFences.first == "{", withoutFences.last == "}" {
            return withoutFences
        }

        var startIndex: String.Index?
        var depth = 0
        var isInsideString = false
        var isEscaping = false

        for index in withoutFences.indices {
            let character = withoutFences[index]

            if isEscaping {
                isEscaping = false
                continue
            }

            if character == "\\" {
                isEscaping = true
                continue
            }

            if character == "\"" {
                isInsideString.toggle()
                continue
            }

            if isInsideString {
                continue
            }

            if character == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let startIndex {
                    return String(withoutFences[startIndex...index])
                }
            }
        }

        throw SmartInputError.malformedModelOutput
    }

    private static func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private static func jsonObject(from data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let string = stringValue(from: dictionary[key]), !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private static func stringValue(from value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let boolean as Bool:
            return boolean ? "true" : "false"
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func normalizedPath(_ path: String, appending suffix: String) -> String {
        let trimmedPath = trimmedTrailingSlash(for: path)
        if trimmedPath.hasSuffix(suffix) {
            return trimmedPath
        }
        if trimmedPath.isEmpty {
            return suffix
        }
        return "\(trimmedPath)\(suffix)"
    }

    private static func trimmedTrailingSlash(for path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        if result == "/" {
            return ""
        }
        return result
    }
}
