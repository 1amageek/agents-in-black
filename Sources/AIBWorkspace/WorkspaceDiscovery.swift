import Foundation

public enum WorkspaceDiscovery {
    private static let excludedDirectoryNames: Set<String> = [
        ".git", "node_modules", ".build", ".swiftpm", "dist", "build", ".next", ".turbo", ".venv", "__pycache__"
    ]

    public static func discoverRepos(workspaceRoot: String, scanPath: String) throws -> [WorkspaceRepo] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: workspaceRoot).standardizedFileURL
        let scanURL = URL(fileURLWithPath: scanPath, relativeTo: rootURL).standardizedFileURL

        var repos: [DiscoveredRepo] = []
        let enumerator = fm.enumerator(
            at: scanURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .nameKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        )

        while let url = enumerator?.nextObject() as? URL {
            let last = url.lastPathComponent
            if excludedDirectoryNames.contains(last) {
                enumerator?.skipDescendants()
                continue
            }
            let gitDir = url.appendingPathComponent(".git")
            if fm.fileExists(atPath: gitDir.path) {
                repos.append(inspectRepo(at: url, workspaceRoot: rootURL))
                enumerator?.skipDescendants()
            }
        }

        let uniqueNamed = uniquedRepoNames(for: repos)
        return uniqueNamed.map { $0.repo }.sorted { $0.name < $1.name }
    }

    private static func inspectRepo(at repoURL: URL, workspaceRoot: URL) -> DiscoveredRepo {
        let runtimeInfo = RuntimeAdapterRegistry.detect(repoURL: repoURL)
        let relPath = relativePath(from: workspaceRoot, to: repoURL)

        let status: RepoStatus = runtimeInfo.candidates.isEmpty ? .unresolved : .discoverable

        let autoSelected = runtimeInfo.candidates.first?.argv.contains("${PORT}") == true
            ? nil
            : runtimeInfo.candidates.first?.argv

        return DiscoveredRepo(
            repo: WorkspaceRepo(
                name: repoURL.lastPathComponent,
                path: relPath,
                runtime: runtimeInfo.runtime,
                framework: runtimeInfo.framework,
                packageManager: runtimeInfo.packageManager,
                status: status,
                detectionConfidence: runtimeInfo.confidence,
                commandCandidates: runtimeInfo.candidates,
                selectedCommand: autoSelected,
                servicesNamespace: repoURL.lastPathComponent,
                enabled: true
            ),
            originalURL: repoURL
        )
    }

    private static func uniquedRepoNames(for repos: [DiscoveredRepo]) -> [DiscoveredRepo] {
        var seen: [String: Int] = [:]
        var result: [DiscoveredRepo] = []
        for item in repos.sorted(by: { $0.repo.name < $1.repo.name }) {
            var adjusted = item
            let base = item.repo.name
            let count = (seen[base] ?? 0) + 1
            seen[base] = count
            if count > 1 {
                adjusted.repo.name = "\(base)-\(count)"
                if adjusted.repo.servicesNamespace == base {
                    adjusted.repo.servicesNamespace = adjusted.repo.name
                }
            }
            result.append(adjusted)
        }
        return result
    }

    /// Inspect a single directory as a potential repo, detecting runtime and computing relative path.
    public static func inspectSingleRepo(at repoURL: URL, workspaceRoot: URL) -> WorkspaceRepo {
        inspectRepo(at: repoURL.standardizedFileURL, workspaceRoot: workspaceRoot.standardizedFileURL).repo
    }

    /// Compute relative path from root to target, supporting upward traversal via `../`.
    public static func relativePath(from root: URL, to target: URL) -> String {
        let rootComps = root.standardizedFileURL.pathComponents
        let targetComps = target.standardizedFileURL.pathComponents
        var i = 0
        while i < min(rootComps.count, targetComps.count), rootComps[i] == targetComps[i] {
            i += 1
        }
        let upward = Array(repeating: "..", count: rootComps.count - i)
        let downward = Array(targetComps[i...])
        let comps = upward + downward
        return comps.isEmpty ? "." : comps.joined(separator: "/")
    }
}

private struct DiscoveredRepo {
    var repo: WorkspaceRepo
    var originalURL: URL
}
