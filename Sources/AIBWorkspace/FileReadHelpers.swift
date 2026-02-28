import Foundation

func readTextFileOrEmpty(path: String) -> String {
    do {
        return try String(contentsOfFile: path, encoding: .utf8)
    } catch {
        return ""
    }
}

func readTextFileOrEmpty(url: URL) -> String {
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        return ""
    }
}
