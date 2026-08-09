import Foundation

public enum BoundedTurnSummary {
    public static func summarize(_ turn: HermesFinalTurn, maxWords: Int = 9) -> String? {
        guard maxWords > 0 else { return nil }
        let assistant = turn.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assistant.isEmpty else { return nil }
        let sentenceLines = assistant.replacingOccurrences(
            of: #"(?<=[.!?])\s+"#,
            with: "\n",
            options: .regularExpression
        )
        var candidate = CompletionSummaryExtractor.extract(from: sentenceLines) ?? assistant
        candidate = candidate
            .replacingOccurrences(
                of: #"(?i)^summary\s+(?:is|:)\s*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        let words = candidate.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > maxWords else { return candidate }
        var result = words.prefix(maxWords).joined(separator: " ")
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        return result + "…"
    }
}
