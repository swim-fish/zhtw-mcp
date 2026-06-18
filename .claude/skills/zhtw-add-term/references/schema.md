# zhtw-mcp rule schema reference

Source of truth: `src/rules/ruleset.rs` (`SpellingRule`, `CaseRule`,
`RuleType`), `src/rules/store.rs` (`Overrides`, `PackMetadata`, exception
matching, paths, merge), `src/engine/scan/rule_ir.rs` + `src/engine/scan/mod.rs`
(clue/exception evaluation, window sizes), `src/config.rs` (`GlossaryConfig`).
Verify against those files if anything here looks stale.

## Top-level file (overrides.json AND pack files)

```jsonc
{
  "schema_version": 3,          // required; must equal 3
  "metadata": { ... },          // optional; packs only (ignored for overrides)
  "spelling": [ SpellingRule ], // terminology / replacement rules
  "case": [ CaseRule ]          // English casing rules
}
```

A wrong `schema_version`, **a UTF-8 BOM, corrupt/empty JSON** — none of these
error. The file is backed up to `<file>.v<N>.bak` / `<file>.corrupt.bak` and
reset to an empty default, **silently** (the warning needs `RUST_LOG`). So a
typo or a BOM-adding editor on Windows loses all existing rules. Keep it `3` and
write UTF-8 without BOM.

## SpellingRule

| Field | Required | Type | Notes |
|---|---|---|---|
| `from` | ✅ | string | source form to flag (matched as substring → mind collisions) |
| `to` | ✅ | string[] | suggested replacements; `[]` + `disabled:true` = disable a rule |
| `type` | ✅ | enum | one of the 7 below; sets default severity |
| `disabled` | | bool | true = rule removed after merge (only this flag matters; `to:[]` is convention) |
| `context` | | string | note for the AI agent; supports `@seealso <from>`, `@domain <field>` |
| `english` | | string | English anchor for cross-strait disambiguation (並行 = concurrency vs parallelism) |
| `exceptions` | | string[] | phrases where the match is NOT flagged; **each must contain `from` verbatim** |
| `context_clues` | | string[] | positive: only fire if one appears within ±40 chars |
| `negative_context_clues` | | string[] | veto: skip if any appears within ±40 chars (overrides positive clues) |
| `positional_clues` | | string[] | directional constraints (syntax below) |
| `tags` | | string[] | categorization / pack filtering |
| `editorial_confidence` | | enum | `high` / `medium` / `low`; `low` ⇒ `auto_fix_safe=false` + `needs_review=true` (for style-preference terms like 優化/算法 that are also valid zh-TW) |

### `type` values and default severity

`#[serde(rename_all = "snake_case")]`, so the JSON strings are exactly:

| `type` | Meaning | Default severity |
|---|---|---|
| `political_coloring` | PRC political coloring (祖國, 內地) | **Error** |
| `typo` | misspelling / wrong characters | **Error** |
| `cross_strait` | cross-strait usage (軟件→軟體) | Warning |
| `confusable` | easily confused (字體 vs 字型) | Warning |
| `variant` | glyph variant (裏→裡); only fires in `strict` profile | Warning |
| `ai_filler` | LLM filler phrase; `to:[""]` deletes the matched span | Info |
| `translationese` | Europeanized / translated-sounding Chinese | Info |

### Severity is NOT set by candidate count

Severity always comes from `type`'s default. Multiple `to` candidates do **not**
lower severity by themselves — they set `needs_review=true` and block auto-fix
(in MCP explain metadata). What you often *see* at info for a multi-candidate
term is **Tier-2 disambiguation suppression** (a separate stage; the JSON
`context` shows `[tier2: suppressed (score=…)]`). So: "2+ candidates ⇒
needs-review / not auto-fixable, and frequently Tier-2-suppressed to info" — not
"candidates set severity".

### `positional_clues` syntax

`TERM` is checked relative to the match. **The names are inverted from intuition
— read the gloss:**

| Clue | Meaning (plain language) | Window |
|---|---|---|
| `before:TERM` | the match comes *before* TERM → TERM appears **after** the match | 20 chars |
| `after:TERM` | the match comes *after* TERM → TERM appears **before** the match | 20 chars |
| `adjacent:TERM` | TERM is immediately next to the match (either side, no gap) | 0 |
| `not_before:TERM` | TERM must NOT appear within 20 chars after | 20 chars |
| `not_after:TERM` | TERM must NOT appear within 20 chars before | 20 chars |

