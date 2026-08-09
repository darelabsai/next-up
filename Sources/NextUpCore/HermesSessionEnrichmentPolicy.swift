public enum HermesSessionEnrichmentPolicy {
    public static func eligibleLanes(from lanes: [LaneSnapshot]) -> [LaneSnapshot] {
        lanes.filter { $0.state != .inputRequired }
    }
}
