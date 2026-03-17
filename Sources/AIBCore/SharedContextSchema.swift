import Foundation
import JSONSchema
import OrderedCollections

/// Defines the JSON Schema for the shared context that the Gateway propagates
/// between Client, Agent, and MCP services.
///
/// The Gateway strips these fields from requests to Agents (context-free)
/// and restores them when Agents call MCP servers through the Gateway.
public struct SharedContextSchema: Sendable, Equatable {
    /// The JSON Schema defining the shape of the shared context.
    public private(set) var schema: JSONSchema

    /// Property names extracted from the schema (top-level object properties).
    public var propertyNames: [String] {
        Array(objectProperties.keys)
    }

    /// Required property names.
    public var requiredNames: [String] {
        guard case .object(_, _, _, _, _, _, _, let required, _) = schema else {
            return []
        }
        return required
    }

    /// Properties as (name, schema) pairs for iteration.
    public var properties: [(name: String, schema: JSONSchema)] {
        objectProperties.map { (name: $0.key, schema: $0.value) }
    }

    /// Whether the schema has any properties defined.
    public var isEmpty: Bool {
        objectProperties.isEmpty
    }

    public init(schema: JSONSchema) {
        self.schema = schema
    }

    /// Empty context schema — no properties defined yet.
    /// Users configure the schema via workspace settings.
    public static let empty = SharedContextSchema(
        schema: .object(
            title: "Shared Context",
            description: "Client context propagated through the Gateway to MCP services. Invisible to Agents."
        )
    )

    // MARK: - Mutation

    /// Add a property to the context schema.
    public mutating func addProperty(name: String, type: ContextPropertyType, isRequired: Bool = false) {
        var props = objectProperties
        props[name] = type.jsonSchema
        var req = requiredNames
        if isRequired, !req.contains(name) {
            req.append(name)
        }
        schema = rebuiltSchema(properties: props, required: req)
    }

    /// Remove a property from the context schema.
    public mutating func removeProperty(name: String) {
        var props = objectProperties
        props.removeValue(forKey: name)
        var req = requiredNames
        req.removeAll { $0 == name }
        schema = rebuiltSchema(properties: props, required: req)
    }

    /// Toggle whether a property is required.
    public mutating func toggleRequired(name: String) {
        var req = requiredNames
        if req.contains(name) {
            req.removeAll { $0 == name }
        } else {
            req.append(name)
        }
        schema = rebuiltSchema(properties: objectProperties, required: req)
    }

    /// Encodes the schema to pretty-printed JSON.
    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(schema)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SharedContextSchemaError.encodingFailed
        }
        return string
    }

    // MARK: - Internal

    private var objectProperties: OrderedDictionary<String, JSONSchema> {
        guard case .object(_, _, _, _, _, _, let properties, _, _) = schema else {
            return [:]
        }
        return properties
    }

    private func rebuiltSchema(
        properties: OrderedDictionary<String, JSONSchema>,
        required: [String]
    ) -> JSONSchema {
        .object(
            title: "Shared Context",
            description: "Client context propagated through the Gateway to MCP services. Invisible to Agents.",
            properties: properties,
            required: required
        )
    }
}

/// Supported property types for context schema fields.
public enum ContextPropertyType: String, Sendable, CaseIterable, Identifiable {
    case string
    case integer
    case number
    case boolean

    public var id: String { rawValue }

    public var jsonSchema: JSONSchema {
        switch self {
        case .string: .string()
        case .integer: .integer()
        case .number: .number()
        case .boolean: .boolean()
        }
    }

    /// Infer the type from an existing JSONSchema value.
    public init(from schema: JSONSchema) {
        switch schema {
        case .string: self = .string
        case .integer: self = .integer
        case .number: self = .number
        case .boolean: self = .boolean
        default: self = .string
        }
    }
}

public enum SharedContextSchemaError: Error {
    case encodingFailed
}
