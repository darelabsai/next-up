import Testing
@testable import NextUpCore

private func bordered(_ rows: [String], indent: String = "  ") -> String {
    (["\(indent)╔════════════════════════════════════╗"]
        + rows.map { "\(indent)║ \($0) ║" }
        + ["\(indent)╚════════════════════════════════════╝"])
        .joined(separator: "\n")
}

@Test func approvalMenuRequiresImmediateInput() {
    let screen = """
    ─ ◉ ◉ mulling… · 15m 15s │ gpt 5.6 sol
    ⚠ approval required · execute_code script execution
    1. Allow once
    2. Allow this session
    3. Always allow
    4. Deny
    ↑/↓ select · Enter confirm · 1–4 quick pick · Esc/Ctrl+C deny
    """

    let classification = SurfaceContentClassifier.classification(screen)
    #expect(classification.state == .inputRequired)
    #expect(classification.inputRequestKind == .approval)
}

@Test func clarifyChoiceMenuRequiresImmediateInput() {
    let screen = """
    ask Which scope should I inspect for the read-only disk-space check?
    ▸ 1. Root volume
      2. Home directory
      3. All mounted volumes
      4. Other (type your answer)
    ↑/↓ select · Enter confirm · 1-3 quick pick · Esc/Ctrl+C
    cancel








    ─ ( •_•)>⌐■-■ formulating… · 37s │ gpt 5.6 sol ─ ~
    """

    let classification = SurfaceContentClassifier.classification(screen)
    #expect(classification.state == .inputRequired)
    #expect(classification.inputRequestKind == .clarification)
}

@Test func explicitInputRequiredControlsClassifyAsResponseRequest() {
    let screen = """
    ⚠ input required · continue workflow
    ↑/↓ select · Enter confirm · Esc/Ctrl+C cancel
    """

    let classification = SurfaceContentClassifier.classification(screen)
    #expect(classification.state == .inputRequired)
    #expect(classification.inputRequestKind == .response)
}

@Test func genericInputRequiredAcceptsNineThroughSixteenSuffixRows() {
    let prompt = """
    ⚠ input required · continue workflow
    ↑/↓ select · Enter confirm · Esc/Ctrl+C cancel
    """

    for suffixCount in 9...16 {
        let suffix = (1...suffixCount).map { "composer suffix \($0)" }.joined(separator: "\n")
        let classification = SurfaceContentClassifier.classification(prompt + "\n" + suffix)
        #expect(classification.state == .inputRequired, "Suffix rows: \(suffixCount)")
        #expect(classification.inputRequestKind == .response, "Suffix rows: \(suffixCount)")
    }
}

@Test func negatedApprovalInsideClarifyMenuStaysClarification() {
    let screen = """
    ask No approval required; choose the scope.
    1. Allow cache inspection
    2. Deny cache inspection
    3. Other (type your answer)
    ↑/↓ select · Enter confirm · 1-2 quick pick · Esc/Ctrl+C
    """

    let classification = SurfaceContentClassifier.classification(screen)
    #expect(classification.state == .inputRequired)
    #expect(classification.inputRequestKind == .clarification)
}

@Test func clarifyChoiceNearMissesRequireAskHeadingAndFinalOtherRow() {
    let missingAsk = """
    Choose the scope.
    1. First target
    2. Other (type your answer)
    ↑/↓ select · Enter confirm · 1-2 quick pick · Esc/Ctrl+C cancel
    """
    let missingOther = """
    ask Choose the scope.
    1. First target
    2. Second target
    ↑/↓ select · Enter confirm · 1-2 quick pick · Esc/Ctrl+C cancel
    """

    #expect(SurfaceContentClassifier.classify(missingAsk) == .unknown)
    #expect(SurfaceContentClassifier.classify(missingOther) == .unknown)
}

