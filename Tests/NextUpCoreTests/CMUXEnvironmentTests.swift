import Testing
@testable import NextUpCore

@Test func capabilityIsTrimmedAndAddedToChildEnvironment() {
    let result = CMUXEnvironment.applyingCapability("  token-value\n", to: ["HOME": "/tmp/home"])
    #expect(result["HOME"] == "/tmp/home")
    #expect(result["CMUX_SOCKET_CAPABILITY"] == "token-value")
}

@Test func emptyCapabilityDoesNotModifyEnvironment() {
    let base = ["HOME": "/tmp/home"]
    #expect(CMUXEnvironment.applyingCapability(" \n", to: base) == base)
}
