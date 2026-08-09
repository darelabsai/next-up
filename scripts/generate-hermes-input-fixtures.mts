#!/usr/bin/env node

/**
 * Source-rendered Hermes blocked-input fixture generator (Revision 7).
 *
 * This script deliberately imports the pinned Hermes source tree rather than
 * copying prompt markup. Run it from ui-tui with tsx after npm ci/build:ink;
 * the exact command is documented in the generated README.
 */

import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { lstat, mkdir, readFile, readdir, realpath, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { dirname, join, parse, resolve, sep } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const GENERATOR_VERSION = 'revision-8-source-render-v1'
const BOOTSTRAP_COMMAND_VERSION = 'revision-7-pinned-bootstrap-v1'
const ROWS = 80
const OUTPUT_MARKER = '.next-up-hermes-input-fixtures'
const OUTPUT_MARKER_CONTENT = 'Next Up generated Hermes input fixtures v1\n'
const HERMES_REVISION = 'c5d37bb95cf7a932d644eb2811f57a7f00b9f670'
const LOCK_HASH = 'f75555da8d603ce69bf83dd68dc225ff8d924e2af44b1752712a5a0b673e5039'
const COMPONENT_HASHES = {
  'ui-tui/src/components/appLayout.tsx': '7e589c39e27e5689e087a68dc2192c06f7655f23f8e86503eacfa42f74eceed5',
  'ui-tui/src/components/appOverlays.tsx': '991fc9ad305e6bce0679b1b539a8ee1ea2259e022e807b0c5e4680bdff24074e',
  'ui-tui/src/components/maskedPrompt.tsx': '1c68fb629411cab75f5afc959838a63bd8da5d139f4d5d079f482bfca2f49ba7',
  'ui-tui/src/components/prompts.tsx': '0a955bdadd88057e3825c4cd1e30db9089965e0a62567b4affe32d075b5f1524',
  'ui-tui/src/components/queuedMessages.tsx': '2707e1934e8a5c51335a5401361c85e39e5f7f177439c0a64faef3586f916f26'
} as const
const FORBIDDEN_SENTINELS = [
  'PRIVACY_SENTINEL_DO_NOT_RENDER_7',
  'SENSITIVE_COMMAND_DO_NOT_RENDER',
  'REAL_SECRET_DO_NOT_RENDER'
]

interface Args {
  hermesRoot: string
  output: string
}

type ExpectedState = 'busy' | 'inputRequired' | 'ready' | 'unknown'
type ExpectedKind = 'approval' | 'clarification' | 'confirmation' | 'secret' | 'sudo' | null
type OverlayKind = 'approval' | 'clarifyChoices' | 'clarifyFreeText' | 'confirm' | 'none' | 'secret' | 'sudo'
type Completeness = 'complete' | 'partial' | 'reproduction'
type FooterDash = 'ascii' | 'en'
type MaskMode = 'empty' | 'entered'

interface Scenario {
  name: string
  columns: number
  overlayKind: OverlayKind
  expectedState: ExpectedState
  expectedKind: ExpectedKind
  completeness: Completeness
  titleWarning: boolean
  sourceOptionCount: number | null
  description?: string
  command?: string
  choices?: string[]
  question?: string
  confirmTitle?: string
  confirmDetail?: string
  cancelLabel?: string
  confirmLabel?: string
  secretPrompt?: string
  secretEnvVar?: string
  busy?: boolean
  queueCount?: number
  statusBar?: 'bottom' | 'off' | 'top'
  sticky?: boolean
  backgroundTask?: boolean
  footerDash?: FooterDash
  maskMode?: MaskMode
  transform?: 'complete-reproduction' | 'controls-only' | 'header-offscreen' | 'header-only' | 'selected-other' | 'stale-partial'
  notes?: string
}

interface ManifestRecord {
  file: string
  generatorVersion: string
  bootstrapCommandVersion: string
  hermesRevision: string
  lockfileSha256: string
  componentSha256: typeof COMPONENT_HASHES
  columns: number
  rows: 80
  overlayKind: OverlayKind
  sourceOptionCount: number | null
  titleWarningPresent: boolean
  expectedState: ExpectedState
  expectedKind: ExpectedKind
  completeness: Completeness
  privacySafeScenario: string
  notes: string
  sha256: string
}

function parseArgs(argv: string[]): Args {
  let hermesRoot = ''
  let output = ''

  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--hermes-root') hermesRoot = argv[++i] ?? ''
    else if (argv[i] === '--output') output = argv[++i] ?? ''
    else throw new Error(`unknown argument: ${argv[i]}`)
  }

  if (!hermesRoot || !output) {
    throw new Error('usage: generate-hermes-input-fixtures.mts --hermes-root PATH --output PATH')
  }

  return { hermesRoot: resolve(hermesRoot), output: resolve(output) }
}

