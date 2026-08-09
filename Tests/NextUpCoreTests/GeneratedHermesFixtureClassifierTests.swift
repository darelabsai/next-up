import Foundation
import Testing
@testable import NextUpCore

private struct HermesFixtureManifest: Decodable {
    let schemaVersion: Int
    let incidentExactClassification: String
    let fixtureRows: Int
    let fixtures: [HermesFixture]
}

private struct HermesFixture: Decodable {
    let file: String
    let rows: Int
    let titleWarningPresent: Bool
    let expectedState: LaneState
    let expectedKind: ManifestInputKind?
    let privacySafeScenario: String
    let notes: String
}

private enum ManifestInputKind: String, Decodable {
    case approval
    case clarification
    case confirmation
    case secret
    case sudo

    var classifierKind: InputRequestKind {
        switch self {
        case .approval:
            .approval
        case .clarification:
            .clarification
        case .confirmation, .secret, .sudo:
            .response
        }
    }
}

private enum HermesFixtureResources {
    static let subdirectory = "Fixtures/HermesInput"
    static let forbiddenIncidentPhrases = [
        "PRIVACY_SENTINEL_DO_NOT_RENDER_7",
        "SENSITIVE_COMMAND_DO_NOT_RENDER",
        "REAL_SECRET_DO_NOT_RENDER",
    ]
    static let forbiddenContentPatterns = [
        #"/(?:Users|home)/[A-Za-z0-9._-]+"#,
        #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
        #"\b(?:sk|ghp|github_pat|xox[baprs])-[_A-Za-z0-9-]{12,}\b"#,
    ]

    static func manifest() throws -> HermesFixtureManifest {
        let url = try #require(Bundle.module.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: subdirectory
        ))
        return try JSONDecoder().decode(HermesFixtureManifest.self, from: Data(contentsOf: url))
    }

    static func contents(of fixture: HermesFixture) throws -> String {
        let url = try #require(Bundle.module.url(
            forResource: fixture.file,
            withExtension: nil,
            subdirectory: subdirectory
        ))
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func physicalRows(in contents: String) -> [Substring] {
        var rows = contents.split(separator: "\n", omittingEmptySubsequences: false)
        if contents.hasSuffix("\n") {
            rows.removeLast()
        }
        return rows
    }

}

@Test func emptyInputFixturesPreserveSourceRenderedCursorArtifactAndClassify() throws {
    let manifest = try HermesFixtureResources.manifest()
    let expected: [String: ManifestInputKind] = [
        "sudo-empty-cursor.txt": .sudo,
        "secret-empty-cursor.txt": .secret,
        "clarify-free-text-empty-cursor.txt": .clarification,
    ]

    for (file, kind) in expected {
        let fixture = try #require(manifest.fixtures.first { $0.file == file })
        let contents = try HermesFixtureResources.contents(of: fixture)
        #expect(contents.contains(" > █\n"), "Fixture: \(file)")
        #expect(fixture.notes.contains("source-rendered inverse-styled cursor cell"), "Fixture: \(file)")
        let classification = SurfaceContentClassifier.classification(
            contents,
            titleHasWarningHint: fixture.titleWarningPresent
        )
        #expect(classification.state == .inputRequired, "Fixture: \(file)")
        #expect(classification.inputRequestKind == kind.classifierKind, "Fixture: \(file)")
    }
}

@Test func everyGeneratedHermesFixtureMatchesManifestClassification() throws {
    let manifest = try HermesFixtureResources.manifest()
    #expect(manifest.schemaVersion == 1)
    #expect(!manifest.fixtures.isEmpty)

    for fixture in manifest.fixtures {
        let contents = try HermesFixtureResources.contents(of: fixture)
        let classification = SurfaceContentClassifier.classification(
            contents,
            titleHasWarningHint: fixture.titleWarningPresent
        )
        #expect(classification.state == fixture.expectedState, "Fixture: \(fixture.file)")
        #expect(
            classification.inputRequestKind == fixture.expectedKind?.classifierKind,
            "Fixture: \(fixture.file)"
        )
    }
}

@Test func generatedHermesFixtureManifestCoversAllBoundedPrivacyNeutralFiles() throws {
    let manifest = try HermesFixtureResources.manifest()
    #expect(manifest.incidentExactClassification == "unproven")
    #expect(manifest.fixtureRows == 80)

    let directory = try #require(Bundle.module.url(
        forResource: "HermesInput",
        withExtension: nil,
        subdirectory: "Fixtures"
    ))
    let resourceFiles = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "txt" }
    .map(\.lastPathComponent)
    let manifestFiles = manifest.fixtures.map(\.file)

    #expect(Set(manifestFiles).count == manifestFiles.count)
    #expect(Set(manifestFiles) == Set(resourceFiles))

    let substantialEnvironmentValues = Set(
        ProcessInfo.processInfo.environment.values.filter { $0.count >= 12 }
    )

    for fixture in manifest.fixtures {
        let contents = try HermesFixtureResources.contents(of: fixture)
        #expect(fixture.rows == manifest.fixtureRows, "Fixture: \(fixture.file)")
        #expect(
            HermesFixtureResources.physicalRows(in: contents).count == fixture.rows,
            "Fixture: \(fixture.file)"
        )
        #expect(
            fixture.privacySafeScenario == String(fixture.file.dropLast(".txt".count)),
            "Fixture: \(fixture.file)"
        )

        for phrase in HermesFixtureResources.forbiddenIncidentPhrases {
            #expect(!contents.contains(phrase), "Fixture: \(fixture.file); phrase: \(phrase)")
        }
        for pattern in HermesFixtureResources.forbiddenContentPatterns {
            #expect(
                contents.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil,
                "Fixture: \(fixture.file); privacy pattern: \(pattern)"
            )
        }
        for value in substantialEnvironmentValues {
            #expect(!contents.contains(value), "Fixture: \(fixture.file); environment value leaked")
        }
    }
}