@Test func permissionHeaderWithCanonicalChoicesWinsOverClarification() {
    let screen = """
    ⚠ permission required · file access
    1. Allow once
    2. Deny
    ↑/↓ select · Enter confirm · 1-2 quick pick · Esc/Ctrl+C deny
    """

    #expect(SurfaceContentClassifier.classification(screen).inputRequestKind == .approval)
}

@Test func actionableHeadersAcceptSpecifiedSeparatorSpacing() {
    for header in [
        "⚠ approval required·details",
        "⚠️ input required · emoji warning",
        "permission required  · details",
        "input required · details",
    ] {
        let screen = """
        \(header)
        ↑/↓ select · Enter confirm · Esc/Ctrl+C
        """
        #expect(SurfaceContentClassifier.classification(screen).state == .inputRequired)
    }
}

@Test func numericQuickPickRequiresPositiveUpperBound() {
    let zero = """
    ⚠ input required · choose
    ↑/↓ select · Enter confirm · 1-0 quick pick
    """
    let positive = """
    ⚠ input required · choose
    ↑/↓ select · Enter confirm · 1-1 quick pick
    """

    #expect(SurfaceContentClassifier.classify(zero) == .unknown)
    #expect(SurfaceContentClassifier.classification(positive).inputRequestKind == .response)
}

@Test func approvalNumberedMenuMustBeOneBasedContiguousAndMatchQuickPickUpperBound() {
    let malformedOptionBlocks = [
        ["2. Allow once", "3. Deny"],
        ["1. Allow once", "3. Deny"],
        ["1. Allow once", "1. Deny"],
        ["1. Allow once", "2. Allow this session", "2. Always allow", "3. Deny"],
    ]

    for options in malformedOptionBlocks {
        let screen = (["⚠ approval required · review probe"] + options + [
            "↑/↓ select · Enter confirm · 1-\(options.count) quick pick · Esc/Ctrl+C deny",
        ]).joined(separator: "\n")
        let classification = SurfaceContentClassifier.classification(screen)
        #expect(classification.state == .unknown, "Options: \(options)")
        #expect(classification.inputRequestKind == nil, "Options: \(options)")
    }

    let wrongUpper = """
    ⚠ approval required · review probe
    1. Allow once
    2. Deny
    ↑/↓ select · Enter confirm · 1-3 quick pick · Esc/Ctrl+C deny
    """
    #expect(SurfaceContentClassifier.classify(wrongUpper) == .unknown)
}

@Test func malformedCanonicalApprovalMenuCannotBypassHeaderFallback() {
    let screen = bordered([
        "⚠ approval required · review probe",
        "1. Allow once", "2. Deny", "2. Allow this session", "3. Deny",
        "↑/↓ select · Enter confirm · 1-4 quick pick · Esc/Ctrl+C deny",
    ])

    let classification = SurfaceContentClassifier.classification(screen)
    #expect(classification.state == .unknown)
    #expect(classification.inputRequestKind == nil)
}

@Test func clarifyMenuRequiresOneBasedContiguousRowsAndSourceQuickPickCount() {
    let skipped = """
    ask Choose a target.
    1. First
    3. Other (type your answer)
    ↑/↓ select · Enter confirm · 1-1 quick pick · Esc/Ctrl+C cancel
    """
    let duplicated = """
    ask Choose a target.
    1. First
    1. Second
    2. Other (type your answer)
    ↑/↓ select · Enter confirm · 1-2 quick pick · Esc/Ctrl+C cancel
    """
    let wrongUpper = """
    ask Choose a target.
    1. First
    2. Second
    3. Other (type your answer)
    ↑/↓ select · Enter confirm · 1-3 quick pick · Esc/Ctrl+C cancel
    """

    for screen in [skipped, duplicated, wrongUpper] {
        let classification = SurfaceContentClassifier.classification(screen)
        #expect(classification.state == .unknown)
        #expect(classification.inputRequestKind == nil)
    }
}