function assertSafeOutput(args: Args): void {
  const nextUpRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
  const requiredSuffix = join('Tests', 'NextUpCoreTests', 'Fixtures', 'HermesInput')
  const forbidden = new Set([
    parse(args.output).root,
    resolve(homedir()),
    nextUpRoot,
    args.hermesRoot
  ])
  if (!args.output.endsWith(`${sep}${requiredSuffix}`) || forbidden.has(args.output)) {
    throw new Error(
      `refusing destructive output path: ${args.output}; destination must end in ${requiredSuffix}`
    )
  }
}

async function prepareSafeOutput(output: string, allowedNames: Set<string>): Promise<void> {
  await mkdir(output, { recursive: true })
  if ((await lstat(output)).isSymbolicLink()) {
    throw new Error(`refusing symlink output directory: ${output}`)
  }
  const requiredSuffix = join('Tests', 'NextUpCoreTests', 'Fixtures', 'HermesInput')
  const canonicalOutput = await realpath(output)
  if (!canonicalOutput.endsWith(`${sep}${requiredSuffix}`)) {
    throw new Error(`refusing canonical output path: ${canonicalOutput}`)
  }
  const entries = await readdir(output)
  if (entries.length > 0) {
    const markerPath = join(output, OUTPUT_MARKER)
    let markerInfo
    try {
      markerInfo = await lstat(markerPath)
    } catch {
      throw new Error(`refusing unmarked nonempty output directory: ${output}`)
    }
    if (markerInfo.isSymbolicLink() || !markerInfo.isFile()) {
      throw new Error(`refusing nonregular output marker: ${markerPath}`)
    }
    if (await readFile(markerPath, 'utf8') !== OUTPUT_MARKER_CONTENT) {
      throw new Error(`refusing invalid output marker: ${markerPath}`)
    }
    for (const entry of entries) {
      const entryPath = join(output, entry)
      const info = await lstat(entryPath)
      if (!allowedNames.has(entry) || info.isSymbolicLink() || !info.isFile()) {
        throw new Error(`refusing unexpected output entry: ${entryPath}`)
      }
    }
  } else {
    await writeFile(join(output, OUTPUT_MARKER), OUTPUT_MARKER_CONTENT, 'utf8')
  }
}

const sha256 = (value: string | Buffer) => createHash('sha256').update(value).digest('hex')

async function sha256File(path: string): Promise<string> {
  return sha256(await readFile(path))
}

function git(root: string, args: string[]): string {
  return execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trim()
}

async function verifyHermesSource(root: string): Promise<void> {
  const head = git(root, ['rev-parse', 'HEAD'])
  if (head !== HERMES_REVISION) throw new Error(`Hermes HEAD mismatch: expected ${HERMES_REVISION}, got ${head}`)

  const dirty = git(root, ['status', '--porcelain', '--', 'ui-tui', 'package-lock.json'])
  if (dirty) throw new Error(`Hermes ui-tui/package-lock.json must be clean:\n${dirty}`)

  const lock = await sha256File(join(root, 'package-lock.json'))
  if (lock !== LOCK_HASH) throw new Error(`package-lock.json SHA-256 mismatch: ${lock}`)

  for (const [relativePath, expected] of Object.entries(COMPONENT_HASHES)) {
    const actual = await sha256File(join(root, relativePath))
    if (actual !== expected) throw new Error(`${relativePath} SHA-256 mismatch: ${actual}`)
  }

  const inkEntry = join(root, 'ui-tui/packages/hermes-ink/dist/entry-exports.js')
  try {
    await readFile(inkEntry)
  } catch {
    throw new Error(`missing ${inkEntry}; run npm run build:ink --prefix ui-tui first`)
  }
}

function repeated(prefix: string, count: number): string {
  return Array.from({ length: count }, (_, index) => `${prefix}_${String(index + 1).padStart(2, '0')}`).join(' ')
}

function longCommand(lines = 14): string {
  return Array.from({ length: lines }, (_, index) => `SAFE_COMMAND_${String(index + 1).padStart(2, '0')}_${'X'.repeat(56)}`).join('\n')
}

