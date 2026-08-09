import Foundation

public enum CompletionSummaryExtractor {
    private static let maximumLength = 160
    private static let maximumWords = 9

    public static func extract(from screen: String) -> String? {
        var shortEnding: String?
        for rawLine in screen.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let line = clean(String(rawLine))
            guard isSubstantive(line) else { continue }
            if let ending = shortEnding {
                return bounded("\(line) \(ending)")
            }
            guard endsSentence(line) else { continue }
            if line.count < 40 {
                shortEnding = line
                continue
            }
            return bounded(line)
        }
        return shortEnding.map(bounded)
    }

    static func bounded(_ line: String) -> String {
        let sentences = line.replacingOccurrences(
            of: #"(?<=[.!?…])\s+"#,
            with: "\n",
            options: .regularExpression
        ).split(separator: "\n").map(String.init)
        let preferred = sentences.count > 1 ? sentences.last! : line
        let characterCapped: String
        if preferred.count > maximumLength {
            let end = preferred.index(preferred.startIndex, offsetBy: maximumLength - 1)
            characterCapped = String(preferred[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        } else {
            characterCapped = preferred
        }
        let words = characterCapped.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > maximumWords else { return characterCapped }
        let result = words.prefix(maximumWords).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?…"))
        return result + "…"
    }

    private static func endsSentence(_ line: String) -> Bool {
        guard let last = line.last else { return false }
        return ".?!…".contains(last)
    }

    private static func clean(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let borderCharacters = CharacterSet(charactersIn: "│┃┌┐└┘╭╮╰╯")
        value = value.trimmingCharacters(in: borderCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = value.first, ["•", "-", "*"].contains(first) {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    private static func isSubstantive(_ line: String) -> Bool {
        guard line.count >= 8, line.rangeOfCharacter(from: .letters) != nil else { return false }
        let lowered = line.lowercased()
        if line == "❯" || line.hasPrefix("❯ ") { return false }
        if line.hasPrefix("[") || line.hasPrefix("⚕") || line.hasPrefix("↳") { return false }
        if lowered.contains("ready │") || lowered.contains("ctrl+c to interrupt") { return false }
        let statusMarkers = ["reasoning…", "reasoning...", "thinking…", "thinking...", "working…", "working..."]
        if statusMarkers.contains(where: lowered.contains) { return false }
        if line.allSatisfy({ $0.isWhitespace || "─━═-_".contains($0) }) { return false }
        return true
    }
}