@Test func malformedControlFooterSpacingCannotCorroborateInput() {
    let screen = """
    ⚠ input required · details
    ↑/↓ select·Enter confirm · Esc/Ctrl+C
    """

    let classification = SurfaceContentClassifier.classification(screen)
    #expect(classification.state == .unknown)
    #expect(classification.inputRequestKind == nil)
}

@Test func isolatedPermissionProseWithoutControlsIsNotInputRequired() {
    let screen = """
    permission required was mentioned in the completed report
    ─ ready │ gpt 5.6 sol
    ❯
    """

    let classification = SurfaceContentClassifier.classification(screen)
    #expect(classification.state == .ready)
    #expect(classification.inputRequestKind == nil)
}

@Test func negatedInputHeaderCannotCreateResponseRequest() {
    let screen = """
    No input required
    ↑/↓ select · Enter confirm · Esc/Ctrl+C cancel
    """

    let classification = SurfaceContentClassifier.classification(screen)
    #expect(classification.state == .unknown)
    #expect(classification.inputRequestKind == nil)
}

@Test func negatedPermissionInsideClarifyMenuStaysClarification() {
    let screen = """
    ask No permission required; choose a target.
    1. First target
    2. Other (type your answer)
    ↑/↓ select · Enter confirm · 1-1 quick pick · Esc/Ctrl+C
    """

    #expect(SurfaceContentClassifier.classification(screen).inputRequestKind == .clarification)
}

@Test func proseMentioningControlsDoesNotCorroborateChoices() {
    let screen = """
    1. First result
    2. Second result
    The guide mentions Enter confirm and quick pick in prose.
    ─ ready │ gpt 5.6 sol
    ❯
    """

    let classification = SurfaceContentClassifier.classification(screen)
    #expect(classification.state == .ready)
    #expect(classification.inputRequestKind == nil)
}

@Test func staleApprovalEvidenceBeyondSixteenSuffixRowsHasNoKind() {
    let prompt = """
    ⚠ approval required · stale
    ↑/↓ select · Enter confirm
    """
    let suffix = (1...15).map { "line \($0)" } + [
        "─ ready │ gpt 5.6 sol",
        "❯",
    ]
    let screen = prompt + "\n" + suffix.joined(separator: "\n")

    let classification = SurfaceContentClassifier.classification(screen)
    #expect(classification.state == .ready)
    #expect(classification.inputRequestKind == nil)
}

@Test func ordinaryNumberedProseWithoutChoiceControlsDoesNotRequireInput() {
    let screen = """
    1. Root volume checked
    2. Home directory checked
    ─ ready │ gpt 5.6 sol
    ❯
    """

    #expect(SurfaceContentClassifier.classify(screen) == .ready)
}

@Test func completedProseMentioningApprovalDoesNotRequireInput() {
    let screen = """
    No approval required. The requested change is complete.
    ─ ready │ gpt 5.6 sol
    ❯
    """

    #expect(SurfaceContentClassifier.classify(screen) == .ready)
}

@Test func activeRuminatingStatusOverridesTypedSteeringPrompt() {
    let screen = """
    tool output
    ─ (▰▰) ruminating… · 15m 45s │ gpt 5.6 sol
    ❯ Another issue and this is crucial.
    """

    #expect(SurfaceContentClassifier.classify(screen) == .busy)
}

@Test func processingContentOverridesIdleText() {
    let screen = """
    prior response text
    ─ reasoning… · 4m 1s │ gpt 5.6 sol
    ❯ Ctrl+C to interrupt…
    """

    #expect(SurfaceContentClassifier.classify(screen) == .busy)
}

@Test func explicitReadyStatusIsWaiting() {
    let screen = """
    response complete
    ─ ready │ gpt 5.6 sol │ ✓ 36m
    ❯
    """

    #expect(SurfaceContentClassifier.classify(screen) == .ready)
}

