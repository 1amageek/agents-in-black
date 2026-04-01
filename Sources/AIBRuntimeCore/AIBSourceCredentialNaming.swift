import Foundation

public enum AIBSourceCredentialNaming {
    public static func suggestedPrivateKeySecretName(workspaceRoot: String, host: String) -> String {
        suggestedSecretName(workspaceRoot: workspaceRoot, host: host, suffix: "ssh-key")
    }

    public static func suggestedKnownHostsSecretName(workspaceRoot: String, host: String) -> String {
        suggestedSecretName(workspaceRoot: workspaceRoot, host: host, suffix: "known-hosts")
    }

    private static func suggestedSecretName(workspaceRoot: String, host: String, suffix: String) -> String {
        let workspaceName = URL(fileURLWithPath: workspaceRoot).lastPathComponent
        let components = [
            "aib",
            sanitizeSecretComponent(workspaceName),
            sanitizeSecretComponent(host),
            suffix,
        ].filter { !$0.isEmpty }
        return components.joined(separator: "-")
    }

    private static func sanitizeSecretComponent(_ value: String) -> String {
        let lowercased = value.lowercased()
        let mapped = lowercased.map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "value" : String(collapsed.prefix(63))
    }
}
