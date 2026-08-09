import SwiftUI
import NextUpCore

struct NextUpView: View {
    @ObservedObject var model: WatcherModel

    private var selectedWorkspaces: [WorkspaceInfo] {
        model.workspaces
            .filter { model.isWorkspaceSelected($0.id) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var selectedWorkspaceCount: Int { selectedWorkspaces.count }

    private var inputRequiredCount: Int { model.lanes.filter { $0.state == .inputRequired }.count }
    private var workingCount: Int { model.lanes.filter { $0.state == .busy }.count }
    private var waitingCount: Int { model.lanes.filter { $0.state == .ready }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Next Up").font(.headline)
                    HStack(spacing: 10) {
                        if inputRequiredCount > 0 {
                            statusSummary(color: .red, count: inputRequiredCount, label: "needs input")
                        }
                        statusSummary(color: .orange, count: workingCount, label: "working")
                        statusSummary(color: .green, count: waitingCount, label: "waiting")
                    }
                    Text(model.status).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    workspaceMenu
                    voiceMenu
                    if !model.pending.isEmpty || !model.attentionLaneIDs.isEmpty {
                        Button("Clear Alerts") { model.acknowledgeAll() }
                            .buttonStyle(.borderless)
                    }
                }
            }

            Divider()

            if model.workspaces.isEmpty {
                emptyState("No CMUX workspaces found")
            } else if selectedWorkspaces.isEmpty {
                emptyState("No workspaces selected")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(selectedWorkspaces) { workspace in
                            let workspaceLanes = lanes(in: workspace.id)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(workspace.title).font(.subheadline).bold().lineLimit(1)
                                    Spacer()
                                    Text("\(workspaceLanes.count)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if workspaceLanes.isEmpty {
                                    Text("No terminal lanes")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(workspaceLanes, id: \.id) { lane in
                                        laneRow(lane)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 520)
            }

            Divider()
            HStack {
                Text("Visible pane contents · refreshes every 5 seconds")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .frame(width: 440)
        .frame(minHeight: 600)
    }

    private var workspaceMenu: some View {
        Menu {
            Button {
                model.selectAllWorkspaces()
            } label: {
                Label("Select All", systemImage: "checkmark.circle")
            }
            Divider()
            ForEach(model.workspaces.sorted { $0.title < $1.title }) { workspace in
                Button {
                    model.toggleWorkspace(workspace.id)
                } label: {
                    Label(
                        workspace.title,
                        systemImage: model.isWorkspaceSelected(workspace.id) ? "checkmark.square.fill" : "square"
                    )
                }
            }
        } label: {
            Label("\(selectedWorkspaceCount)/\(model.workspaces.count)", systemImage: "rectangle.stack")
        }
        .menuStyle(.borderlessButton)
        .help("Choose workspaces to watch")
    }

    private var voiceMenu: some View {
        Menu {
            ForEach(VoiceAnnouncementMode.allCases, id: \.self) { mode in
                Button {
                    model.setVoiceMode(mode)
                } label: {
                    Label(
                        mode.displayName,
                        systemImage: model.voiceMode == mode ? "checkmark" : "circle"
                    )
                }
            }
        } label: {
            Label(model.voiceMode.displayName, systemImage: "speaker.wave.2")
        }
        .menuStyle(.borderlessButton)
        .help("Choose spoken announcement detail")
    }

    private func lanes(in workspaceID: String) -> [LaneSnapshot] {
        let workspaceLanes = model.lanes.filter { $0.workspaceID == workspaceID }
        return LaneOrdering.sorted(
            workspaceLanes,
            pendingLaneIDs: Set(model.pending.map(\.laneID)),
            activityDates: Dictionary(uniqueKeysWithValues: workspaceLanes.compactMap { lane in
                model.activityDate(for: lane.id).map { (lane.id, $0) }
            })
        )
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(message).font(.headline)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    @ViewBuilder
    private func laneRow(_ lane: LaneSnapshot) -> some View {
        let completion = model.pending.first { $0.laneID == lane.id }
        HStack(spacing: 10) {
            Circle()
                .fill(color(for: lane.state))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(LaneMonitorState.displayName(from: lane.title)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(label(for: lane.state))
                    if let completion {
                        Text("· ready ") + Text(completion.completedAt, style: .relative)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let summary = completion?.summary {
                    Text(summary)
                        .font(.caption)
                        .lineLimit(1)
                        .help(summary)
                }
            }
            Spacer()
            if completion != nil || lane.state == .inputRequired {
                Button {
                    model.acknowledge(lane.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Mark alert seen")
            }
        }
        .padding(.vertical, 5)
    }

    private func statusSummary(color: Color, count: Int, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(count) \(label)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func color(for state: LaneState) -> Color {
        switch state {
        case .inputRequired: return .red
        case .busy: return .orange
        case .ready: return .green
        case .unknown: return .gray
        }
    }

    private func label(for state: LaneState) -> String {
        switch state {
        case .inputRequired: return "Needs input"
        case .busy: return "Working"
        case .ready: return "Waiting"
        case .unknown: return "State not recognized"
        }
    }

}