function scenarios(): Scenario[] {
  const baseApproval = {
    overlayKind: 'approval' as const,
    expectedState: 'inputRequired' as const,
    expectedKind: 'approval' as const,
    completeness: 'complete' as const,
    titleWarning: true
  }

  return [
    { ...baseApproval, name: 'approval-long-double-border-2-options', columns: 80, sourceOptionCount: 2, command: longCommand(14), description: 'SAFE_APPROVAL_DESCRIPTION', choices: ['once', 'deny'], queueCount: 7, backgroundTask: true, sticky: true, statusBar: 'bottom', busy: true, notes: 'Screenshot-shaped approval: double border, ten preview rows, overflow marker, maximal standard ComposerPane suffix.' },
    { ...baseApproval, name: 'approval-3-options-ascii-range-footer-2-lines', columns: 64, sourceOptionCount: 3, command: longCommand(3), description: 'SAFE_APPROVAL_DESCRIPTION', choices: ['once', 'session', 'deny'], footerDash: 'ascii', notes: 'Three-option source variant with ASCII 1-N range and wrapped footer.' },
    { ...baseApproval, name: 'approval-4-options-en-range-footer-3-lines', columns: 32, sourceOptionCount: 4, command: longCommand(2), description: 'SAFE_APPROVAL_DESCRIPTION', choices: ['once', 'session', 'always', 'deny'], footerDash: 'en', notes: 'Four-option narrow source variant; source-cell footer range is normalized to the accepted en dash variant.' },
    { ...baseApproval, name: 'approval-wide-footer', columns: 120, sourceOptionCount: 4, command: 'SAFE_COMMAND_WIDE', description: 'SAFE_APPROVAL_DESCRIPTION', choices: ['once', 'session', 'always', 'deny'], notes: 'Wide complete approval.' },
    { ...baseApproval, name: 'approval-description-wrap-13', columns: 64, sourceOptionCount: 2, command: 'SAFE_COMMAND_DESC_13', description: repeated('SAFE_DESCRIPTION', 25), choices: ['once', 'deny'], notes: 'Caller-defined Approval description rendered to exactly 13 physical rows.' },
    { ...baseApproval, name: 'approval-description-wrap-14', columns: 64, sourceOptionCount: 3, command: 'SAFE_COMMAND_DESC_14', description: repeated('SAFE_DESCRIPTION', 27), choices: ['once', 'session', 'deny'], notes: 'Caller-defined Approval description rendered to exactly 14 physical rows.' },
    { ...baseApproval, name: 'approval-description-wrap-15', columns: 64, sourceOptionCount: 4, command: 'SAFE_COMMAND_DESC_15', description: repeated('SAFE_DESCRIPTION', 29), choices: ['once', 'session', 'always', 'deny'], notes: 'Caller-defined Approval description rendered to exactly 15 physical rows.' },
    { ...baseApproval, name: 'approval-overlay-before-title', columns: 80, sourceOptionCount: 4, command: 'SAFE_COMMAND_OVERLAY_FIRST', description: 'SAFE_APPROVAL_DESCRIPTION', choices: ['once', 'session', 'always', 'deny'], titleWarning: false, notes: 'Complete visible overlay is authoritative before the terminal title changes.' },
    { ...baseApproval, name: 'approval-busy-underlay', columns: 100, sourceOptionCount: 4, command: 'SAFE_COMMAND_BUSY_UNDERLAY', description: 'SAFE_APPROVAL_DESCRIPTION', choices: ['once', 'session', 'always', 'deny'], busy: true, statusBar: 'top', notes: 'Complete active prompt followed by busy-looking source-rendered ComposerPane/status.' },
    { ...baseApproval, name: 'approval-truncated-header-offscreen', columns: 48, sourceOptionCount: 4, command: longCommand(14), description: 'SAFE_APPROVAL_DESCRIPTION', choices: ['once', 'session', 'always', 'deny'], completeness: 'partial', transform: 'header-offscreen', notes: 'Top-clipped source-cell capture: header/opening border are offscreen while canonical rows, footer, closing border, and ComposerPane suffix remain.' },
    { ...baseApproval, name: 'approval-header-before-controls-partial', columns: 80, sourceOptionCount: 4, command: longCommand(3), description: 'SAFE_APPROVAL_DESCRIPTION', choices: ['once', 'session', 'always', 'deny'], expectedState: 'busy', expectedKind: null, completeness: 'partial', transform: 'header-only', busy: true, notes: 'Race-shaped partial containing source-rendered header/preview but no selection rows/footer.' },
    { ...baseApproval, name: 'approval-controls-before-header-partial', columns: 80, sourceOptionCount: 4, command: longCommand(3), description: 'SAFE_APPROVAL_DESCRIPTION', choices: ['once', 'session', 'always', 'deny'], expectedState: 'ready', expectedKind: null, completeness: 'partial', transform: 'controls-only', notes: 'Race-shaped partial containing source-rendered controls but no header/preview.' },

    { name: 'clarify-one-choice', columns: 80, overlayKind: 'clarifyChoices', expectedState: 'inputRequired', expectedKind: 'clarification', completeness: 'complete', titleWarning: true, sourceOptionCount: 1, question: 'SAFE_QUESTION_ONE', choices: ['SAFE_CHOICE_ONE'], notes: 'Clarify with one caller choice plus Other.' },
    { name: 'clarify-many-choices-narrow', columns: 40, overlayKind: 'clarifyChoices', expectedState: 'inputRequired', expectedKind: 'clarification', completeness: 'complete', titleWarning: true, sourceOptionCount: 6, question: 'SAFE_QUESTION_MANY', choices: Array.from({ length: 6 }, (_, i) => `SAFE_CHOICE_${i + 1}`), notes: 'Many-choice Clarify with all numbered source rows and Other.' },
    { name: 'clarify-selected-other', columns: 64, overlayKind: 'clarifyChoices', expectedState: 'inputRequired', expectedKind: 'clarification', completeness: 'complete', titleWarning: true, sourceOptionCount: 3, question: 'SAFE_QUESTION_SELECTED_OTHER', choices: ['SAFE_CHOICE_A', 'SAFE_CHOICE_B', 'SAFE_CHOICE_C'], transform: 'selected-other', notes: 'Selected Other row, derived only by moving the source-rendered selection marker between source rows.' },
    { name: 'clarify-free-text-empty-cursor', columns: 80, overlayKind: 'clarifyFreeText', expectedState: 'inputRequired', expectedKind: 'clarification', completeness: 'complete', titleWarning: true, sourceOptionCount: 0, question: 'SAFE_QUESTION_FREE_TEXT', choices: [], notes: 'Free-text Clarify; the source-rendered inverse-styled cursor cell is encoded as █ in the plain-text fixture.' },
    { name: 'clarify-free-text-footer-4-lines', columns: 24, overlayKind: 'clarifyFreeText', expectedState: 'inputRequired', expectedKind: 'clarification', completeness: 'complete', titleWarning: true, sourceOptionCount: 0, question: 'SAFE_QUESTION_NARROW', choices: [], notes: 'Free-text Clarify whose complete Enter-send footer occupies four physical rows.' },
    ...[7, 8, 9].map((rows): Scenario => ({ name: `clarify-question-wrap-${rows}`, columns: 48, overlayKind: 'clarifyFreeText', expectedState: 'inputRequired', expectedKind: 'clarification', completeness: 'complete', titleWarning: true, sourceOptionCount: 0, question: repeated('SAFE_QUESTION', rows * 2 - 1), choices: [], notes: `Caller-defined Clarify question rendered to exactly ${rows} physical rows.` })),

    { name: 'confirm-custom-misleading-labels', columns: 80, overlayKind: 'confirm', expectedState: 'inputRequired', expectedKind: 'confirmation', completeness: 'complete', titleWarning: false, sourceOptionCount: 2, confirmTitle: 'SAFE_CONFIRM_TITLE', confirmDetail: repeated('SAFE_CONFIRM_DETAIL', 8), cancelLabel: 'Allow SAFE cancellation', confirmLabel: 'Deny SAFE cancellation', notes: 'Exactly two adjacent custom rows whose misleading Allow/Deny words must remain Confirm.' },
    { name: 'confirm-narrow-wrap', columns: 48, overlayKind: 'confirm', expectedState: 'inputRequired', expectedKind: 'confirmation', completeness: 'complete', titleWarning: false, sourceOptionCount: 2, confirmTitle: repeated('SAFE_CONFIRM_TITLE', 8), confirmDetail: repeated('SAFE_CONFIRM_DETAIL', 12), cancelLabel: 'SAFE_CANCEL', confirmLabel: 'SAFE_CONFIRM', notes: 'Narrow Confirm with wrapped caller title/detail and source footer.' },

    { name: 'sudo-empty-cursor', columns: 80, overlayKind: 'sudo', expectedState: 'inputRequired', expectedKind: 'sudo', completeness: 'complete', titleWarning: true, sourceOptionCount: null, maskMode: 'empty', notes: 'Canonical sudo heading; the source-rendered inverse-styled cursor cell is encoded as █ in the plain-text fixture.' },
    { name: 'sudo-entered-mask-narrow', columns: 48, overlayKind: 'sudo', expectedState: 'inputRequired', expectedKind: 'sudo', completeness: 'complete', titleWarning: true, sourceOptionCount: null, maskMode: 'entered', notes: 'Narrow sudo prompt; five mask cells are inserted into the source-rendered input row without any secret value.' },
    { name: 'secret-empty-cursor', columns: 80, overlayKind: 'secret', expectedState: 'inputRequired', expectedKind: 'secret', completeness: 'complete', titleWarning: true, sourceOptionCount: null, secretPrompt: 'SAFE_SECRET_LABEL', secretEnvVar: 'SAFE_SECRET_ENV', maskMode: 'empty', notes: 'Secret heading/sub-row; the source-rendered inverse-styled cursor cell is encoded as █ in the plain-text fixture.' },
    { name: 'secret-entered-mask-narrow', columns: 48, overlayKind: 'secret', expectedState: 'inputRequired', expectedKind: 'secret', completeness: 'complete', titleWarning: true, sourceOptionCount: null, secretPrompt: repeated('SAFE_SECRET_LABEL', 9), secretEnvVar: repeated('SAFE_SECRET_ENV', 9), maskMode: 'entered', notes: 'Narrow entered secret mask with long wrapped label/sub-row.' },
    ...[7, 8, 9].map((rows): Scenario => ({ name: `secret-label-subrow-wrap-${rows}`, columns: 48, overlayKind: 'secret', expectedState: 'inputRequired', expectedKind: 'secret', completeness: 'complete', titleWarning: true, sourceOptionCount: null, secretPrompt: repeated('SAFE_SECRET_LABEL', rows * 2), secretEnvVar: repeated('SAFE_SECRET_ENV', rows * 2), notes: `Secret label and for-sub-row long-wrap ${rows}-row target family.` })),

    { name: 'title-warning-before-overlay', columns: 80, overlayKind: 'none', expectedState: 'busy', expectedKind: null, completeness: 'partial', titleWarning: true, sourceOptionCount: null, busy: true, notes: 'Warning title hint with no visible overlay; screen remains lower precedence.' },
    { name: 'stale-partial-above-busy', columns: 80, overlayKind: 'none', expectedState: 'busy', expectedKind: null, completeness: 'reproduction', titleWarning: false, sourceOptionCount: null, busy: true, transform: 'stale-partial', notes: 'Stale partial bordered/footer prose in transcript above a current busy ComposerPane.' },
    { name: 'stale-partial-above-ready', columns: 80, overlayKind: 'none', expectedState: 'ready', expectedKind: null, completeness: 'reproduction', titleWarning: false, sourceOptionCount: null, busy: false, transform: 'stale-partial', notes: 'Stale partial bordered/footer prose in transcript above a current ready ComposerPane.' },
    { ...baseApproval, name: 'complete-byte-equivalent-reproduction-limit', columns: 80, sourceOptionCount: 4, command: 'SAFE_COMMAND_REPRODUCTION', description: 'SAFE_APPROVAL_DESCRIPTION', choices: ['once', 'session', 'always', 'deny'], completeness: 'reproduction', transform: 'complete-reproduction', notes: 'Expected input-required visible-cell limitation: source prompt cells reproduced above an accepted source ComposerPane suffix are observationally indistinguishable from an active overlay.' }
  ]
}

