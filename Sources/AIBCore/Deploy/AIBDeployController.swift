import AIBRuntimeCore
import Foundation

/// Controls the deployment pipeline.
/// Provider-agnostic: delegates cloud-specific operations to DeploymentProvider.
/// Follows the same event-driven pattern as AIBEmulatorController.
///
/// Dependencies are injected via constructor (following the `DevSupervisor` pattern
/// from AIBSupervisor: `protocol + default + constructor injection`).
@MainActor
public final class AIBDeployController {
    /// Resolves a passphrase environment key (e.g. an entry from
    /// `local.yaml`'s `localPrivateKeyPassphraseEnv`) to the actual
    /// passphrase string. Returning `nil` means "no passphrase known for
    /// this key — try environment variables or fail."
    ///
    /// Sync + Sendable to match the shape `CloudSourceAuthBootstrapService`
    /// expects as `secretLookup`. The caller is responsible for routing the
    /// call to a thread-safe backing store (Keychain APIs are thread-safe,
    /// so a Sendable wrapper around `TargetSourceAuthKeychainStore`
    /// suffices).
    public typealias SourceAuthPassphraseResolver = @Sendable (String) throws -> String?

    private let planGenerator: DeployPlanGenerator
    private let executor: DeployExecuting
    private let secretValueResolver: SecretValueResolver
    private let sourceAuthPassphraseResolver: SourceAuthPassphraseResolver?
    private var eventContinuations: [UUID: AsyncStream<AIBDeployEvent>.Continuation] = [:]
    private var currentTask: Task<Void, Never>?
    private var approvalGate: ApprovalGate?
    private var secretsGate: SecretsGate?
    private var cachedPreflightReport: PreflightReport?
    private var cancellationRequested = false
    private var deployStartedAt: Date?

    public private(set) var phase: AIBDeployPhase = .idle

    /// Foundation `Progress` for the current deployment.
    /// Created at the start of the apply phase; nil otherwise.
    /// Observe this from SwiftUI via `ProgressView(progress)`.
    public private(set) var deployProgress: Progress?

    /// Secrets provided by the user during the secretsInput phase.
    /// Passed to the provider's deploy commands.
    public private(set) var providedSecrets: [String: String] = [:]

    public init(
        planGenerator: DeployPlanGenerator = DefaultDeployPlanGenerator(),
        executor: DeployExecuting = DefaultDeployExecutor(),
        secretValueResolver: SecretValueResolver = ChainedSecretValueResolver.default,
        sourceAuthPassphraseResolver: SourceAuthPassphraseResolver? = nil
    ) {
        self.planGenerator = planGenerator
        self.executor = executor
        self.secretValueResolver = secretValueResolver
        self.sourceAuthPassphraseResolver = sourceAuthPassphraseResolver
    }

    // MARK: - Event Stream

    public func events() -> AsyncStream<AIBDeployEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            self.eventContinuations[id] = continuation
            continuation.yield(.phaseChanged(self.phase))
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.eventContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    public func shutdown() {
        cancellationRequested = true
        deployStartedAt = nil
        currentTask?.cancel()
        currentTask = nil
        approvalGate?.deny()
        approvalGate = nil
        secretsGate?.cancel()
        secretsGate = nil
        finishEventStreams()
    }

    // MARK: - Pipeline Control

