import Foundation

enum PreflightDiagnostics {
    private static let maxOutputLength = 4_000

    static func lines(command: String, result: ShellProbe.Result) -> [String] {
        [
            "$ \(command)",
            "exit code: \(result.exitCode)",
            "stdout:",
            formattedOutput(result.stdout),
            "stderr:",
            formattedOutput(result.stderr),
        ]
    }

    static func lines(command: String, error: Error) -> [String] {
        [
            "$ \(command)",
            "error: \(error.localizedDescription)",
        ]
    }

    private static func formattedOutput(_ output: String) -> String {
        guard !output.isEmpty else {
            return "<empty>"
        }
        if output.count <= maxOutputLength {
            return output
        }
        return "\(output.prefix(maxOutputLength))\n... truncated"
    }
}