function safeQueue(count: number): string[] {
  return Array.from({ length: count }, (_, i) => `SAFE_QUEUE_${String(i + 1).padStart(2, '0')}`)
}

function noop() {}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2))
  assertSafeOutput(args)
  await verifyHermesSource(args.hermesRoot)

  // Make AppLayout use its normal flex-column shell without requiring a live
  // alternate terminal. This must be set before importing config/env.ts.
  process.env.HERMES_TUI_INLINE = '1'
  process.env.HERMES_TUI_FPS = '0'
  process.env.HERMES_TUI_DISABLE_MOUSE = '1'
  // Busy status copy/face selection is intentionally playful in production;
  // fixtures pin its entropy so source-rendered ComposerPane rows regenerate
  // byte-for-byte.
  Math.random = () => 0.5

  const uiRoot = join(args.hermesRoot, 'ui-tui')
  const dynamicImport = (path: string) => import(pathToFileURL(path).href)
  const React = await dynamicImport(join(args.hermesRoot, 'node_modules/react/index.js')) as any
  const ink = await dynamicImport(join(uiRoot, 'packages/hermes-ink/dist/entry-exports.js')) as any
  const { renderToScreen } = await dynamicImport(join(uiRoot, 'packages/hermes-ink/src/ink/render-to-screen.ts')) as any
  const { cellAtIndex } = await dynamicImport(join(uiRoot, 'packages/hermes-ink/src/ink/screen.ts')) as any
  const { AppLayout } = await dynamicImport(join(uiRoot, 'src/components/appLayout.tsx')) as any
  const { GatewayProvider } = await dynamicImport(join(uiRoot, 'src/app/gatewayContext.tsx')) as any
  const overlayStore = await dynamicImport(join(uiRoot, 'src/app/overlayStore.ts')) as any
  const uiStore = await dynamicImport(join(uiRoot, 'src/app/uiStore.ts')) as any

  const render = (scenario: Scenario, forceNoOverlay = false): string[] => {
    overlayStore.resetOverlayState()
    uiStore.resetUiState()

    const overlay: Record<string, unknown> = {}
    if (!forceNoOverlay) {
      if (scenario.overlayKind === 'approval') {
        overlay.approval = { command: scenario.command ?? 'SAFE_COMMAND', description: scenario.description ?? 'SAFE_APPROVAL_DESCRIPTION', choices: scenario.choices }
      } else if (scenario.overlayKind === 'clarifyChoices' || scenario.overlayKind === 'clarifyFreeText') {
        overlay.clarify = { requestId: 'SAFE_REQUEST_ID', question: scenario.question ?? 'SAFE_QUESTION', choices: scenario.overlayKind === 'clarifyFreeText' ? null : scenario.choices ?? [] }
      } else if (scenario.overlayKind === 'confirm') {
        overlay.confirm = { title: scenario.confirmTitle ?? 'SAFE_CONFIRM_TITLE', detail: scenario.confirmDetail, cancelLabel: scenario.cancelLabel, confirmLabel: scenario.confirmLabel, onConfirm: noop }
      } else if (scenario.overlayKind === 'sudo') {
        overlay.sudo = { requestId: 'SAFE_REQUEST_ID' }
      } else if (scenario.overlayKind === 'secret') {
        overlay.secret = { requestId: 'SAFE_REQUEST_ID', prompt: scenario.secretPrompt ?? 'SAFE_SECRET_LABEL', envVar: scenario.secretEnvVar ?? 'SAFE_SECRET_ENV' }
      }
    }
    overlayStore.patchOverlayState(overlay)

    uiStore.patchUiState({
      bgTasks: scenario.backgroundTask ? new Set(['SAFE_BACKGROUND_TASK']) : new Set(),
      busy: scenario.busy ?? false,
      info: { model: 'SAFE_MODEL', profile_name: 'SAFE_PROFILE', skills: {}, tools: {} },
      sid: 'SAFE_SESSION_ID',
      status: scenario.busy ? 'SAFE_STATUS_BUSY' : 'SAFE_STATUS_READY',
      statusBar: scenario.statusBar ?? 'top',
      streaming: scenario.busy ?? false
    })

    const transcriptText = scenario.transform === 'stale-partial'
      ? '╔════════ SAFE_STALE ════════\n║ ⚠ approval required · SAFE_STALE_PROSE\n║ Enter confirm · 1-4 quick pick\nSAFE_NON_SOURCE_SHAPED_PARTIAL'
      : 'SAFE_TRANSCRIPT'
    const historyItems = [{ role: 'system', text: transcriptText }]
    const virtualRows = historyItems.map((msg, index) => ({ index, key: `SAFE_ROW_${index}`, msg }))
    const composer = {
      cols: scenario.columns,
      compIdx: 0,
      completions: [],
      empty: false,
      handleTextPaste: () => null,
      input: scenario.busy ? 'SAFE_BUSY_COMPOSER' : 'SAFE_READY_COMPOSER',
      inputBuf: [],
      pagerPageSize: 12,
      queueEditIdx: scenario.queueCount ? Math.max(0, scenario.queueCount - 2) : null,
      queuedDisplay: safeQueue(scenario.queueCount ?? 0),
      submit: noop,
      updateInput: noop,
      voiceRecordKey: { ctrl: false, key: 'v', meta: false, shift: false }
    }
    const actions = {
      activateLiveSession: noop, answerApproval: noop, answerClarify: noop, answerSecret: noop, answerSudo: noop,
      clearSelection: noop, closeLiveSession: async () => null, newLiveSession: noop, newPromptSession: noop,
      onModelSelect: noop, resumeById: noop, setStickyPrompt: noop
    }
    const status = {
      cwdLabel: 'SAFE_CWD', goodVibesTick: 0, lastTurnEndedAt: null, sessionStartedAt: null,
      showStickyPrompt: scenario.sticky ?? false, statusColor: '#808080', stickyPrompt: 'SAFE_STICKY_PROMPT',
      turnStartedAt: null, voiceLabel: ''
    }
    const transcript = {
      historyItems,
      scrollRef: { current: null },
      virtualHistory: { bottomSpacer: 0, end: virtualRows.length, measureRef: () => noop, offsets: [0], start: 0, topSpacer: 0 },
      virtualRows
    }
    const gateway = { gw: {}, rpc: async () => null }
    const tree = React.createElement(
      ink.Box,
      { flexDirection: 'column', height: ROWS, width: scenario.columns },
      React.createElement(
        GatewayProvider,
        { value: gateway },
        React.createElement(AppLayout, { actions, composer, mouseTracking: 'off', progress: { showProgressArea: false }, status, transcript })
      )
    )
    const { screen } = renderToScreen(tree, scenario.columns)
    const sourceRows: string[] = []
    const start = Math.max(0, screen.height - ROWS)
    for (let row = 0; row < ROWS; row += 1) {
      const sourceRow = start + row
      let text = ''
      for (let col = 0; col < scenario.columns; col += 1) {
        if (sourceRow >= screen.height) {
          text += ' '
          continue
        }
        const cell = cellAtIndex(screen, sourceRow * screen.width + col)
        const char = cell.width === 2 || cell.width === 3 || !cell.char ? ' ' : cell.char
        // TextInput's non-TTY render path paints the empty caret as an
        // inverse-styled space. Plain text cannot retain SGR cell style, so
        // encode that source-observed visible cell as a block only on the
        // input row after the source-rendered `>` prefix.
        const cursorArtifact = char === ' ' && (cell.styleId & 1) === 1 && text.trimStart().startsWith('>')
        text += cursorArtifact ? '█' : char
      }
      sourceRows.push(text.replace(/\s+$/u, ''))
    }
    return sourceRows
  }

  const applyTransform = (scenario: Scenario, rows: string[]): string[] => {
    let out = [...rows]
    const firstTop = out.findIndex(row => row.trimStart().startsWith('╔'))
    const firstBottom = out.findIndex((row, index) => index > firstTop && row.trimStart().startsWith('╚'))

    if (scenario.transform === 'header-only' && firstTop >= 0 && firstBottom > firstTop) {
      const control = out.findIndex((row, index) => index > firstTop && row.includes('Enter confirm'))
      const option = out.findIndex((row, index) => index > firstTop && /(?:▸ |  )1\. Allow/.test(row))
      const cut = option >= 0 ? option : control
      if (cut >= 0) for (let i = cut; i <= firstBottom; i += 1) out[i] = ''
    } else if (scenario.transform === 'controls-only' && firstTop >= 0 && firstBottom > firstTop) {
      const option = out.findIndex((row, index) => index > firstTop && /(?:▸ |  )1\. Allow/.test(row))
      if (option >= 0) for (let i = firstTop; i < option; i += 1) out[i] = ''
      out[firstBottom] = ''
    } else if (scenario.transform === 'header-offscreen' && firstTop >= 0 && firstBottom > firstTop) {
      const option = out.findIndex((row, index) => index > firstTop && /(?:▸ |  )1\. Allow/.test(row))
      if (option < 0) throw new Error(`${scenario.name}: source option rows not found`)
      const retained = out.slice(option)
      out = Array(Math.max(0, ROWS - retained.length)).fill('').concat(retained).slice(-ROWS)
    } else if (scenario.transform === 'selected-other') {
      const selected = out.findIndex(row => row.includes('▸ 1.'))
      const other = out.findIndex(row => row.includes('Other (type your answer)'))
      if (selected >= 0) out[selected] = out[selected]!.replace('▸ 1.', '  1.')
      if (other >= 0) out[other] = out[other]!.replace(/  (\d+\.)/, '▸ $1')
    }

    if (scenario.footerDash === 'en') out = out.map(row => row.replace(/\b1-(\d+)\b/, '1–$1'))
    if (scenario.maskMode === 'entered') {
      const input = out.findIndex(row => row.trimStart().startsWith('>'))
      if (input >= 0) out[input] = out[input]!.replace(/>\s*█?/, '> *****')
    }
    return out
  }

  const allScenarios = scenarios()
  const allowedNames = new Set([
    OUTPUT_MARKER,
    'README.md',
    'manifest.json',
    ...allScenarios.map(scenario => `${scenario.name}.txt`)
  ])
  await prepareSafeOutput(args.output, allowedNames)

  const records: ManifestRecord[] = []
  for (const scenario of allScenarios) {
    let rows = applyTransform(scenario, render(scenario))
    if (scenario.transform === 'complete-reproduction') {
      const source = rows
      const ready = render({ ...scenario, overlayKind: 'none', transform: undefined, busy: false }, true)
      const top = source.findIndex(row => row.trimStart().startsWith('╔'))
      const bottom = source.findIndex((row, index) => index > top && row.trimStart().startsWith('╚'))
      const composerStart = ready.findIndex(row => row.includes('SAFE_STATUS_READY') || row.includes('SAFE_READY_COMPOSER'))
      if (top < 0 || bottom < top || composerStart < 0) throw new Error(`cannot compose reproduction ${scenario.name}`)
      const prompt = source.slice(top, bottom + 1)
      const suffix = ready.slice(Math.max(0, composerStart - 2))
      rows = Array(Math.max(0, ROWS - prompt.length - suffix.length)).fill('').concat(prompt, suffix).slice(-ROWS)
    }
    if (rows.length !== ROWS) throw new Error(`${scenario.name}: expected ${ROWS} rows, got ${rows.length}`)

    if (scenario.name.endsWith('-empty-cursor') && !rows.some(row => row.trimStart() === '> █')) {
      throw new Error(`${scenario.name}: source-rendered inverse-styled cursor cell not found`)
    }
    const fixture = `${rows.join('\n')}\n`
    assertPrivacySafe(fixture, scenario.name)
    const file = `${scenario.name}.txt`
    await writeFile(join(args.output, file), fixture, 'utf8')
    records.push({
      file,
      generatorVersion: GENERATOR_VERSION,
      bootstrapCommandVersion: BOOTSTRAP_COMMAND_VERSION,
      hermesRevision: HERMES_REVISION,
      lockfileSha256: LOCK_HASH,
      componentSha256: COMPONENT_HASHES,
      columns: scenario.columns,
      rows: ROWS,
      overlayKind: scenario.overlayKind,
      sourceOptionCount: scenario.sourceOptionCount,
      titleWarningPresent: scenario.titleWarning,
      expectedState: scenario.expectedState,
      expectedKind: scenario.expectedKind,
      completeness: scenario.completeness,
      privacySafeScenario: scenario.name,
      notes: scenario.notes ?? '',
      sha256: sha256(fixture)
    })
  }

  const manifest = {
    schemaVersion: 1,
    generatorVersion: GENERATOR_VERSION,
    bootstrapCommandVersion: BOOTSTRAP_COMMAND_VERSION,
    incidentExactClassification: 'unproven',
    fixtureRows: ROWS,
    hermesRevision: HERMES_REVISION,
    lockfileSha256: LOCK_HASH,
    componentSha256: COMPONENT_HASHES,
    fixtures: records
  }
  const manifestText = `${JSON.stringify(manifest, null, 2)}\n`
  assertPrivacySafe(manifestText, 'manifest')
  await writeFile(join(args.output, 'manifest.json'), manifestText, 'utf8')
  await writeFile(join(args.output, 'README.md'), readme(), 'utf8')

  console.log(`generated ${records.length} source-rendered fixtures in ${args.output}`)
  console.log(`Hermes HEAD ${HERMES_REVISION}; rows=${ROWS}; manifest sha256=${sha256(manifestText)}`)
}

