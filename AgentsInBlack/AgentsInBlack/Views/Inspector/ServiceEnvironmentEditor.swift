import AIBCore
import SwiftUI

/// Edits a service's three env scopes (universal `env`, `local_env`, `deploy_env`)
/// with inline lint feedback. The universal section warns when a key/value matches
/// the same rule the deploy pipeline enforces, so users can fix it before they
/// hit the hard block on next deploy.
struct ServiceEnvironmentEditor: View {
    @Bindable var model: AgentsInBlackAppModel
    let service: AIBServiceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            Text("Environment Variables")
                .font(.headline)

            EnvScopeSection(
                title: "Universal",
                caption: "Applied in both local emulator and deploy.",
                scope: .universal,
                entries: service.env,
                showLintWarnings: true,
                onCommit: { newDict in
                    Task { await model.updateServiceEnv(namespacedServiceID: service.namespacedID, env: newDict) }
                }
            )
            .id("env-universal-\(service.id)")

            EnvScopeSection(
                title: "Local only",
                caption: "Merged on top of Universal when running the local emulator. Never sent to deploy.",
                scope: .local,
                entries: service.localEnv,
                showLintWarnings: false,
                onCommit: { newDict in
                    Task { await model.updateServiceLocalEnv(namespacedServiceID: service.namespacedID, localEnv: newDict) }
                }
            )
            .id("env-local-\(service.id)")

            EnvScopeSection(
                title: "Deploy only",
                caption: "Merged on top of Universal when deploying. Never used locally.",
                scope: .deploy,
                entries: service.deployEnv,
                showLintWarnings: false,
                onCommit: { newDict in
                    Task { await model.updateServiceDeployEnv(namespacedServiceID: service.namespacedID, deployEnv: newDict) }
                }
            )
            .id("env-deploy-\(service.id)")

            SecretsSection(
                entries: service.secrets,
                onCommit: { newDict in
                    Task { await model.updateServiceSecrets(namespacedServiceID: service.namespacedID, secrets: newDict) }
                }
            )
            .id("secrets-\(service.id)")
        }
    }
}

private enum EnvScope {
    case universal
    case local
    case deploy
}

private struct EnvScopeSection: View {
    let title: String
    let caption: String
    let scope: EnvScope
    let entries: [String: String]
    let showLintWarnings: Bool
    let onCommit: ([String: String]) -> Void

    @State private var draft: [EnvRow] = []
    @State private var lastSyncedSnapshot: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }

            ForEach($draft) { $row in
                EnvRowEditor(
                    row: $row,
                    showLintWarning: showLintWarnings,
                    onCommit: { commitDraft() },
                    onDelete: { delete(row.id) }
                )
            }

            Button {
                draft.append(EnvRow(key: "", value: ""))
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .onAppear { syncFromUpstream(force: true) }
        .onChange(of: entries) { _, _ in syncFromUpstream(force: false) }
    }

    private func syncFromUpstream(force: Bool) {
        // Only refresh draft from upstream when the upstream actually changed —
        // otherwise we'd clobber in-flight edits that haven't been committed yet.
        guard force || entries != lastSyncedSnapshot else { return }
        draft = entries
            .sorted { $0.key < $1.key }
            .map { EnvRow(key: $0.key, value: $0.value) }
        lastSyncedSnapshot = entries
    }

    private func delete(_ id: UUID) {
        draft.removeAll { $0.id == id }
        commitDraft()
    }

    private func commitDraft() {
        var dict: [String: String] = [:]
        for row in draft {
            let trimmedKey = row.key.trimmingCharacters(in: .whitespaces)
            guard !trimmedKey.isEmpty else { continue }
            dict[trimmedKey] = row.value
        }
        guard dict != lastSyncedSnapshot else { return }
        lastSyncedSnapshot = dict
        onCommit(dict)
    }
}

private struct EnvRow: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String
}

private struct EnvRowEditor: View {
    @Binding var row: EnvRow
    let showLintWarning: Bool
    let onCommit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("KEY", text: $row.key)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit(onCommit)
                Text("=")
                    .foregroundStyle(.tertiary)
                TextField("value", text: $row.value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onCommit)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
            if showLintWarning, let warning = lintWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Inline lint that mirrors the deploy-time hard block in EnvScopeRule.
    /// Kept in sync by hand because the editor lives in the app target which
    /// does not link AIBConfig directly.
    private var lintWarning: String? {
        let upperKey = row.key.uppercased()
        if upperKey.hasSuffix("_EMULATOR_HOST") || upperKey.hasSuffix("_EMULATOR") {
            return "Looks like a local emulator key — move to Local only."
        }
        let lowerValue = row.value.lowercased()
        let needles = [
            "host.container.internal",
            "host.docker.internal",
            "localhost:",
            "127.0.0.1:",
            "://localhost",
            "://127.0.0.1",
        ]
        for needle in needles where lowerValue.contains(needle) {
            return "Value points at a local-only host — move to Local only."
        }
        return nil
    }
}