@Test func readyFooterWithTruncatedWorkspaceTitleIsWaiting() {
    let screen = """
    Completed work remains visible above.
    ─ ready │ gpt 5.6 sol │ 145.5k/272k ─ Next Up 2.0 · …xt-up-2 (main)
    ❯
    """

    let classification = SurfaceContentClassifier.classification(screen)
    #expect(classification.state == .ready)
    #expect(classification.inputRequestKind == nil)
}

@Test func idlePromptIsWaitingForPiStyleSurface() {
    let screen = """
    ⚕ gpt-5.6-sol │ 139K/372K │ ✓ 2m
    ───────────────────────────
    ❯
    ───────────────────────────
    [pi-session:python3.11*
    """

    #expect(SurfaceContentClassifier.classify(screen) == .ready)
}

@Test func staleProcessingMarkerAboveBottomStatusDoesNotOverridePrompt() {
    let screen = """
    ─ reasoning… · old status
    line 1
    line 2
    line 3
    line 4
    line 5
    line 6
    line 7
    line 8
    completed response
    ─ ready │ gpt 5.6 sol
    ❯
    """

    #expect(SurfaceContentClassifier.classify(screen) == .ready)
}

@Test func proseContainingPromptGlyphDoesNotCountAsIdlePrompt() {
    let screen = "The guide says: type ❯ to continue."
    #expect(SurfaceContentClassifier.classify(screen) == .unknown)
}

@Test func doubleBorderApprovalUnwrapsPaddingAndBeatsBusyComposerSuffix() {
    let prompt = bordered([
        "⚠ approval required · run command",
        "Run this command?",
        "SAFE_COMMAND_part_01", "SAFE_COMMAND_part_02", "SAFE_COMMAND_part_03",
        "SAFE_COMMAND_part_04", "SAFE_COMMAND_part_05", "SAFE_COMMAND_part_06",
        "SAFE_COMMAND_part_07", "SAFE_COMMAND_part_08", "SAFE_COMMAND_part_09",
        "SAFE_COMMAND_part_10", "… 3 more lines",
        "▸ 1. Allow once", "  2. Allow this session", "  3. Always allow", "  4. Deny",
        "↑/↓ select · Enter confirm · 1–4 quick pick · Esc/Ctrl+C deny",
    ])
    let screen = prompt + "\n\nqueued work\n─ ruminating… · 3s │ gpt 5.6 sol\n❯ typed composer text"

    let result = SurfaceContentClassifier.classification(screen)
    #expect(result.state == .inputRequired)
    #expect(result.inputRequestKind == .approval)
}

@Test func completePromptAtEightyLineBoundaryIsVisibleButClippedPromptFailsClosed() {
    let longDescription = (1...58).map { "caller text row \($0)" }
    let prompt = bordered([
        "⚠ permission required · safe operation",
    ] + longDescription + [
        "1. Allow once", "2. Deny",
        "↑/↓ select · Enter confirm · 1-2 quick pick · Esc/Ctrl+C deny",
    ])
    let exactlyEighty = prompt + "\n" + Array(repeating: "suffix", count: 16).joined(separator: "\n") + "\n"
    #expect(exactlyEighty.split(separator: "\n", omittingEmptySubsequences: false).count == 81)
    #expect(SurfaceContentClassifier.classify(exactlyEighty) == .inputRequired)
    #expect(SurfaceContentClassifier.classify(exactlyEighty + "clipping row\n") != .inputRequired)
}

@Test func clarifyChoicesRequireSourceShapedRowsIncludingOther() {
    let screen = """
    ask Choose a deployment target whose caller supplied question can wrap
    across arbitrary physical lines inside this block without a distance cap.
      1. Staging
    ▸ 2. Production
      3. Other (type your answer)
    ↑/↓ select · Enter confirm · 1-2 quick pick · Esc/Ctrl+C cancel

    ─ ready │ gpt 5.6 sol
    ❯
    """
    let result = SurfaceContentClassifier.classification(screen)
    #expect(result.state == .inputRequired)
    #expect(result.inputRequestKind == .clarification)
}