    /// Start the deploy pipeline: preflight -> plan -> wait for review.
    public func startPlan(
        workspaceRoot: String,
        targetConfig: AIBDeployTargetConfig,
        provider: any DeploymentProvider,
        selection: AIBDeploySelection? = nil,
        environmentName: String? = nil
    ) {
        guard case .idle = phase else { return }
        cancellationRequested = false
        deployStartedAt = Date()

        currentTask = Task { [weak self] in
            guard let self else { return }

            // Phase 1: Preflight
            self.transitionTo(.preflight)
            let report = await self.planGenerator.preflightCheck(provider: provider)
            self.cachedPreflightReport = report

            guard report.canProceed else {
                let failedNames = report.failedChecks.map(\.title).joined(separator: ", ")
                self.transitionTo(.failed(AIBDeployError(
                    phase: "preflight",
                    message: "Preflight failed: \(failedNames)"
                )))
                return
            }

            // Enrich target config with auto-detected values from preflight
            var enrichedConfig = targetConfig
            let detectedValues = provider.extractDetectedConfig(from: report)
            for (key, value) in detectedValues where enrichedConfig.providerConfig[key] == nil {
                enrichedConfig.providerConfig[key] = value
            }

            // Phase 2: Planning
            self.transitionTo(.planning)
            do {
                var effectiveEnvironmentName = environmentName
                if effectiveEnvironmentName == nil,
                   let inferredEnvironmentName = try AIBDeployService.inferEnvironmentName(
                       workspaceRoot: workspaceRoot,
                       targetConfig: enrichedConfig
                   )
                {
                    effectiveEnvironmentName = inferredEnvironmentName
                    enrichedConfig = try AIBDeployService.loadTargetConfig(
                        workspaceRoot: workspaceRoot,
                        providerID: provider.providerID,
                        environmentName: inferredEnvironmentName
                    )
                    for (key, value) in detectedValues where enrichedConfig.providerConfig[key] == nil {
                        enrichedConfig.providerConfig[key] = value
                    }
                }

                // Validate that all required provider config is present
                try provider.validateTargetConfig(enrichedConfig)

                let plan = try await self.planGenerator.generatePlan(
                    workspaceRoot: workspaceRoot,
                    targetConfig: enrichedConfig,
                    provider: provider,
                    selection: selection,
                    environmentName: effectiveEnvironmentName
                )

                // Phase 3: Review — block until user approves or cancels
                self.transitionTo(.reviewing(plan))

                let gate = ApprovalGate()
                self.approvalGate = gate
                let approved = await gate.wait()

                guard approved else {
                    self.transitionTo(.cancelled)
                    return
                }

                // Phase 3.5: Secrets Input — collect values for two distinct
                // buckets in a single user-facing step:
                //
                //   (a) unresolved env secrets: source-code-referenced env vars
                //       that are not yet pinned. Injected directly via
                //       `--set-env-vars`. Pre-populated from the live service
                //       so that an authoritative env-var replacement on deploy
                //       does not silently wipe values entered on a previous
                //       deploy.
                //
                //   (b) declared SecretRefs missing in Secret Manager:
                //       workspace.yaml `secrets:` bindings whose backing
                //       Secret Manager secret does not exist yet. Values
                //       entered here are uploaded via `provider.upsertSecret`
                //       *before* `applying` so the subsequent `--set-secrets`
                //       mount succeeds. Declared SecretRefs that already
                //       exist are NOT prompted for — they are mounted from
                //       Secret Manager as-is.
                var secretValues: [String: String] = [:]
                var aggregatedExistingEnv: [String: String] = [:]
                if plan.hasUnresolvedSecrets {
                    for service in plan.services where !service.unresolvedSecrets.isEmpty {
                        let existing = await provider.existingEnvVars(
                            serviceName: service.deployedServiceName,
                            targetConfig: enrichedConfig
                        )
                        for (key, value) in existing {
                            aggregatedExistingEnv[key] = value
                        }
                    }

                    // Reuse previously-deployed env values verbatim so
                    // `--set-env-vars` (which fully replaces, not merges)
                    // does not rotate live values. Rotation requires the
                    // user to re-enter the value in the secretsInput UI.
                    for name in plan.allUnresolvedSecrets {
                        if let existingValue = aggregatedExistingEnv[name], !existingValue.isEmpty {
                            secretValues[name] = existingValue
                            self.emit(.log(AIBDeployLogEntry(
                                timestamp: Date(),
                                level: .info,
                                message: "Reusing existing env value for '\(name)' from running service — value preserved"
                            )))
                        }
                    }
                }
                let unresolvedStillMissing = plan.allUnresolvedSecrets
                    .filter { secretValues[$0] == nil }

                // Compute which Secret Manager secrets are missing for this
                // deploy. Two buckets share a single `listSecrets()` call:
                //
                //   * declared SecretRefs (workspace.yaml `secrets:`)
                //   * source auth secrets (private SSH key + known_hosts
                //     referenced by `sourceCredential`)
                //
                // **Invariant**: only names in the "missing" sets ever
                // reach a resolver, `provisionFromLocalSSH`, or
                // `upsertSecret`. Secrets that already exist in Secret
                // Manager are deliberately left untouched — Cloud Run
                // mounts them as-is via `--set-secrets`, and Cloud Build
                // fetches them via `gcloud secrets versions access`.
                // Rotating an existing secret therefore requires an
                // explicit out-of-band action (e.g. `gcloud secrets
                // versions add`), never a side effect of running a deploy.
                let declaredSecretNames = Set(plan.allDeclaredSecretRefs.values.map(\.secret))
                var sourceAuthSecretNames: Set<String> = []
                for service in plan.services where !service.sourceDependencies.isEmpty {
                    if let name = service.sourceCredential?.cloudPrivateKeySecret, !name.isEmpty {
                        sourceAuthSecretNames.insert(name)
                    }
                    if let name = service.sourceCredential?.cloudKnownHostsSecret, !name.isEmpty {
                        sourceAuthSecretNames.insert(name)
                    }
                }
                let allRequiredSecretNames = declaredSecretNames.union(sourceAuthSecretNames)
                self.emit(.log(AIBDeployLogEntry(
                    timestamp: Date(),
                    level: .info,
                    message: "[secrets] Pre-check: declared=[\(declaredSecretNames.sorted().joined(separator: ", "))], "
                        + "sourceAuth=[\(sourceAuthSecretNames.sorted().joined(separator: ", "))]"
                )))

                var existingSecrets: Set<String> = []
                if !allRequiredSecretNames.isEmpty {
                    do {
                        existingSecrets = try await provider.listSecrets(targetConfig: enrichedConfig)
                        self.emit(.log(AIBDeployLogEntry(
                            timestamp: Date(),
                            level: .info,
                            message: "[secrets] Secret Manager currently has \(existingSecrets.count) secret(s). "
                                + "Required & present: [\(allRequiredSecretNames.intersection(existingSecrets).sorted().joined(separator: ", "))]; "
                                + "Required & missing: [\(allRequiredSecretNames.subtracting(existingSecrets).sorted().joined(separator: ", "))]"
                        )))
                    } catch {
                        // Surface the listing failure as a deploy failure —
                        // we cannot reason about which secrets need creation.
                        self.transitionTo(.failed(AIBDeployError(
                            phase: "secrets",
                            message: "Failed to list Secret Manager secrets: \(error.localizedDescription)"
                        )))
                        return
                    }
                }

                var missingDeclaredSecrets: [String] = declaredSecretNames
                    .subtracting(existingSecrets)
                    .sorted()
                let preservedDeclared = declaredSecretNames
                    .intersection(existingSecrets)
                    .sorted()
                for name in preservedDeclared {
                    self.emit(.log(AIBDeployLogEntry(
                        timestamp: Date(),
                        level: .info,
                        message: "Reusing existing Secret Manager secret '\(name)' — value preserved"
                    )))
                }

                // Auto-provision missing source auth secrets from the
                // user's local SSH key. Same UX principle as the codex
                // auth resolver: if the developer already has the material
                // locally, AIB should upload it instead of asking them to
                // do it by hand. If `localPrivateKeyPath` is unset or the
                // file is missing, fall through — the executor pre-check
                // will surface a clear "provision via AIB Inspector"
                // remediation message.
                let missingSourceAuth = sourceAuthSecretNames.subtracting(existingSecrets)
                if !missingSourceAuth.isEmpty {
                    let provisioningOutcome = await self.autoProvisionSourceAuthSecrets(
                        workspaceRoot: workspaceRoot,
                        plan: plan,
                        missingSecretNames: missingSourceAuth,
                        targetConfig: enrichedConfig
                    )
                    // Drop names that we just uploaded so the executor
                    // pre-check sees them as present without us having to
                    // re-`listSecrets`.
                    existingSecrets.formUnion(provisioningOutcome.uploadedNames)
                }

                // Try to auto-resolve missing secrets through the resolver
                // chain (codex auth file -> random hex generator). Anything
                // the chain can fill in is held aside in
                // `autoResolvedDeclared` and uploaded later; anything it
                // cannot fill stays in `missingDeclaredSecrets` for user
                // input. This keeps the secretsInput UI focused on what
                // genuinely needs human attention.
                var autoResolvedDeclared: [String: String] = [:]
                var unresolvedDeclaredForUser: [String] = []
                for name in missingDeclaredSecrets {
                    if let resolved = await self.secretValueResolver.resolveValue(
                        secretName: name,
                        plan: plan
                    ) {
                        autoResolvedDeclared[name] = resolved.value
                        self.emit(.log(AIBDeployLogEntry(
                            timestamp: Date(),
                            level: .info,
                            message: "Auto-resolved secret '\(name)' from \(resolved.sourceDescription)"
                        )))
                    } else {
                        unresolvedDeclaredForUser.append(name)
                    }
                }
                missingDeclaredSecrets = unresolvedDeclaredForUser

                var declaredValuesForUpload: [String: String] = autoResolvedDeclared

                if !unresolvedStillMissing.isEmpty || !missingDeclaredSecrets.isEmpty {
                    self.transitionTo(.secretsInput(
                        plan,
                        unresolvedSecrets: unresolvedStillMissing,
                        missingDeclaredSecrets: missingDeclaredSecrets
                    ))

                    let sGate = SecretsGate()
                    self.secretsGate = sGate
                    let result = await sGate.wait()

                    guard let userInput = result else {
                        self.transitionTo(.cancelled)
                        return
                    }

                    // Merge user-provided env values on top of remote values.
                    // User input takes precedence so a user can rotate a
                    // secret by re-entering it.
                    for (key, value) in userInput.unresolvedEnv {
                        secretValues[key] = value
                    }

                    // User-provided declared values take precedence over
                    // auto-resolved ones — same rotation principle.
                    for (key, value) in userInput.declared {
                        declaredValuesForUpload[key] = value
                    }
                }

                // Upload declared SecretRef values (auto-resolved + user-
                // provided) to Secret Manager so the subsequent
                // `--set-secrets` mount can resolve them. Sequential —
                // uploads are idempotent and small; ordering makes the log
                // easier to follow if one fails.
                let declaredNamesToUpload = autoResolvedDeclared.keys.sorted()
                    + missingDeclaredSecrets
                for name in declaredNamesToUpload {
                    guard let value = declaredValuesForUpload[name], !value.isEmpty else {
                        self.transitionTo(.failed(AIBDeployError(
                            phase: "secrets",
                            message: "Missing value for declared SecretRef '\(name)'"
                        )))
                        return
                    }
                    do {
                        try await provider.upsertSecret(
                            name: name,
                            value: value,
                            targetConfig: enrichedConfig
                        )
                    } catch let error as AIBDeployError {
                        self.transitionTo(.failed(error))
                        return
                    } catch {
                        self.transitionTo(.failed(AIBDeployError(
                            phase: "secrets",
                            message: "Failed to upload secret '\(name)': \(error.localizedDescription)"
                        )))
                        return
                    }
                }
                self.providedSecrets = secretValues

                // Phase 4: Apply
                let progress = Progress(totalUnitCount: Int64(plan.services.count))
                self.deployProgress = progress
                self.transitionTo(.applying(plan))

                try self.planGenerator.writeArtifacts(plan: plan, workspaceRoot: workspaceRoot)

                let result = try await self.executor.execute(
                    plan: plan,
                    provider: provider,
                    workspaceRoot: workspaceRoot,
                    overallProgress: progress,
                    secrets: secretValues,
                    logHandler: { [weak self] logEntry in
                        Task { @MainActor in
                            guard let self else { return }
                            var enriched = logEntry
                            if let startedAt = self.deployStartedAt {
                                let elapsed = logEntry.timestamp.timeIntervalSince(startedAt)
                                enriched.elapsedSeconds = max(0, elapsed)
                            }
                            self.emit(.log(enriched))
                        }
                    }
                )

                if Task.isCancelled || self.cancellationRequested {
                    self.transitionTo(.cancelled)
                    return
                }
                self.transitionTo(.completed(result))
            } catch is CancellationError {
                self.transitionTo(.cancelled)
            } catch {
                if Task.isCancelled || self.cancellationRequested {
                    self.transitionTo(.cancelled)
                    return
                }
                self.transitionTo(.failed(AIBDeployError(
                    phase: "deploy",
                    message: error.localizedDescription
                )))
            }
        }
    }