// MARK: - Secrets

/// Edits a service's `secrets` map: env-key → backing Secret Manager binding.
/// Workspace YAML stores only the binding; values are resolved at deploy time
/// from the provider's secret store and locally from the chained resolver
/// (env passthrough / `.aib/secrets.local.yaml` / gcloud).
private struct SecretsSection: View {
    let entries: [String: AIBServiceSecretRef]
    let onCommit: ([String: AIBServiceSecretRef]) -> Void

    @State private var draft: [SecretRow] = []
    @State private var lastSyncedSnapshot: [String: AIBServiceSecretRef] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Secrets").font(.subheadline.weight(.semibold))
                Text("Bindings to Secret Manager. Values never live in workspace.yaml.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach($draft) { $row in
                SecretRowEditor(
                    row: $row,
                    onCommit: { commitDraft() },
                    onDelete: { delete(row.id) }
                )
            }

            Button {
                draft.append(SecretRow(envKey: "", secret: "", version: ""))
            } label: {
                Label("Add Secret", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .onAppear { syncFromUpstream(force: true) }
        .onChange(of: entries) { _, _ in syncFromUpstream(force: false) }
    }

    private func syncFromUpstream(force: Bool) {
        guard force || entries != lastSyncedSnapshot else { return }
        draft = entries
            .sorted { $0.key < $1.key }
            .map { SecretRow(envKey: $0.key, secret: $0.value.secret, version: $0.value.version ?? "") }
        lastSyncedSnapshot = entries
    }

    private func delete(_ id: UUID) {
        draft.removeAll { $0.id == id }
        commitDraft()
    }

    private func commitDraft() {
        var dict: [String: AIBServiceSecretRef] = [:]
        for row in draft {
            let trimmedKey = row.envKey.trimmingCharacters(in: .whitespaces)
            let trimmedSecret = row.secret.trimmingCharacters(in: .whitespaces)
            // Skip half-edited rows so we never persist an invalid entry.
            guard !trimmedKey.isEmpty, !trimmedSecret.isEmpty else { continue }
            let trimmedVersion = row.version.trimmingCharacters(in: .whitespaces)
            dict[trimmedKey] = AIBServiceSecretRef(
                secret: trimmedSecret,
                version: trimmedVersion.isEmpty ? nil : trimmedVersion
            )
        }
        guard dict != lastSyncedSnapshot else { return }
        lastSyncedSnapshot = dict
        onCommit(dict)
    }
}

private struct SecretRow: Identifiable, Equatable {
    let id = UUID()
    var envKey: String
    var secret: String
    var version: String
}

private struct SecretRowEditor: View {
    @Binding var row: SecretRow
    let onCommit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("ENV_KEY", text: $row.envKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .onSubmit(onCommit)
                Text("→")
                    .foregroundStyle(.tertiary)
                TextField("secret-name", text: $row.secret)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onCommit)
                TextField("ver (opt)", text: $row.version)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 80)
                    .onSubmit(onCommit)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
            if let warning = lintWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Mirrors SecretRefRule (S002/S003) so users see violations before save.
    private var lintWarning: String? {
        let trimmedKey = row.envKey.trimmingCharacters(in: .whitespaces)
        if !trimmedKey.isEmpty, !isValidEnvKey(trimmedKey) {
            return "ENV_KEY must match [A-Za-z_][A-Za-z0-9_]*."
        }
        let trimmedSecret = row.secret.trimmingCharacters(in: .whitespaces)
        if !trimmedSecret.isEmpty, !isValidSecretManagerName(trimmedSecret) {
            return "Secret name must match [A-Za-z0-9_-]{1,255}."
        }
        return nil
    }

    private func isValidEnvKey(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        guard first.isLetter || first == "_" else { return false }
        for ch in s.dropFirst() where !(ch.isLetter || ch.isNumber || ch == "_") {
            return false
        }
        return true
    }

    private func isValidSecretManagerName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 255 else { return false }
        for ch in s where !(ch.isLetter || ch.isNumber || ch == "_" || ch == "-") {
            return false
        }
        return true
    }
}