@Test func clarifyFreeTextRecognizesAskInputAndSendControls() {
    let screen = """
    ask Explain what should happen next; this caller text may wrap
    for as many rows as fit in the complete captured block.
    > a free-form answer
    Enter send · Esc/Ctrl+C cancel
    """
    let result = SurfaceContentClassifier.classification(screen)
    #expect(result.state == .inputRequired)
    #expect(result.inputRequestKind == .clarification)
}

@Test func borderedConfirmUsesTwoAdjacentCallerDefinedChoices() {
    let screen = bordered([
        "Deploy the release?", "This detail is caller supplied.",
        "▸ Allow wording is misleading", "  Deny wording is also caller supplied",
        "↑/↓ select · Enter confirm · Y/N quick · Esc/Ctrl+C cancel",
    ])
    let result = SurfaceContentClassifier.classification(screen)
    #expect(result.state == .inputRequired)
    #expect(result.inputRequestKind == .response)
}

@Test func sudoAndSecretMaskedPromptsAreResponses() {
    let sudoEmpty = " 🔐  sudo password required\n >"
    let sudoMasked = " 🔐  sudo password required\n > *****"
    let secretEmpty = " 🔑  SAFE_SECRET_LABEL\n  for SAFE_SECRET_ENV\n >"
    let secretMasked = " 🔑  SAFE_SECRET_LABEL\n  for SAFE_SECRET_ENV\n > *****"

    for screen in [sudoEmpty, sudoMasked, secretEmpty, secretMasked] {
        #expect(SurfaceContentClassifier.classification(screen).inputRequestKind == .response)
    }
}

@Test func sudoAndSecretRejectCleartextAndCopiedQuoteNearMisses() {
    let nearMisses = [
        " 🔐  sudo password required\n > cleartext-password",
        " 🔐  sudo password required\n > \"*****\"",
        " 🔑  SAFE_SECRET_LABEL\n  for SAFE_SECRET_ENV\n > copied-token",
        " 🔑  SAFE_SECRET_LABEL\n  for SAFE_SECRET_ENV\n > `*****`",
    ]

    for screen in nearMisses {
        let classification = SurfaceContentClassifier.classification(screen)
        #expect(classification.state == .unknown)
        #expect(classification.inputRequestKind == nil)
    }
}

@Test func selectionFooterMayWrapAcrossTwoThreeOrFourPhysicalLines() {
    for footer in [
        ["↑/↓ select · Enter confirm", "· 1-2 quick pick · Esc/Ctrl+C deny"],
        ["↑/↓ select ·", "Enter confirm ·", "1–2 quick pick · Esc/Ctrl+C deny"],
        ["↑/↓ select", "· Enter confirm", "· 1-2 quick pick", "· Esc/Ctrl+C deny"],
    ] {
        let screen = bordered([
            "⚠ approval required · wrapped controls", "1. Allow once", "2. Deny",
        ] + footer)
        #expect(SurfaceContentClassifier.classify(screen) == .inputRequired)
    }
}

@Test func physicallyContinuedFooterBeyondFourLinesFailsClosed() {
    let selection = bordered([
        "⚠ approval required · invalid footer", "1. Allow once", "2. Deny",
        "↑/↓ select", "· Enter confirm", "· 1-2 quick pick", "· Esc/Ctrl+C",
        "deny",
    ])
    let send = """
    ask Explain what should happen.
    > answer
    Enter send
    · wrapped footer detail
    · another wrapped footer detail
    · Esc/Ctrl+C
    cancel
    """

    #expect(SurfaceContentClassifier.classify(selection) == .unknown)
    #expect(SurfaceContentClassifier.classify(send) == .unknown)
}