    /// Approve the current plan and proceed to deployment.
    public func approve(plan: AIBDeployPlan) {
        approvalGate?.approve()
    }

    /// Provide secrets and proceed to deployment.
    ///
    /// `unresolvedEnv` values are injected at deploy time via `--set-env-vars`.
    /// `declared` values are uploaded to Secret Manager via `upsertSecret`
    /// before the apply phase begins.
    public func provideSecrets(
        unresolvedEnv: [String: String],
        declared: [String: String]
    ) {
        secretsGate?.provide(result: SecretsGateResult(
            unresolvedEnv: unresolvedEnv,
            declared: declared
        ))
    }

    /// Cancel the current deployment pipeline.
    ///
    /// Asynchronous because the running pipeline `Task` owns all phase
    /// transitions to `.cancelled` (it observes the gate denial / cancellation
    /// in its own body). We await its completion here so that a follow-up
    /// `reset()` / restart is guaranteed to happen *after* the running task
    /// has emitted its final `.cancelled` event — otherwise the delayed
    /// emission would overwrite the freshly-reset `.idle` state and the UI
    /// would get stuck on "Deployment cancelled" after a context switch.
    ///
    /// Only when no pipeline task is running (e.g. cancel called from
    /// `.idle`) does this method itself perform the terminal transition.
    public func cancel() async {
        cancellationRequested = true
        deployStartedAt = nil
        approvalGate?.deny()
        approvalGate = nil
        secretsGate?.cancel()
        secretsGate = nil

        let runningTask = currentTask
        currentTask = nil
        runningTask?.cancel()

        // Wait for the pipeline task to fully exit so its terminal
        // `transitionTo(.cancelled)` (or `.failed` / `.completed`) has already
        // been emitted before this call returns.
        await runningTask?.value

        // If there was no running task to transition the phase, do it here.
        if !phase.isTerminal {
            transitionTo(.cancelled)
        }
    }

