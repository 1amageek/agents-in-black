import Darwin.POSIX.pwd
import Foundation

enum AppleContainerInstallerError: Error, LocalizedError {
    case releaseFetchFailed(Int)
    case noInstallerAssetFound
    case invalidDownloadResponse
    case installerCommandFailed(String)
    case postInstallSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .releaseFetchFailed(let statusCode):
            return "Failed to fetch latest apple/container release (HTTP \(statusCode))."
        case .noInstallerAssetFound:
            return "No installer package found in the latest apple/container release."
        case .invalidDownloadResponse:
            return "Installer download returned an unexpected response."
        case .installerCommandFailed(let detail):
            return "Installer command failed: \(detail)"
        case .postInstallSetupFailed(let detail):
            return "apple/container was installed, but setup failed: \(detail)"
        }
    }
}

struct AppleContainerInstaller {
    private static let fallbackContainerBinaryPaths: [String] = [
        "/opt/homebrew/bin/container",
        "/usr/local/bin/container",
        "/usr/bin/container"
    ]

    private static let defaultPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    private struct CommandResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Resolve the current user's login shell from the account database.
    /// This is more reliable than `$SHELL` in GUI app execution.
    private static var userLoginShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            return String(cString: shell)
        }
        return "/bin/zsh"
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    static func installLatest() async throws -> String {
        let release = try await fetchLatestRelease()
        guard let asset = selectInstallerAsset(from: release.assets) else {
            throw AppleContainerInstallerError.noInstallerAssetFound
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(asset.name)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        let (downloadedURL, response) = try await URLSession.shared.download(from: asset.browserDownloadURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AppleContainerInstallerError.invalidDownloadResponse
        }
        try FileManager.default.moveItem(at: downloadedURL, to: destination)

        try await runInstaller(packagePath: destination.path)
        try await runContainerSystemStart()

        return release.tagName
    }

    private static func fetchLatestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/apple/container/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AgentsInBlack", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppleContainerInstallerError.invalidDownloadResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw AppleContainerInstallerError.releaseFetchFailed(http.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    private static func selectInstallerAsset(from assets: [GitHubAsset]) -> GitHubAsset? {
        if let signed = assets.first(where: { $0.name.hasSuffix("-installer-signed.pkg") }) {
            return signed
        }
        return assets.first(where: { $0.name.hasSuffix(".pkg") })
    }

    private static func runInstaller(packagePath: String) async throws {
        let shellCommand = "/usr/sbin/installer -pkg \(shellQuote(packagePath)) -target /"
        let appleScript = """
        do shell script "\(appleScriptEscape(shellCommand))" with administrator privileges
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)"
            throw AppleContainerInstallerError.installerCommandFailed(detail)
        }
    }

    private static func runContainerSystemStart() async throws {
        try startContainerSystemServices()
        try await ensureBuilderReadyWithKernelSetup()
    }

    private static func startContainerSystemServices() throws {
        var failureDetails: [String] = []

        let loginShellStart = try runCommand(
            executablePath: userLoginShell,
            arguments: ["-l", "-c", "container system start >/dev/null 2>&1 &"]
        )
        if loginShellStart.exitCode != 0 {
            failureDetails.append("login-shell: \(normalizedError(from: loginShellStart))")
        }

        if loginShellStart.exitCode != 0 {
            for binaryPath in fallbackContainerBinaryPaths {
                let command = "\(shellQuote(binaryPath)) system start >/dev/null 2>&1 &"
                do {
                    let result = try runCommand(
                        executablePath: "/bin/sh",
                        arguments: ["-c", command]
                    )
                    if result.exitCode == 0 {
                        return
                    }
                    failureDetails.append("\(binaryPath): \(normalizedError(from: result))")
                } catch {
                    failureDetails.append("\(binaryPath): \(error.localizedDescription)")
                }
            }

            throw AppleContainerInstallerError.postInstallSetupFailed(
                failureDetails.joined(separator: " | ")
            )
        }
    }

    private static func ensureBuilderReadyWithKernelSetup() async throws {
        let status = try runCommand(
            executablePath: userLoginShell,
            arguments: ["-l", "-c", "container builder status >/dev/null 2>&1"]
        )
        if status.exitCode == 0 {
            return
        }

        let firstStartAttempt = try runCommand(
            executablePath: userLoginShell,
            arguments: ["-l", "-c", "container builder start 2>&1"]
        )
        if firstStartAttempt.exitCode == 0 {
            try await waitForBuilderReady()
            return
        }

        let firstAttemptOutput = normalizedError(from: firstStartAttempt)
        if firstAttemptOutput.localizedCaseInsensitiveContains("default kernel not configured") {
            try runKernelSetupRecommended()

            let secondStartAttempt = try runCommand(
                executablePath: userLoginShell,
                arguments: ["-l", "-c", "container builder start 2>&1"]
            )
            if secondStartAttempt.exitCode == 0 {
                try await waitForBuilderReady()
                return
            }

            throw AppleContainerInstallerError.postInstallSetupFailed(
                "builder start failed after kernel setup: \(normalizedError(from: secondStartAttempt))"
            )
        }

        throw AppleContainerInstallerError.postInstallSetupFailed(
            "builder start failed: \(firstAttemptOutput)"
        )
    }

    private static func runKernelSetupRecommended() throws {
        let result = try runCommand(
            executablePath: userLoginShell,
            arguments: ["-l", "-c", "container system kernel set --recommended 2>&1"]
        )
        if result.exitCode == 0 {
            return
        }
        throw AppleContainerInstallerError.postInstallSetupFailed(
            "kernel setup failed: \(normalizedError(from: result))"
        )
    }

    private static func waitForBuilderReady(
        timeout: Duration = .seconds(30),
        pollInterval: Duration = .seconds(1)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        var lastStatus = "builder is not ready yet"

        while ContinuousClock.now < deadline {
            let result = try runCommand(
                executablePath: userLoginShell,
                arguments: ["-l", "-c", "container builder status >/dev/null 2>&1"]
            )
            if result.exitCode == 0 {
                return
            }
            lastStatus = normalizedError(from: result)
            try await Task.sleep(for: pollInterval)
        }

        throw AppleContainerInstallerError.postInstallSetupFailed(
            "Timed out waiting for container builder readiness (30s): \(lastStatus)"
        )
    }

    private static func runCommand(executablePath: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = defaultPATH
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    private static func normalizedError(from result: CommandResult) -> String {
        if !result.stderr.isEmpty {
            return result.stderr
        }
        if !result.stdout.isEmpty {
            return result.stdout
        }
        return "exit \(result.exitCode)"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
