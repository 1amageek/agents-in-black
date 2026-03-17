import AIBCore
import JSONSchema
import SwiftUI

/// Floating overlay displayed in the top-right of the Canvas.
/// Shows and edits the shared context JSON Schema that the Gateway propagates.
struct ContextSchemaOverlay: View {
    @Binding var contextSchema: SharedContextSchema
    @State private var isExpanded: Bool = false
    @State private var isAddingKey: Bool = false
    @State private var newKeyName: String = ""
    @State private var newKeyType: ContextPropertyType = .string
    @FocusState private var isKeyFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerButton
            if isExpanded {
                schemaContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .frame(maxWidth: 280)
    }

    // MARK: - Header

    private var headerButton: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "shared.with.you")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Shared Context")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    if !contextSchema.isEmpty {
                        Text("\(contextSchema.properties.count)")
                            .font(.system(.caption2, design: .monospaced, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isAddingKey = true
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: - Schema Content

    private var schemaContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            if contextSchema.isEmpty && !isAddingKey {
                emptyState
            } else {
                propertyList
            }
        }
    }

    private var emptyState: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isAddingKey = true
            }
        } label: {
            Text("Add context property...")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var propertyList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(contextSchema.properties, id: \.name) { property in
                propertyRow(
                    name: property.name,
                    schema: property.schema,
                    isRequired: contextSchema.requiredNames.contains(property.name)
                )
            }
            if isAddingKey {
                addKeyRow
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Property Row

    private func propertyRow(name: String, schema: JSONSchema, isRequired: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                contextSchema.toggleRequired(name: name)
            } label: {
                Circle()
                    .fill(isRequired ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
                    .contentShape(Circle().inset(by: -4))
            }
            .buttonStyle(.plain)
            .help(isRequired ? "Required — click to make optional" : "Optional — click to make required")

            Text(name)
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(typeLabel(for: schema))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    contextSchema.removeProperty(name: name)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Add Key Row

    private var addKeyRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 6, height: 6)

            TextField("key", text: $newKeyName)
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .textFieldStyle(.plain)
                .frame(minWidth: 60)
                .focused($isKeyFieldFocused)
                .onSubmit { commitNewKey() }
                .onChange(of: isKeyFieldFocused) { _, focused in
                    if !focused { commitOrCancel() }
                }
                .onAppear { isKeyFieldFocused = true }

            Spacer(minLength: 0)

            Picker("", selection: $newKeyType) {
                ForEach(ContextPropertyType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.system(.caption2, design: .monospaced))

            Button {
                cancelNewKey()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func commitNewKey() {
        let trimmed = newKeyName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard !contextSchema.propertyNames.contains(trimmed) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            contextSchema.addProperty(name: trimmed, type: newKeyType)
            newKeyName = ""
            newKeyType = .string
            isAddingKey = false
        }
    }

    private func commitOrCancel() {
        let trimmed = newKeyName.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            cancelNewKey()
        } else {
            commitNewKey()
        }
    }

    private func cancelNewKey() {
        withAnimation(.easeInOut(duration: 0.15)) {
            newKeyName = ""
            newKeyType = .string
            isAddingKey = false
        }
    }

    // MARK: - Helpers

    private func typeLabel(for schema: JSONSchema) -> String {
        switch schema {
        case .string: "string"
        case .integer: "integer"
        case .number: "number"
        case .boolean: "boolean"
        case .array: "array"
        case .object: "object"
        default: "any"
        }
    }
}
