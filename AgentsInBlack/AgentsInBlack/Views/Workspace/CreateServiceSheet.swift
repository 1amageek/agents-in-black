import AIBWorkspace
import SwiftUI

struct CreateServiceSheet: View {
    @Bindable var model: AgentsInBlackAppModel
    @State private var selectedRuntime: RuntimeKind?
    @State private var selectedTemplate: (any ProjectTemplate)?
    @State private var serviceName: String = ""
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .padding(20)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            if selectedRuntime != nil {
                Button {
                    if selectedTemplate != nil {
                        selectedTemplate = nil
                    } else {
                        selectedRuntime = nil
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
            }

            Label(headerTitle, systemImage: "plus.rectangle.on.folder")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var headerTitle: String {
        if let template = selectedTemplate {
            return "New \(template.displayName) Service"
        } else if let runtime = selectedRuntime {
            return "Choose \(runtime.displayLabel) Framework"
        }
        return "Create New Service"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if selectedTemplate != nil {
            nameInputStep
        } else if let runtime = selectedRuntime {
            frameworkStep(for: runtime)
        } else {
            runtimeStep
        }
    }

    // MARK: - Step 1: Runtime

    private var runtimeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select a runtime")
                .font(.subheadline.weight(.medium))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(ProjectTemplateRegistry.supportedRuntimes, id: \.rawValue) { runtime in
                    runtimeButton(runtime)
                }
            }

            footerButtons(canProceed: false)
        }
    }

    private func runtimeButton(_ runtime: RuntimeKind) -> some View {
        Button {
            selectedRuntime = runtime
        } label: {
            HStack(spacing: 10) {
                Image(systemName: runtime.sfSymbol)
                    .font(.title2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(runtime.displayLabel)
                        .font(.body.weight(.medium))
                    Text(runtime.tagline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 2: Framework

    private func frameworkStep(for runtime: RuntimeKind) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select a framework")
                .font(.subheadline.weight(.medium))

            let templates = ProjectTemplateRegistry.templates(for: runtime)
            ForEach(templates, id: \.framework) { template in
                Button {
                    selectedTemplate = template
                    isNameFieldFocused = true
                } label: {
                    HStack {
                        Text(template.displayName)
                            .font(.body.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            footerButtons(canProceed: false)
        }
    }

    // MARK: - Step 3: Name

    private var nameInputStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Service Name")
                    .font(.subheadline.weight(.medium))
                TextField("my-service", text: $serviceName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFieldFocused)
                    .disabled(isCreating)
                    .onSubmit {
                        if canCreate { create() }
                    }
                Text("Lowercase letters, numbers, and hyphens only. Used as the directory name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let validationError = nameValidationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if isCreating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Creating...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            footerButtons(canProceed: canCreate, proceedLabel: "Create", onProceed: create)
        }
    }

    // MARK: - Footer

    private func footerButtons(
        canProceed: Bool,
        proceedLabel: String = "Next",
        onProceed: (() -> Void)? = nil
    ) -> some View {
        HStack {
            Spacer()
            Button("Cancel") {
                model.showCreateServiceSheet = false
            }
            .keyboardShortcut(.cancelAction)

            if let action = onProceed {
                Button(proceedLabel) {
                    action()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canProceed)
            }
        }
    }

    // MARK: - Validation

    private var sanitizedName: String {
        serviceName
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private var nameValidationError: String? {
        guard !serviceName.isEmpty else { return nil }
        if sanitizedName != serviceName {
            return "Name will be sanitized to: \(sanitizedName)"
        }
        if sanitizedName.isEmpty {
            return "Name must contain at least one letter or number."
        }
        return nil
    }

    private var canCreate: Bool {
        !sanitizedName.isEmpty && !isCreating && selectedTemplate != nil
    }

    // MARK: - Create

    private func create() {
        guard let template = selectedTemplate, canCreate else { return }
        let name = sanitizedName
        isCreating = true
        errorMessage = nil

        Task {
            do {
                try await model.createNewService(template: template, serviceName: name)
                model.showCreateServiceSheet = false
            } catch {
                errorMessage = error.localizedDescription
            }
            isCreating = false
        }
    }
}

// MARK: - RuntimeKind Display Helpers

extension RuntimeKind {
    var displayLabel: String {
        switch self {
        case .swift: "Swift"
        case .node: "Node.js"
        case .python: "Python"
        case .deno: "Deno"
        case .unknown: "Unknown"
        }
    }

    var sfSymbol: String {
        switch self {
        case .swift: "swift"
        case .node: "shippingbox"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .deno: "fossil.shell"
        case .unknown: "questionmark.circle"
        }
    }

    var tagline: String {
        switch self {
        case .swift: "Vapor, Hummingbird"
        case .node: "Express, Hono, Fastify"
        case .python: "FastAPI, Flask"
        case .deno: "Hono, Oak, Fresh"
        case .unknown: ""
        }
    }
}