    /// Reset to idle state after completion, failure, or cancellation.
    ///
    /// **Precondition**: any in-flight pipeline `Task` must already be done.
    /// Callers that may still have a running task must `await cancel()` before
    /// calling this method, otherwise the running task can emit a stale
    /// `.cancelled` event after `phase` has been set back to `.idle`.
    public func reset() {
        cancellationRequested = false
        deployStartedAt = nil
        currentTask?.cancel()
        currentTask = nil
        approvalGate?.deny()
        approvalGate = nil
        secretsGate?.cancel()
        secretsGate = nil
        deployProgress = nil
        providedSecrets = [:]
        phase = .idle
        emit(.phaseChanged(.idle))
    }

    /// Returns the cached preflight report, if available.
    public var latestPreflightReport: PreflightReport? {
        cachedPreflightReport
    }

    /// Invalidate cached preflight report (e.g., on workspace reload).
    public func invalidatePreflightCache() {
        cachedPreflightReport = nil
    }

    // MARK: - Private

    private func transitionTo(_ newPhase: AIBDeployPhase) {
        phase = newPhase
        emit(.phaseChanged(newPhase))
    }

    private func emit(_ event: AIBDeployEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func finishEventStreams() {
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }

    // MARK: - Source Auth Auto-Provisioning

    private struct SourceAuthProvisioningOutcome {
        var uploadedNames: Set<String>
    }

    /// Auto-provision missing cloud source auth secrets from the user's
    /// local SSH key, using the same `CloudSourceAuthBootstrapService` that
    /// the AIB Inspector's "Provision from local SSH" button drives.
    ///
    /// The bootstrap service is the right entry point here (not the lower-
    /// level `CloudSourceCredentialProvisioningService`) because the local
    /// SSH key path lives in `.aib/targets/local.yaml`, NOT in the cloud
    /// target config: a fresh deploy's `gcp-cloudrun.yaml` entry typically
    /// has only `cloudPrivateKeySecret` populated, with `localPrivateKeyPath`
    /// nil. The bootstrap loads `local.yaml`, matches by host, and writes
    /// the merged credential back to `gcp-cloudrun.yaml`.
    ///
    /// Behaviour is best-effort and silent on partial failure: anything that
    /// cannot be auto-provisioned (no matching local credential, key file
    /// missing, host has no `gcpProject` in target config, provisioning
    /// throws) is left for the executor's pre-check to surface with the
    /// existing remediation guidance ("Provision them via the AIB
    /// Inspector ..."). The goal here is to remove friction in the common
    /// case where the developer already has a working local SSH key, not
    /// to replace the explicit Inspector flow.
    private func autoProvisionSourceAuthSecrets(
        workspaceRoot: String,
        plan: AIBDeployPlan,
        missingSecretNames: Set<String>,
        targetConfig: AIBDeployTargetConfig
    ) async -> SourceAuthProvisioningOutcome {
        self.emit(.log(AIBDeployLogEntry(
            timestamp: Date(),
            level: .info,
            message: "[source-auth] Auto-provisioning entered. workspaceRoot=\(workspaceRoot) "
                + "missingSecrets=[\(missingSecretNames.sorted().joined(separator: ", "))]"
        )))

        guard let gcpProject = targetConfig.providerConfig["gcpProject"],
              !gcpProject.isEmpty
        else {
            self.emit(.log(AIBDeployLogEntry(
                timestamp: Date(),
                level: .warning,
                message: "[source-auth] Skipping auto-provision: targetConfig.providerConfig[\"gcpProject\"] is missing or empty."
            )))
            return SourceAuthProvisioningOutcome(uploadedNames: [])
        }
        self.emit(.log(AIBDeployLogEntry(
            timestamp: Date(),
            level: .info,
            message: "[source-auth] Using GCP project '\(gcpProject)' for auto-provisioning."
        )))

        // Dedup credentials by host — multiple services often share the
        // same SSH credential, and we only want to upload once per host.
        var credentialsByHost: [String: AIBSourceCredential] = [:]
        var servicesWithDependencies = 0
        var servicesWithoutCredential = 0
        for service in plan.services {
            if !service.sourceDependencies.isEmpty {
                servicesWithDependencies += 1
            }
            guard let credential = service.sourceCredential else {
                if !service.sourceDependencies.isEmpty {
                    servicesWithoutCredential += 1
                    self.emit(.log(AIBDeployLogEntry(
                        timestamp: Date(),
                        level: .warning,
                        message: "[source-auth] Service '\(service.id)' has \(service.sourceDependencies.count) "
                            + "source dependencies but no sourceCredential resolved in plan."
                    )))
                }
                continue
            }
            credentialsByHost[credential.host] = credential
        }
        self.emit(.log(AIBDeployLogEntry(
            timestamp: Date(),
            level: .info,
            message: "[source-auth] Plan summary: \(plan.services.count) service(s), "
                + "\(servicesWithDependencies) with source deps, "
                + "\(servicesWithoutCredential) missing credential, "
                + "\(credentialsByHost.count) unique host(s): "
                + "[\(credentialsByHost.keys.sorted().joined(separator: ", "))]"
        )))

        if credentialsByHost.isEmpty {
            self.emit(.log(AIBDeployLogEntry(
                timestamp: Date(),
                level: .warning,
                message: "[source-auth] No host credentials to provision — bailing out without upload."
            )))
            return SourceAuthProvisioningOutcome(uploadedNames: [])
        }

        let bootstrap = CloudSourceAuthBootstrapService()
        var uploaded: Set<String> = []

        for (host, credential) in credentialsByHost.sorted(by: { $0.key < $1.key }) {
            let privateKeySecretName = credential.cloudPrivateKeySecret ?? ""
            guard !privateKeySecretName.isEmpty else {
                self.emit(.log(AIBDeployLogEntry(
                    timestamp: Date(),
                    level: .warning,
                    message: "[source-auth] Skipping host '\(host)': cloudPrivateKeySecret is unset on credential."
                )))
                continue
            }

            // Skip credentials whose private-key secret already exists —
            // we only want to upload what is missing.
            guard missingSecretNames.contains(privateKeySecretName) else {
                self.emit(.log(AIBDeployLogEntry(
                    timestamp: Date(),
                    level: .info,
                    message: "[source-auth] Skipping host '\(host)': secret '\(privateKeySecretName)' "
                        + "is not in the missing set (probably already exists in Secret Manager)."
                )))
                continue
            }

            self.emit(.log(AIBDeployLogEntry(
                timestamp: Date(),
                level: .info,
                message: "[source-auth] Provisioning host '\(host)' → "
                    + "privateKey='\(privateKeySecretName)', "
                    + "knownHosts='\(credential.cloudKnownHostsSecret ?? "<nil>")' "
                    + "in project '\(gcpProject)' from local.yaml entry"
            )))

            do {
                // Bridge to the injected passphrase resolver (typically a
                // Keychain wrapper from the macOS app). Without this, a
                // passphrase-protected local SSH key causes the bootstrap
                // to fail with "configure localPrivateKeyPassphraseEnv".
                let resolver = self.sourceAuthPassphraseResolver
                let secretLookup: @Sendable (String) throws -> String? = { key in
                    try resolver?(key)
                }
                let result = try await bootstrap.provisionGCPCloudRunSourceAuth(
                    workspaceRoot: workspaceRoot,
                    projectID: gcpProject,
                    host: credential.host,
                    preferredPrivateKeySecretName: privateKeySecretName,
                    preferredKnownHostsSecretName: credential.cloudKnownHostsSecret,
                    secretLookup: secretLookup
                )
                self.emit(.log(AIBDeployLogEntry(
                    timestamp: Date(),
                    level: .info,
                    message: "[source-auth] Bootstrap completed for host '\(host)': "
                        + "privateKey='\(result.privateKeySecretName)' "
                        + "createdPrivateKey=\(result.createdPrivateKeySecret), "
                        + "knownHosts='\(result.knownHostsSecretName ?? "<nil>")' "
                        + "createdKnownHosts=\(result.createdKnownHostsSecret)"
                )))
                // Mark the private-key secret as uploaded whether the bootstrap
                // *created* a new secret (first deploy) or only *added a new
                // version* (subsequent re-provision after manual deletion).
                // Either way, the executor's pre-check will now find it.
                uploaded.insert(result.privateKeySecretName)
                if let knownHostsName = result.knownHostsSecretName,
                   !knownHostsName.isEmpty
                {
                    uploaded.insert(knownHostsName)
                }
            } catch {
                self.emit(.log(AIBDeployLogEntry(
                    timestamp: Date(),
                    level: .error,
                    message: "[source-auth] Bootstrap FAILED for host '\(host)' "
                        + "(secret '\(privateKeySecretName)'): \(error.localizedDescription). "
                        + "Falling back to manual provisioning via AIB Inspector."
                )))
            }
        }

        self.emit(.log(AIBDeployLogEntry(
            timestamp: Date(),
            level: .info,
            message: "[source-auth] Auto-provisioning finished. uploaded="
                + "[\(uploaded.sorted().joined(separator: ", "))]"
        )))
        return SourceAuthProvisioningOutcome(uploadedNames: uploaded)
    }
}

private extension AIBDeployPhase {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }
}
