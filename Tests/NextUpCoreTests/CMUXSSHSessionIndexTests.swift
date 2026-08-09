import Testing
@testable import NextUpCore

@Test func routesRetainedSSHSurfaceToMacMini() {
    let sessions = """
    workspace:6 SC (MacMini) ssh-EA5221DE-7C1F-497B-BAC8-EE000045E3A2-1EEB9D45-46B5-4CD0-A103-91553C348F08 attachments=1
    """
    let remote = LaneSnapshot(
        id: "surface:55", persistentID: "1EEB9D45-46B5-4CD0-A103-91553C348F08",
        title: "Remote", state: .ready,
        workspaceID: "workspace:6",
        workspacePersistentID: "EA5221DE-7C1F-497B-BAC8-EE000045E3A2"
    )
    let local = LaneSnapshot(
        id: "surface:1", persistentID: "7347D759-0FE8-4424-823D-E34D44E226D5",
        title: "Local", state: .ready,
        workspaceID: "workspace:1",
        workspacePersistentID: "9C9FF59F-D597-4496-B379-6C3B4A74A24A"
    )

    #expect(CMUXSSHSessionIndex.machine(for: remote, inventory: sessions) == "mac-mini")
    #expect(CMUXSSHSessionIndex.machine(for: local, inventory: sessions) == "mac-air")
}

@Test func incompletePersistentIdentityFailsClosedToLocal() {
    let lane = LaneSnapshot(id: "surface:55", title: "Unknown", state: .ready)

    #expect(CMUXSSHSessionIndex.machine(for: lane, inventory: "ssh-anything") == "mac-air")
}

@Test func retainedSSHIdentityRequiresAnExactInventoryField() {
    let lane = LaneSnapshot(
        id: "surface:55", persistentID: "SURFACE-ID",
        title: "Remote", state: .ready,
        workspaceID: "workspace:6", workspacePersistentID: "WORKSPACE-ID"
    )
    let colliding = "workspace:6 Remote ssh-WORKSPACE-ID-SURFACE-ID-extra attachments=1"

    #expect(CMUXSSHSessionIndex.machine(for: lane, inventory: colliding) == "mac-air")
}