@Test func reconstructedFooterCharacterCapIncludesInsertedWhitespace() {
    func footer(logicalLength: Int) -> [String] {
        let first = "↑/↓ select · Enter confirm"
        let secondPrefix = "· 1-2 quick pick · Esc/Ctrl+C deny · "
        let fillerCount = logicalLength - first.count - 1 - secondPrefix.count
        return [first, secondPrefix + String(repeating: "x", count: fillerCount)]
    }

    let exact = bordered([
        "⚠ approval required · boundary footer", "1. Allow once", "2. Deny",
    ] + footer(logicalLength: 1_024))
    let over = bordered([
        "⚠ approval required · boundary footer", "1. Allow once", "2. Deny",
    ] + footer(logicalLength: 1_025))

    #expect(SurfaceContentClassifier.classify(exact) == .inputRequired)
    #expect(SurfaceContentClassifier.classify(over) == .unknown)
}

@Test func footerBeyondPhysicalOrCharacterCapFailsClosed() {
    let fiveLines = bordered([
        "⚠ approval required · invalid footer", "1. Allow once", "2. Deny",
        "↑/↓ select", "· Enter", "confirm ·", "1-2 quick", "pick · Esc/Ctrl+C deny",
    ])
    let oversized = bordered([
        "⚠ approval required · invalid footer", "1. Allow once", "2. Deny",
        "↑/↓ select · Enter confirm · 1-2 quick pick · " + String(repeating: "x", count: 1_025),
    ])
    #expect(SurfaceContentClassifier.classify(fiveLines) == .unknown)
    #expect(SurfaceContentClassifier.classify(oversized) == .unknown)
}

@Test func arbitraryCallerTextWrappingWithinCompleteBorderDoesNotBreakApproval() {
    let description = (1...24).map { "caller description physical row \($0)" }
    let screen = bordered(["⚠ approval required · operation"] + description + [
        "1. Allow once", "2. Deny",
        "↑/↓ select · Enter confirm · 1-2 quick pick · Esc/Ctrl+C deny",
    ])
    #expect(SurfaceContentClassifier.classify(screen) == .inputRequired)
}

@Test func moreThanSixteenComposerSuffixRowsInvalidatePrompt() {
    let prompt = bordered([
        "⚠ approval required · operation", "1. Allow once", "2. Deny",
        "↑/↓ select · Enter confirm · 1-2 quick pick · Esc/Ctrl+C deny",
    ])
    let screen = prompt + "\n" + Array(repeating: "composer suffix", count: 17).joined(separator: "\n") + "\n─ ready │ model\n❯"
    #expect(SurfaceContentClassifier.classify(screen) == .ready)
}

@Test func partialAndProseNearMissesDeferToCurrentComposer() {
    let screens = [
        "⚠ approval required · incomplete\n1. Allow once\n─ ready │ model\n❯",
        "1. Allow once\n2. Deny\n↑/↓ select · Enter confirm · 1-2 quick pick\n─ reasoning… · 1s │ model",
        "The transcript says ↑/↓ select · Enter confirm · 1-2 quick pick.\n─ ready │ model\n❯",
        "ask copied question\n> copied answer without send controls\n─ ready │ model\n❯",
    ]
    #expect(SurfaceContentClassifier.classify(screens[0]) == .ready)
    #expect(SurfaceContentClassifier.classify(screens[1]) == .busy)
    #expect(SurfaceContentClassifier.classify(screens[2]) == .ready)
    #expect(SurfaceContentClassifier.classify(screens[3]) == .ready)
}

@Test func exactVisibleCellReproductionIsObservationallyInputRequired() {
    let reproducedTranscript = bordered([
        "⚠ permission required · byte-equivalent copied surface",
        "1. Allow once", "2. Deny",
        "↑/↓ select · Enter confirm · 1-2 quick pick · Esc/Ctrl+C deny",
    ]) + "\n\n─ ready │ model\n❯"
    #expect(SurfaceContentClassifier.classify(reproducedTranscript) == .inputRequired)
}
