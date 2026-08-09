import Foundation

public enum CompletionAnnouncementFormatter {
    public static func spoken(_ completions: [PendingCompletion], at now: Date) -> String {
        grouped(completions).flatMap { group -> [String] in
            var statements: [String] = []
            let first = group.completions.filter { $0.lastAnnouncedAt == nil }
            let repeats = group.completions.filter { $0.lastAnnouncedAt != nil }
            if !first.isEmpty {
                statements.append(firstAnnouncement(first, workspaceTitle: group.workspaceTitle))
            }
            if !repeats.isEmpty {
                statements.append(repeatAnnouncement(repeats, workspaceTitle: group.workspaceTitle, now: now))
            }
            return statements
        }.joined(separator: " ")
    }

    public static func notificationBody(_ completion: PendingCompletion, at now: Date) -> String {
        let lead: String
        if completion.lastAnnouncedAt == nil {
            lead = "Finished"
        } else {
            lead = "Finished about \(elapsedDescription(completion, at: now)) ago"
        }
        guard let summary = nonemptySummary(completion) else { return lead + "." }
        return "\(lead) — \(summary)"
    }

    public static func roundedIdleMinutes(_ completion: PendingCompletion, at now: Date) -> Int {
        max(1, Int(ceil(max(0, now.timeIntervalSince(completion.completedAt)) / 60)))
    }

    public static func elapsedDescription(_ completion: PendingCompletion, at now: Date) -> String {
        let totalMinutes = roundedIdleMinutes(completion, at: now)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let minuteText = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        guard hours > 0 else { return minuteText }
        let hourText = hours == 1 ? "an hour" : "\(hours) hours"
        guard minutes > 0 else { return hourText }
        return "\(hourText) and \(minuteText)"
    }

    private static func firstAnnouncement(
        _ completions: [PendingCompletion],
        workspaceTitle: String?
    ) -> String {
        guard completions.count > 1 else {
            return singleSentence(completions[0], lead: "\(completions[0].displayName) finished")
        }
        let scope = workspaceTitle.map { " \($0)" } ?? ""
        let clauses = completions.map(clause).joined(separator: "; ")
        return "\(countWord(completions.count))\(scope) lanes finished: \(clauses)."
    }

    private static func repeatAnnouncement(
        _ completions: [PendingCompletion],
        workspaceTitle: String?,
        now: Date
    ) -> String {
        guard completions.count > 1 else {
            let completion = completions[0]
            let elapsed = elapsedDescription(completion, at: now)
            return singleSentence(
                completion,
                lead: "\(completion.displayName) finished about \(elapsed) ago"
            )
        }
        let scope = workspaceTitle.map { " \($0)" } ?? ""
        let heading = "\(countWord(completions.count))\(scope) lanes are waiting."
        let details = completions.map { completion in
            let elapsed = elapsedDescription(completion, at: now)
            return singleSentence(
                completion,
                lead: "\(completion.displayName) finished about \(elapsed) ago"
            )
        }.joined(separator: " ")
        return "\(heading) \(details)"
    }

    private static func singleSentence(_ completion: PendingCompletion, lead: String) -> String {
        guard let summary = nonemptySummary(completion) else { return lead + "." }
        return "\(lead) — \(ensuringTerminalPunctuation(summary))"
    }

    private static func clause(_ completion: PendingCompletion) -> String {
        guard let summary = nonemptySummary(completion) else { return completion.displayName }
        return "\(completion.displayName) — \(removingTerminalPunctuation(summary))"
    }

    private static func nonemptySummary(_ completion: PendingCompletion) -> String? {
        guard let summary = completion.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else { return nil }
        return summary
    }

    private static func ensuringTerminalPunctuation(_ text: String) -> String {
        guard let last = text.last, ".?!…".contains(last) else { return text + "." }
        return text
    }

    private static func removingTerminalPunctuation(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: ".?!…"))
    }

    private static func countWord(_ count: Int) -> String {
        switch count {
        case 2: return "Two"
        case 3: return "Three"
        case 4: return "Four"
        case 5: return "Five"
        default: return String(count)
        }
    }

    private struct Group {
        let workspaceTitle: String?
        var completions: [PendingCompletion]
    }

    private static func grouped(_ completions: [PendingCompletion]) -> [Group] {
        var result: [Group] = []
        var indexes: [String: Int] = [:]
        for completion in completions {
            let key = completion.workspaceID ?? completion.workspaceTitle ?? ""
            if let index = indexes[key] {
                result[index].completions.append(completion)
            } else {
                indexes[key] = result.count
                result.append(Group(
                    workspaceTitle: completion.workspaceTitle,
                    completions: [completion]
                ))
            }
        }
        return result
    }
}