function assertPrivacySafe(text: string, label: string): void {
  for (const sentinel of FORBIDDEN_SENTINELS) {
    if (text.includes(sentinel)) throw new Error(`${label}: forbidden sentinel appeared: ${sentinel}`)
  }

  const forbiddenPatterns: Array<[string, RegExp]> = [
    ['home path', /\/(?:Users|home)\/[A-Za-z0-9._-]+/],
    ['email address', /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i],
    ['API/token-shaped value', /\b(?:sk|ghp|github_pat|xox[baprs])-[_A-Za-z0-9-]{12,}\b/i]
  ]
  for (const [name, pattern] of forbiddenPatterns) if (pattern.test(text)) throw new Error(`${label}: ${name} appeared`)

  // Environment values can carry credentials even when their names are
  // unfamiliar. Ignore only short/common process toggles that create unusable
  // false positives; every substantial value is forbidden from artifacts.
  const envValues = [...new Set(Object.values(process.env).filter((value): value is string => Boolean(value && value.length >= 12)))]
  for (const value of envValues) {
    if (text.includes(value)) throw new Error(`${label}: an environment-variable value appeared`)
  }
}

function readme(): string {
  return `# Hermes input fixtures\n\nThese fixtures are generated from Hermes \`${HERMES_REVISION}\` source with real \`AppLayout\` / \`PromptZone\` composition. The unavailable incident frame is **not** reconstructed; exact incident classification remains **unproven**. All caller-controlled values are deterministic neutral \`SAFE_*\` strings supplied before rendering.\n\nEvery \`.txt\` file is exactly 80 newline-delimited physical rows. The generator reads the pinned internal \`renderToScreen\` and \`cellAtIndex\` APIs, converts empty/spacer cells to spaces, encodes an inverse-styled empty TextInput cursor space as \`█\` on its \`>\` input row, clips above the fixed viewport, and trims trailing row spaces only. Partial-race and selected/masked variants retain source-rendered cells; the manifest notes the minimal deterministic cell operation. The complete-reproduction fixture documents the visible-cell limitation: a byte-equivalent complete prompt in the accepted region is expected input-required because provenance is not observable.\n\n## Regenerate\n\n\`\`\`bash\nNEXT_UP_ROOT="$(pwd)" # run from the Next Up checkout root\nHERMES_ROOT="$HOME/.hermes/hermes-agent"\nOUTPUT="$NEXT_UP_ROOT/Tests/NextUpCoreTests/Fixtures/HermesInput"\ncd "$HERMES_ROOT"\ntest "$(git rev-parse HEAD)" = ${HERMES_REVISION}\ntest -z "$(git status --porcelain -- ui-tui package-lock.json)"\ntest "$(shasum -a 256 package-lock.json | cut -d' ' -f1)" = ${LOCK_HASH}\nnpm ci\nnpm run build:ink --prefix ui-tui\ncd ui-tui\nnpx --no-install tsx "$NEXT_UP_ROOT/scripts/generate-hermes-input-fixtures.mts" \\\n  --hermes-root "$HERMES_ROOT" \\\n  --output "$OUTPUT"\n\`\`\`\n\nThe generator also checks the five pinned component hashes, the scoped clean tree, deterministic metadata, forbidden privacy sentinels, token/email/home-path patterns, and substantial environment-variable values. It never recursively deletes output entries. Generation requires the exact \`Tests/NextUpCoreTests/Fixtures/HermesInput\` suffix, a canonical path with that suffix, a nonsymlink output directory, a regular nonsymlink \`.next-up-hermes-input-fixtures\` authorization marker for any nonempty destination, and only the fixed generated-file allowlist. Run it twice and compare the output-tree hash to verify deterministic regeneration.\n`
}

main().catch(error => {
  console.error(error instanceof Error ? error.stack ?? error.message : String(error))
  process.exitCode = 1
})
