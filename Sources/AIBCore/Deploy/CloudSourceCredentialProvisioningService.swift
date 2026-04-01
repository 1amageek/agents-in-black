import AIBRuntimeCore
import Foundation

public struct CloudSourceCredentialProvisioningService: Sendable {
    public struct Request: Sendable {
        public var projectID: String
        public var host: String
        public var localPrivateKeyPath: String
        public var localKnownHostsPath: String?
        public var localPrivateKeyPassphrase: String?
        public var privateKeySecretName: String
        public var knownHostsSecretName: String?

        public init(
            projectID: String,
            host: String,
            localPrivateKeyPath: String,
            localKnownHostsPath: String? = nil,
            localPrivateKeyPassphrase: String? = nil,
            privateKeySecretName: String,
            knownHostsSecretName: String? = nil
        ) {
            self.projectID = projectID
            self.host = host
            self.localPrivateKeyPath = localPrivateKeyPath
            self.localKnownHostsPath = localKnownHostsPath
            self.localPrivateKeyPassphrase = localPrivateKeyPassphrase
            self.privateKeySecretName = privateKeySecretName
            self.knownHostsSecretName = knownHostsSecretName
        }
    }

    public struct Result: Sendable {
        public var privateKeySecretName: String
        public var knownHostsSecretName: String?
        public var createdPrivateKeySecret: Bool
        public var createdKnownHostsSecret: Bool

        public init(
            privateKeySecretName: String,
            knownHostsSecretName: String?,
            createdPrivateKeySecret: Bool,
            createdKnownHostsSecret: Bool
        ) {
            self.privateKeySecretName = privateKeySecretName
            self.knownHostsSecretName = knownHostsSecretName
            self.createdPrivateKeySecret = createdPrivateKeySecret
            self.createdKnownHostsSecret = createdKnownHostsSecret
        }
    }

    private let processRunner: any ProcessRunner

    public init(processRunner: any ProcessRunner = DefaultProcessRunner()) {
        self.processRunner = processRunner
    }

    public static func suggestedPrivateKeySecretName(workspaceRoot: String, host: String) -> String {
        AIBSourceCredentialNaming.suggestedPrivateKeySecretName(
            workspaceRoot: workspaceRoot,
            host: host
        )
    }

    public static func suggestedKnownHostsSecretName(workspaceRoot: String, host: String) -> String {
        AIBSourceCredentialNaming.suggestedKnownHostsSecretName(
            workspaceRoot: workspaceRoot,
            host: host
        )
    }

    public func provisionFromLocalSSH(request: Request) async throws -> Result {
        let projectID = request.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = request.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let privateKeySecretName = request.privateKeySecretName.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownHostsSecretName = request.knownHostsSecretName?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !projectID.isEmpty else {
            throw AIBDeployError(phase: "gcloud-secrets", message: "Set a Google Cloud project before creating source auth secrets.")
        }
        guard !host.isEmpty else {
            throw AIBDeployError(phase: "gcloud-secrets", message: "Set a source auth host before creating cloud source auth secrets.")
        }
        guard !privateKeySecretName.isEmpty else {
            throw AIBDeployError(phase: "gcloud-secrets", message: "Cloud private key secret name cannot be empty.")
        }

        let privateKeyContents = try materializePrivateKeyContents(
            privateKeyPath: request.localPrivateKeyPath,
            host: host,
            passphrase: request.localPrivateKeyPassphrase
        )
        let knownHostsContents = try resolveKnownHostsContents(
            host: host,
            knownHostsPath: request.localKnownHostsPath
        )

        let createdPrivateKeySecret = try await upsertSecret(
            projectID: projectID,
            secretName: privateKeySecretName,
            contents: privateKeyContents
        )

        var createdKnownHostsSecret = false
        var resolvedKnownHostsSecretName: String?
        if let knownHostsSecretName, !knownHostsSecretName.isEmpty, !knownHostsContents.isEmpty {
            createdKnownHostsSecret = try await upsertSecret(
                projectID: projectID,
                secretName: knownHostsSecretName,
                contents: knownHostsContents
            )
            resolvedKnownHostsSecretName = knownHostsSecretName
        }

        return Result(
            privateKeySecretName: privateKeySecretName,
            knownHostsSecretName: resolvedKnownHostsSecretName,
            createdPrivateKeySecret: createdPrivateKeySecret,
            createdKnownHostsSecret: createdKnownHostsSecret
        )
    }

    private func materializePrivateKeyContents(
        privateKeyPath: String,
        host: String,
        passphrase: String?
    ) throws -> String {
        let trimmedPath = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw AIBDeployError(phase: "gcloud-secrets", message: "Local SSH private key path is empty.")
        }

        let sourceURL = URL(fileURLWithPath: trimmedPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw AIBDeployError(
                phase: "gcloud-secrets",
                message: "Local SSH private key was not found at \(sourceURL.path)."
            )
        }

        let blankPassphraseProbe = try inspectSSHPrivateKey(at: sourceURL, passphrase: "", host: host)
        if blankPassphraseProbe.exitCode == 0 {
            return try String(contentsOf: sourceURL, encoding: .utf8)
        }

