import Foundation

enum LocalSourceAuthMethod: String, CaseIterable, Identifiable {
    case sshKey
    case githubToken

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sshKey:
            "SSH Key"
        case .githubToken:
            "GitHub Token"
        }
    }
}

enum LocalSourceAuthPassphraseMode: String, CaseIterable, Identifiable {
    case none
    case appManaged
    case external

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:
            "None"
        case .appManaged:
            "App Managed"
        case .external:
            "External Env"
        }
    }
}

struct LocalSourceAuthValidationState {
    enum Level {
        case neutral
        case success
        case warning
        case failure
    }

    var level: Level
    var message: String
}

@MainActor
final class LocalSourceAuthValidationService {
    func validate(
        privateKeyPath: String,
        passphraseMode: LocalSourceAuthPassphraseMode,
        managedPassphrase: String,
        externalEnvironmentKey: String
    ) -> LocalSourceAuthValidationState {
        let trimmedPath = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return LocalSourceAuthValidationState(level: .neutral, message: "Set a private key path to validate local source auth.")
        }
        guard FileManager.default.fileExists(atPath: trimmedPath) else {
            return LocalSourceAuthValidationState(level: .failure, message: "Private key file was not found.")
        }

        let blankProbe: LocalSourceAuthValidationProbeResult
        do {
            blankProbe = try inspect(privateKeyPath: trimmedPath, passphrase: "")
        } catch {
            return LocalSourceAuthValidationState(level: .failure, message: error.localizedDescription)
        }

        if blankProbe.exitCode == 0 {
            return LocalSourceAuthValidationState(level: .success, message: "Key is usable without a passphrase.")
        }

        switch passphraseMode {
        case .appManaged:
            let passphrase = managedPassphrase
            guard !passphrase.isEmpty else {
                return LocalSourceAuthValidationState(level: .warning, message: "Key appears encrypted. Enter a passphrase to store it in Keychain.")
            }
            do {
                let managedProbe = try inspect(privateKeyPath: trimmedPath, passphrase: passphrase)
                if managedProbe.exitCode == 0 {
                    return LocalSourceAuthValidationState(level: .success, message: "Encrypted key can be unlocked from Keychain.")
                }
                return LocalSourceAuthValidationState(level: .failure, message: "Stored passphrase does not unlock this key.")
            } catch {
                return LocalSourceAuthValidationState(level: .failure, message: error.localizedDescription)
            }
        case .external:
            let envName = externalEnvironmentKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !envName.isEmpty else {
                return LocalSourceAuthValidationState(level: .warning, message: "Provide the external environment variable name used for this key.")
            }
            return LocalSourceAuthValidationState(level: .warning, message: "Key appears encrypted and will rely on external env '\(envName)'.")
        case .none:
            return LocalSourceAuthValidationState(level: .warning, message: "Key appears encrypted but no passphrase management is configured.")
        }
    }

    private func inspect(
        privateKeyPath: String,
        passphrase: String
    ) throws -> LocalSourceAuthValidationProbeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-y", "-P", passphrase, "-f", privateKeyPath]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()

        return LocalSourceAuthValidationProbeResult(
            exitCode: process.terminationStatus,
            stderr: stderr
        )
    }
}

private struct LocalSourceAuthValidationProbeResult {
    var exitCode: Int32
    var stderr: String
}
