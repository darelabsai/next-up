import Foundation

public enum InputRequestKind: String, Codable, Equatable, Sendable {
    case approval
    case clarification
    case response
}

public struct SurfaceClassification: Equatable, Sendable {
    public let state: LaneState
    public let inputRequestKind: InputRequestKind?

    public init(state: LaneState, inputRequestKind: InputRequestKind? = nil) {
        self.state = state
        self.inputRequestKind = state == .inputRequired ? inputRequestKind : nil
    }
}

public enum SurfaceContentClassifier {
    private struct PhysicalLine {
        let text: String
        let index: Int
    }

    private struct ParsedCandidate {
        let kind: InputRequestKind
        let endIndex: Int
    }

    private struct Footer {
        let start: Int
        let end: Int
        let numericQuickPickUpper: Int?
        let hasYNQuickPick: Bool
    }

    private struct NumberedChoice {
        let number: Int
        let label: String
        let numericColumn: Int
    }

    private struct NumberedChoiceBlock {
        let range: Range<Int>
        let choices: [NumberedChoice]

        var isCanonicalSequence: Bool {
            guard let first = choices.first else { return false }
            return choices.enumerated().allSatisfy { offset, choice in
                choice.number == offset + 1 && choice.numericColumn == first.numericColumn
            }
        }
    }

    public static func classify(_ screen: String) -> LaneState {
        classification(screen).state
    }

    public static func classification(
        _ screen: String,
        titleHasWarningHint: Bool = false
    ) -> SurfaceClassification {
        var allLines = screen
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { sanitize(String($0)) }
        if screen.hasSuffix("\n") {
            allLines.removeLast()
        }
        let window = Array(allLines.suffix(80)).enumerated().map {
            PhysicalLine(text: $0.element, index: $0.offset)
        }

        if let requestKind = latestInputCandidate(
            in: window,
            titleHasWarningHint: titleHasWarningHint
        ) {
            return SurfaceClassification(state: .inputRequired, inputRequestKind: requestKind)
        }

        // Preserve the established busy/ready behavior: status classification is
        // based on the latest eight non-empty rendered rows.
        let statusLines = window
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(8)
        let lowered = statusLines.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }

        if lowered.contains(where: isProcessingLine) {
            return SurfaceClassification(state: .busy)
        }
        if lowered.contains(where: { $0.contains("ready │") }) {
            return SurfaceClassification(state: .ready)
        }
        if statusLines.contains(where: { isIdlePromptLine($0.trimmingCharacters(in: .whitespaces)) }) {
            return SurfaceClassification(state: .ready)
        }
        return SurfaceClassification(state: .unknown)
    }

    private static func latestInputCandidate(
        in lines: [PhysicalLine],
        titleHasWarningHint: Bool
    ) -> InputRequestKind? {
        var candidates: [ParsedCandidate] = []

        for block in blankDelimitedBlocks(lines) {
            candidates.append(contentsOf: borderedCandidates(in: block, windowCount: lines.count))
            if titleHasWarningHint,
               let candidate = truncatedApprovalCandidate(in: block, windowCount: lines.count) {
                candidates.append(candidate)
            }
            if let candidate = unborderedCandidate(in: block, windowCount: lines.count) {
                candidates.append(candidate)
            }
        }

        guard let latestEnd = candidates.map(\.endIndex).max() else { return nil }
        let latest = candidates.filter { $0.endIndex == latestEnd }
        let kinds = Set(latest.map(\.kind))
        guard kinds.count == 1 else { return nil }
        return latest[0].kind
    }

    private static func truncatedApprovalCandidate(
        in block: [PhysicalLine],
        windowCount: Int
    ) -> ParsedCandidate? {
        guard !block.contains(where: { firstNonSpace(in: $0.text) == "╔" }),
              let closingOffset = block.firstIndex(where: { firstNonSpace(in: $0.text) == "╚" }),
              closingOffset > 0 else { return nil }
        var rows: [String] = []
        for line in block[..<closingOffset] {
            guard let row = unwrapBorderedRow(line.text) else { return nil }
            rows.append(row)
        }
        guard semanticKind(rows: rows, bordered: true) == .approval else { return nil }
        let endIndex = block[closingOffset].index
        guard windowCount - endIndex - 1 <= 16 else { return nil }
        return ParsedCandidate(kind: .approval, endIndex: endIndex)
    }

    private static func blankDelimitedBlocks(_ lines: [PhysicalLine]) -> [[PhysicalLine]] {
        var result: [[PhysicalLine]] = []
        var current: [PhysicalLine] = []
        for line in lines {
            if line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    result.append(current)
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func borderedCandidates(
        in block: [PhysicalLine],
        windowCount: Int
    ) -> [ParsedCandidate] {
        var result: [ParsedCandidate] = []
        var offset = 0

        while offset < block.count {
            let opening = block[offset].text
            guard firstNonSpace(in: opening) == "╔" else {
                offset += 1
                continue
            }
            let openingIndent = leadingSpaceCount(opening)
            var closingOffset: Int?
            var nested = false
            var cursor = offset + 1
            while cursor < block.count {
                let first = firstNonSpace(in: block[cursor].text)
                if first == "╔" {
                    nested = true
                    break
                }
                if first == "╚" {
                    closingOffset = cursor
                    break
                }
                cursor += 1
            }
            guard !nested, let closingOffset,
                  leadingSpaceCount(block[closingOffset].text) == openingIndent,
                  closingOffset > offset + 1 else {
                offset += 1
                continue
            }

            let interior = block[(offset + 1)..<closingOffset]
            var rows: [String] = []
            var valid = true
            for line in interior {
                guard let row = unwrapBorderedRow(line.text) else {
                    valid = false
                    break
                }
                rows.append(row)
            }

            let endIndex = block[closingOffset].index
            if valid, windowCount - endIndex - 1 <= 16,
               let kind = semanticKind(rows: rows, bordered: true) {
                result.append(ParsedCandidate(kind: kind, endIndex: endIndex))
            }
            offset = closingOffset + 1
        }
        return result
    }

    private static func unborderedCandidate(
        in block: [PhysicalLine],
        windowCount: Int
    ) -> ParsedCandidate? {
        let rows = block.map(\.text)
        guard let semantic = semanticKindAndEnd(rows: rows, bordered: false) else { return nil }
        let endIndex = block[semantic.end].index
        guard windowCount - endIndex - 1 <= 16 else { return nil }
        return ParsedCandidate(kind: semantic.kind, endIndex: endIndex)
    }

    private static func semanticKind(
        rows: [String],
        bordered: Bool
    ) -> InputRequestKind? {
        semanticKindAndEnd(rows: rows, bordered: bordered)?.kind
    }

    private static func semanticKindAndEnd(
        rows: [String],
        bordered: Bool
    ) -> (kind: InputRequestKind, end: Int, genericHeaderOnly: Bool)? {
        let trimmed = rows.map { $0.trimmingCharacters(in: .whitespaces) }
        let lowered = trimmed.map { $0.lowercased() }

        // Masked prompts have no selection footer.
        if let input = firstInputRow(in: trimmed) {
            if let heading = lowered.firstIndex(where: {
                collapsedWhitespace($0) == "🔐 sudo password required"
            }), heading < input, isMaskedInputRow(trimmed[input]) {
                return (.response, input, false)
            }
            if let heading = lowered.firstIndex(where: { $0.hasPrefix("🔑") }), heading < input,
               lowered[(heading + 1)..<input].contains(where: { $0.hasPrefix("for ") }),
               isMaskedInputRow(trimmed[input]) {
                return (.response, input, false)
            }
            if let ask = lowered.firstIndex(where: isAskHeading), ask < input,
               let sendEnd = sendFooterEnd(in: rows, after: input) {
                return (.clarification, sendEnd, false)
            }
        }

        for footer in selectionFooters(in: rows).reversed() {
            let approvalHeader = lowered[..<footer.start].contains {
                matchesHeader($0, phrases: ["approval required", "permission required"])
            }
            let inputHeader = lowered[..<footer.start].contains {
                matchesHeader($0, phrases: ["input required"])
            }
            let finalGroup = adjacentNumberedChoiceBlock(in: rows, before: footer.start)
            let canonicalApproval = finalGroup.map { group in
                group.isCanonicalSequence
                    && footer.numericQuickPickUpper == group.choices.count
                    && (2...4).contains(group.choices.count)
                    && group.choices.allSatisfy { isCanonicalApprovalLabel($0.label) }
            } ?? false

            // A source menu is one adjacent numbered block. Do not let a
            // duplicate/skip split into a later apparently-valid group, and do
            // not let an approval header rescue malformed source menu rows.
            if let group = finalGroup {
                guard group.isCanonicalSequence,
                      let quickPickUpper = footer.numericQuickPickUpper else { continue }
                let hasOther = group.choices.last?.label.lowercased() == "other (type your answer)"
                let expectedUpper = hasOther ? group.choices.count - 1 : group.choices.count
                guard quickPickUpper == expectedUpper else { continue }
            } else if approvalHeader, footer.numericQuickPickUpper != nil {
                continue
            }

            if footer.hasYNQuickPick, bordered, !approvalHeader, !canonicalApproval,
               confirmHasExactlyTwoChoices(rows: rows, footerStart: footer.start) {
                return (.response, footer.end, false)
            }

            if let group = finalGroup, footer.numericQuickPickUpper != nil {
                let ask = lowered[..<group.range.lowerBound].contains(where: isAskHeading)
                let hasOther = group.choices.last?.label.lowercased() == "other (type your answer)"
                if ask, hasOther {
                    return (.clarification, footer.end, false)
                }
                if approvalHeader || (bordered && canonicalApproval) {
                    return (.approval, footer.end, false)
                }
            }

            if approvalHeader {
                return (.approval, footer.end, finalGroup == nil)
            }
            if inputHeader {
                return (.response, footer.end, true)
            }
        }
        return nil
    }

    private static func selectionFooters(in rows: [String]) -> [Footer] {
        var result: [Footer] = []
        for start in rows.indices where rows[start].contains("↑/↓ select") {
            for count in 1...4 where start + count <= rows.count {
                let fragments = Array(rows[start..<(start + count)])
                let logical = normalizedFooter(fragments)
                guard !footerContinues(in: rows, after: start + count),
                      logical.count <= 1_024 else { continue }
                let controls = logical.components(separatedBy: " · ")
                guard controls.first?.lowercased() == "↑/↓ select",
                      controls.contains(where: { $0.lowercased() == "enter confirm" }) else { continue }
                let numericUpper = controls.compactMap(numericQuickPickUpper).first
                let yn = controls.contains { $0.lowercased() == "y/n quick" }
                let hasCancelControl = controls.contains {
                    $0.lowercased().hasPrefix("esc/ctrl+c")
                }
                if numericUpper != nil || yn || hasCancelControl || controls.count == 2 {
                    result.append(Footer(
                        start: start,
                        end: start + count - 1,
                        numericQuickPickUpper: numericUpper,
                        hasYNQuickPick: yn
                    ))
                    break
                }
            }
        }
        return result
    }

    private static func sendFooterEnd(in rows: [String], after input: Int) -> Int? {
        guard input + 1 < rows.count else { return nil }
        for start in (input + 1)..<rows.count {
            for count in 1...4 where start + count <= rows.count {
                let fragments = Array(rows[start..<(start + count)])
                let logical = normalizedFooter(fragments)
                guard !footerContinues(in: rows, after: start + count),
                      logical.count <= 1_024 else { continue }
                let controls = logical.components(separatedBy: " · ")
                if controls.first?.lowercased() == "enter send" {
                    return start + count - 1
                }
            }
        }
        return nil
    }

    private static func adjacentNumberedChoiceBlock(
        in rows: [String],
        before footerStart: Int
    ) -> NumberedChoiceBlock? {
        guard footerStart > 0, numberedChoice(rows[footerStart - 1]) != nil else { return nil }
        var start = footerStart - 1
        while start > 0, numberedChoice(rows[start - 1]) != nil {
            start -= 1
        }
        let choices = rows[start..<footerStart].compactMap(numberedChoice)
        return NumberedChoiceBlock(range: start..<footerStart, choices: choices)
    }

    private static func numericQuickPickUpper(_ control: String) -> Int? {
        let pattern = #"^1[-–]([1-9]\d*) quick pick$"#
        let normalized = control.lowercased()
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: normalized,
                range: NSRange(normalized.startIndex..., in: normalized)
              ),
              let range = Range(match.range(at: 1), in: normalized) else { return nil }
        return Int(normalized[range])
    }

    private static func numberedChoice(_ row: String) -> NumberedChoice? {
        let pattern = #"^\s*(?:▸|>)?\s*(\d+)\.\s+(.+?)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: row,
                range: NSRange(row.startIndex..., in: row)
              ), match.range.location == 0,
              let numberRange = Range(match.range(at: 1), in: row),
              let labelRange = Range(match.range(at: 2), in: row),
              let number = Int(row[numberRange]) else { return nil }
        let column = row.distance(from: row.startIndex, to: numberRange.lowerBound)
        return NumberedChoice(number: number, label: String(row[labelRange]), numericColumn: column)
    }

    private static func confirmHasExactlyTwoChoices(rows: [String], footerStart: Int) -> Bool {
        guard footerStart >= 2 else { return false }
        let pair = Array(rows[(footerStart - 2)..<footerStart])
        let selectable = pair.allSatisfy { row in
            row.hasPrefix("▸ ") || row.hasPrefix("  ")
        }
        guard selectable, pair.contains(where: { $0.hasPrefix("▸ ") }) else { return false }
        if footerStart >= 3 {
            let prior = rows[footerStart - 3]
            if prior.hasPrefix("▸ ") || prior.hasPrefix("  ") { return false }
        }
        return true
    }

    private static func footerContinues(in rows: [String], after end: Int) -> Bool {
        guard end > 0, end < rows.count else { return false }
        let previous = rows[end - 1].trimmingCharacters(in: .whitespaces).lowercased()
        let next = rows[end].trimmingCharacters(in: .whitespaces).lowercased()
        if previous.hasSuffix("·") || next.hasPrefix("·") { return true }
        return previous.hasSuffix("esc/ctrl+c") && (next == "cancel" || next == "deny")
    }

    private static func normalizedFooter(_ rows: [String]) -> String {
        let joined = rows
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        return joined
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: " · ", with: " · ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func firstInputRow(in rows: [String]) -> Int? {
        rows.firstIndex { $0.hasPrefix(">") }
    }

    private static func isMaskedInputRow(_ row: String) -> Bool {
        guard row.hasPrefix(">") else { return false }
        let payload = row.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty else { return true }
        return payload.allSatisfy { $0 == "*" } || payload == "█"
    }

    private static func isAskHeading(_ line: String) -> Bool {
        line == "ask" || line.hasPrefix("ask ")
    }

    private static func isCanonicalApprovalLabel(_ label: String) -> Bool {
        ["allow once", "allow this session", "always allow", "deny"]
            .contains(label.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private static func unwrapBorderedRow(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "║", trimmed.last == "║", trimmed.count >= 2 else { return nil }
        var inner = String(trimmed.dropFirst().dropLast())
        if inner.first == " " { inner.removeFirst() }
        if inner.last == " " { inner.removeLast() }
        return inner
    }

    private static func firstNonSpace(in line: String) -> Character? {
        line.first(where: { $0 != " " && $0 != "\t" })
    }

    private static func leadingSpaceCount(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func sanitize(_ line: String) -> String {
        var value = line.replacingOccurrences(
            of: #"\u{001B}\[[0-?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )
        value = String(value.unicodeScalars.filter { scalar in
            scalar.value == 9 || scalar.value >= 32
        })
        return value.replacingOccurrences(
            of: #"[ \t]+$"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func matches(_ line: String, _ pattern: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }

    private static func matchesHeader(_ line: String, phrases: [String]) -> Bool {
        var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("⚠️") {
            value.removeFirst(2)
        } else if value.hasPrefix("⚠") {
            value.removeFirst()
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let alternatives = phrases.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return matches(value, "^(?:\(alternatives))(?:\\s*·.*)?$")
    }

    private static func isProcessingLine(_ line: String) -> Bool {
        if line.contains("ctrl+c to interrupt") { return true }
        if line.contains("ready │") { return false }
        if (line.contains("…") || line.contains("...")),
           line.contains(" · "), line.contains(" │ ") {
            return true
        }
        let markers = [
            "reasoning…", "reasoning...", "thinking…", "thinking...",
            "working…", "working...", "running…", "running...",
            "executing…", "executing...", "analyzing…", "analyzing...",
            "ruminating…", "ruminating...", "mulling…", "mulling...",
            "reflecting…", "reflecting...",
            "tool…", "tool...",
        ]
        return markers.contains(where: line.contains)
    }

    private static func isIdlePromptLine(_ line: String) -> Bool {
        line == "❯" || line.hasPrefix("❯ ")
    }
}
