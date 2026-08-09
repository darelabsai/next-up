# Hermes input fixtures

These fixtures are generated from Hermes `c5d37bb95cf7a932d644eb2811f57a7f00b9f670` source with real `AppLayout` / `PromptZone` composition. The unavailable incident frame is **not** reconstructed; exact incident classification remains **unproven**. All caller-controlled values are deterministic neutral `SAFE_*` strings supplied before rendering.

Every `.txt` file is exactly 80 newline-delimited physical rows. The generator reads the pinned internal `renderToScreen` and `cellAtIndex` APIs, converts empty/spacer cells to spaces, encodes an inverse-styled empty TextInput cursor space as `█` on its `>` input row, clips above the fixed viewport, and trims trailing row spaces only. Partial-race and selected/masked variants retain source-rendered cells; the manifest notes the minimal deterministic cell operation. The complete-reproduction fixture documents the visible-cell limitation: a byte-equivalent complete prompt in the accepted region is expected input-required because provenance is not observable.

## Regenerate

```bash
NEXT_UP_ROOT="$(pwd)" # run from the Next Up checkout root
HERMES_ROOT="$HOME/.hermes/hermes-agent"
OUTPUT="$NEXT_UP_ROOT/Tests/NextUpCoreTests/Fixtures/HermesInput"
cd "$HERMES_ROOT"
test "$(git rev-parse HEAD)" = c5d37bb95cf7a932d644eb2811f57a7f00b9f670
test -z "$(git status --porcelain -- ui-tui package-lock.json)"
test "$(shasum -a 256 package-lock.json | cut -d' ' -f1)" = f75555da8d603ce69bf83dd68dc225ff8d924e2af44b1752712a5a0b673e5039
npm ci
npm run build:ink --prefix ui-tui
cd ui-tui
npx --no-install tsx "$NEXT_UP_ROOT/scripts/generate-hermes-input-fixtures.mts" \
  --hermes-root "$HERMES_ROOT" \
  --output "$OUTPUT"
```

The generator also checks the five pinned component hashes, the scoped clean tree, deterministic metadata, forbidden privacy sentinels, token/email/home-path patterns, and substantial environment-variable values. It never recursively deletes output entries. Generation requires the exact `Tests/NextUpCoreTests/Fixtures/HermesInput` suffix, a canonical path with that suffix, a nonsymlink output directory, a regular nonsymlink `.next-up-hermes-input-fixtures` authorization marker for any nonempty destination, and only the fixed generated-file allowlist. Run it twice and compare the output-tree hash to verify deterministic regeneration.