Example: rule `from:"程序"`, `positional_clues:["before:設計"]` fires on
「程序設計」(設計 follows 程序) but not on bare 「程序」. All positive conditions
must pass (AND); any negative vetoes. When both `context_clues` and
`positional_clues` are present, both must match.

### How `exceptions` matches (and why "full phrase")

At match time, for each exception phrase the engine locates where `from` sits
inside that phrase, then checks whether the text around the current match equals
the **whole** exception phrase at that offset. Consequences:

- The exception phrase **must contain `from`** or it can never apply.
- Use the **full** colliding word/idiom. For `from:"我司"`, `"我司空見慣"` (5
  chars) only suppresses the idiom; `"我司法"` (3 chars) would also suppress the
  legitimate「我司法務」(our company + legal affairs).

## CaseRule

| Field | Required | Type | Notes |
|---|---|---|---|
| `term` | ✅ | string | canonical casing (e.g. `JavaScript`) |
| `alternatives` | | string[] | wrong casings to correct (`["javascript","JAVASCRIPT"]`) |
| `disabled` | | bool | true = disable |

## Pack `metadata` (optional, packs only)

```jsonc
"metadata": {
  "name": "naer-electronics", "version": "1.0.0", "author": "your-name",
  "description": "...", "license": "CC-BY-4.0",
  "source_url": "https://terms.naer.edu.tw/"
}
```

## Project glossary (.zhtw-mcp.toml `[glossary]`)

TOML string lists, not SpellingRules:

- `banned` — always flag, highest precedence (forces a calque to fire even in
  ambiguous prose)
- `preferred` — canonical zh-TW form chosen by the consistency report when both
  variants appear
- `proper_nouns` — never flag (added to the suppression list)

## Precedence (one authoritative picture)

Two distinct stages — don't conflate them:

1. **Rule-data merge** (which `from→to` rule wins when the same `from` is defined
   in several places), later wins:
   `embedded ruleset → overrides.json → pack[0] → pack[1] → …`
   (pack order = activation order: `--pack` repetitions, then config `packs=[…]`).
   `disabled` rules are dropped after merge.
2. **Runtime enforcement** (how glossary/TM influence the merged rules), per
   `src/config.rs`:
   `glossary banned > translation memory > glossary preferred > domain pack >
   embedded ruleset`.

## Paths

`config_dir()` = `$XDG_CONFIG_HOME` (only if absolute, all platforms) else
`dirs::config_dir()`:

| Platform | config dir | overrides | packs |
|---|---|---|---|
| Windows | `%APPDATA%` | `%APPDATA%\zhtw-mcp\overrides.json` | `%APPDATA%\zhtw-mcp\packs\` |
| Linux | `~/.config` | `~/.config/zhtw-mcp/overrides.json` | `~/.config/zhtw-mcp/packs/` |
| macOS | `~/Library/Application Support` | …`/zhtw-mcp/overrides.json` | …`/zhtw-mcp/packs/` |

`.zhtw-mcp.toml`: discovered from cwd walking up, stopping at `.git` (so
typically the repo root; a config above the `.git` boundary is not found).

## Lint output (for verification)

- Human output (the `1:1: warning …` lines + `N issue(s) found.`) → **stderr**.
  Capture with `2>&1`.
- `--format json` → **stdout**: `{ issues:[{found, suggestions, rule_type,
  severity, line, col, offset, length, context}], total, errors, warnings }`.
- Global flags (`--pack`, `--config`, `--overrides`, `--packs-dir`) go **before**
  the `lint` subcommand.

## Worked example: 貴司 / 我司

```jsonc
{
  "schema_version": 3,
  "spelling": [
    { "from": "貴司", "to": ["貴公司"], "type": "cross_strait",
      "context": "中國大陸商務簡稱;台灣稱對方公司用「貴公司」" },
    { "from": "我司", "to": ["本公司", "敝公司"], "type": "cross_strait",
      "context": "台灣自稱用「本公司」(中性) 或「敝公司」(謙稱)",
      "exceptions": ["我司空見慣"] }
  ],
  "case": []
}
```

`貴司` → single candidate → auto-fixable, fires as **warning**. `我司` → two
candidates → needs-review / not auto-fixable, and surfaces at **info** because
Tier-2 suppresses it (`[tier2: suppressed]`); the `exceptions` entry stops the
司空見慣 false positive.
