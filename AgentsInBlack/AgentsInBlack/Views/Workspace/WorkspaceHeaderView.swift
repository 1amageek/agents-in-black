import AIBCore
import SwiftUI

struct WorkspaceHeaderView: View {
    @Bindable var model: AgentsInBlackAppModel

    var body: some View {
        HStack(spacing: 10) {
            if let subjectIcon {
                Image(systemName: subjectIcon)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let meta = headerMetaText {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            HStack(spacing: 6) {
                if model.lastErrorMessage != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(headerSubtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.lastErrorMessage == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .help(headerHelpText)
    }

    private var headerTitle: String {
        if let service = model.selectedService() {
            return service.namespacedID
        }
        if let repo = model.selectedRepo() {
            return repo.name
        }
        if let fileURL = model.selectedFileURL() {
            return fileURL.lastPathComponent
        }
        return model.workspace?.displayName ?? "No Workspace"
    }

    private var headerMetaText: String? {
        if let service = model.selectedService() {
            return serviceKindLabel(for: service)
        }
        if let repo = model.selectedRepo() {
            return "\(repo.runtime)/\(repo.framework)"
        }
        if model.workspace != nil {
            return nil
        }
        return "Open a workspace to begin"
    }

    private var subjectIcon: String? {
        if let service = model.selectedService() {
            switch service.serviceKind {
            case .agent:
                return "sparkles"
            case .mcp:
                return "wrench.and.screwdriver"
            case .unknown:
                return "square.stack.3d.up"
            }
        }
        if let repo = model.selectedRepo() {
            switch repo.runtime {
            case "swift": return "swift"
            case "node": return "server.rack"
            case "python": return "terminal"
            case "deno": return "network"
            default: return "folder"
            }
        }
        return nil
    }

    private var headerSubtitle: String {
        guard model.workspace != nil else { return "Open Workspace" }
        if model.lastErrorMessage != nil {
            return "Error"
        }
        return model.emulatorState.label
    }

    private var headerHelpText: String {
        var lines: [String] = []
        if let path = model.workspace?.rootURL.path {
            lines.append(path)
        } else {
            lines.append("No workspace selected")
        }
        if let error = model.lastErrorMessage {
            lines.append("")
            lines.append("Error:")
            lines.append(error)
        }
        return lines.joined(separator: "\n")
    }

    private func serviceKindLabel(for service: AIBServiceModel) -> String {
        switch service.serviceKind {
        case .agent:
            return "Agent"
        case .mcp:
            return "MCP"
        case .unknown:
            return service.mountPath
        }
    }
}