        guard let passphrase, !passphrase.isEmpty else {
            if looksLikePassphraseProtected(stderr: blankPassphraseProbe.stderr) {
                throw AIBDeployError(
                    phase: "gcloud-secrets",
                    message: "The local SSH private key is passphrase-protected. Configure localPrivateKeyPassphraseEnv in the local target or use an unencrypted deploy key."
                )
            }
            throw AIBDeployError(
                phase: "gcloud-secrets",
                message: "The local SSH private key could not be validated: \(blankPassphraseProbe.stderr)"
            )
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: temporaryDirectory)
            } catch {
            }
        }

        let temporaryKeyURL = temporaryDirectory.appendingPathComponent("id_ed25519")
        try FileManager.default.copyItem(at: sourceURL, to: temporaryKeyURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: temporaryKeyURL.path
        )

        let decryptResult = try reencryptSSHPrivateKeyWithoutPassphrase(
            at: temporaryKeyURL,
            oldPassphrase: passphrase,
            host: host
        )
        guard decryptResult.exitCode == 0 else {
            throw AIBDeployError(
                phase: "gcloud-secrets",
                message: "Failed to remove the passphrase from the local SSH private key: \(decryptResult.stderr)"
            )
        }

        let decryptedProbe = try inspectSSHPrivateKey(at: temporaryKeyURL, passphrase: "", host: host)
        guard decryptedProbe.exitCode == 0 else {
            throw AIBDeployError(
                phase: "gcloud-secrets",
                message: "The decrypted SSH private key could not be validated: \(decryptedProbe.stderr)"
            )
        }

        return try String(contentsOf: temporaryKeyURL, encoding: .utf8)
    }

    private func resolveKnownHostsContents(host: String, knownHostsPath: String?) throws -> String {
        if let knownHostsPath {
            let trimmedPath = knownHostsPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPath.isEmpty {
                let knownHostsURL = URL(fileURLWithPath: trimmedPath)
                guard FileManager.default.fileExists(atPath: knownHostsURL.path) else {
                    throw AIBDeployError(
                        phase: "gcloud-secrets",
                        message: "Local known_hosts file was not found at \(knownHostsURL.path)."
                    )
                }
                return try String(contentsOf: knownHostsURL, encoding: .utf8)
            }
        }

        return AIBSourceDependencyAnalyzer.defaultKnownHosts(for: host) ?? ""
    }

    private func upsertSecret(
        projectID: String,
        secretName: String,
        contents: String
    ) async throws -> Bool {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: temporaryDirectory)
            } catch {
            }
        }

        let secretFileURL = temporaryDirectory.appendingPathComponent("secret.txt")
        try contents.write(to: secretFileURL, atomically: true, encoding: .utf8)

        if try await secretExists(projectID: projectID, secretName: secretName) {
            _ = try await runGCloud(
                arguments: [
                    "gcloud", "secrets", "versions", "add", secretName,
                    "--project", projectID,
                    "--data-file", secretFileURL.path,
                ],
                failureMessage: "Failed to update secret '\(secretName)'."
            )
            return false
        }

        _ = try await runGCloud(
            arguments: [
                "gcloud", "secrets", "create", secretName,
                "--project", projectID,
                "--replication-policy", "automatic",
                "--data-file", secretFileURL.path,
            ],
            failureMessage: "Failed to create secret '\(secretName)'."
        )
        return true
    }

    private func secretExists(projectID: String, secretName: String) async throws -> Bool {
        let result = try await processRunner.run(arguments: [
            "gcloud", "secrets", "describe", secretName,
            "--project", projectID,
        ]) { _ in }
        if result.exitCode == 0 {
            return true
        }

        let detail = [result.stderr, result.stdout]
            .joined(separator: "\n")
            .lowercased()
        if detail.contains("not found") || detail.contains("was not found") || detail.contains("not exist") {
            return false
        }

        throw AIBDeployError(
            phase: "gcloud-secrets",
            message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Failed to inspect secret '\(secretName)'."
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func runGCloud(
        arguments: [String],
        failureMessage: String
    ) async throws -> ProcessRunResult {
        let result = try await processRunner.run(arguments: arguments) { _ in }
        guard result.exitCode == 0 else {
            let detail = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            throw AIBDeployError(
                phase: "gcloud-secrets",
                message: detail ?? failureMessage
            )
        }
        return result
    }

    private func looksLikePassphraseProtected(stderr: String) -> Bool {
        let normalized = stderr.lowercased()
        return normalized.contains("passphrase")
            || normalized.contains("incorrect")
            || normalized.contains("private key is encrypted")
    }

    private func inspectSSHPrivateKey(
        at privateKeyURL: URL,
        passphrase: String,
        host: String
    ) throws -> SynchronousProcessResult {
        do {
            return try runProcessSynchronously(
                executablePath: "/usr/bin/ssh-keygen",
                arguments: ["-y", "-P", passphrase, "-f", privateKeyURL.path]
            )
        } catch {
            throw AIBDeployError(
                phase: "gcloud-secrets",
                message: "Failed to inspect the local SSH private key for \(host): \(error.localizedDescription)"
            )
        }
    }

    private func reencryptSSHPrivateKeyWithoutPassphrase(
        at privateKeyURL: URL,
        oldPassphrase: String,
        host: String
    ) throws -> SynchronousProcessResult {
        do {
            return try runProcessSynchronously(
                executablePath: "/usr/bin/ssh-keygen",
                arguments: ["-p", "-P", oldPassphrase, "-N", "", "-f", privateKeyURL.path]
            )
        } catch {
            throw AIBDeployError(
                phase: "gcloud-secrets",
                message: "Failed to remove the passphrase from the local SSH private key for \(host): \(error.localizedDescription)"
            )
        }
    }

    private func runProcessSynchronously(
        executablePath: String,
        arguments: [String]
    ) throws -> SynchronousProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return SynchronousProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}

private struct SynchronousProcessResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}
