---
name: zhtw-add-term
description: >-
  Add, change, or stop a zh-TW terminology / replacement rule for the zhtw-mcp
  linter. Use whenever the user wants to teach zhtw-mcp a new 兩岸用詞 / 錯字 /
  慣用替換 (e.g. 軟件→軟體, 貴司→貴公司), change what a term gets corrected to,
  make a term stop firing, whitelist a 專有名詞, or import/extend the lexicon —
  in zh-TW this sounds like 「加進詞典 / 新增替換詞 / 這個改成… / 不要再標記 /
  這是誤判 / 把這個詞排除 / 加入白名單」, often WITHOUT naming any file. Also use
  when extending zhtw-mcp via a shareable pack or the project .zhtw-mcp.toml
  glossary. The workflow asks the user in plain zh-TW at every real editorial
  decision, edits the file safely, then proves the change with the compiled
  binary and a false-positive check. Do NOT use for pure lookups ("what is the
  Taiwan term for X?") with no intent to change rule data — that is
  taiwan-term-corrector's job.
---

# zhtw-add-term — update zhtw-mcp replacement data

Captures the verified workflow for extending zhtw-mcp's lexicon. It exists
because hand-editing these files has sharp edges that fail **silently**:

- a wrong `schema_version` **or a UTF-8 BOM** makes the linter treat the file as
  corrupt, rename it to `*.bak`, and **reset it to empty** — destroying every
  rule you (and the user) had;
- a short `from` term matches as a substring and fires inside unrelated words
  (我司 inside 司空見慣);
- the MCP server reads this data **once at startup**, so changes do nothing
  until it restarts;
- lint's human output goes to **stderr**, and a wrong `--pack` name is ignored
  with **exit 0** — so a broken change can look like it worked.

The skill's job is to get those right and to **prove** the change, not assume it.

## Core principle: ask before you guess

Some choices here are genuine editorial calls only the user can make — which
Taiwan form to prefer, how strict a term should be, whether a borderline match
is really wrong. When you hit one, **stop and ask the user in chat, in zh-TW**,
phrased in plain language (never dump raw enum values at them). The full list is
in [§5](#5-when-to-ask-the-user). Everything mechanical (paths, schema, the
verify commands) you handle yourself.

---

## 1. Pick the layer (ask if unclear)

| Layer | File | Scope | Use when |
|---|---|---|---|
| **A. overrides** | user-global `overrides.json` | this user, every project | personal preference, quick add — **the default** |
| **B. pack** | `packs/<name>.json` | shareable, versioned | a domain glossary to distribute (e.g. NAER 樂詞網) |
| **C. glossary** | repo `.zhtw-mcp.toml` | this project, whole team | team-wide always-flag / never-flag / canonical-form policy |

If the request doesn't make the layer obvious, ask. Layers A and B are
**user-global, outside the repo**; only C lives in the project tree.

**Resolve the path — don't assume `%APPDATA%`.** The config dir is
`$XDG_CONFIG_HOME` when it's set to an absolute path (on *every* platform,
Windows included), otherwise the OS default: Windows `%APPDATA%`, Linux
`~/.config`, macOS `~/Library/Application Support`. In this PowerShell
environment resolve it live rather than hardcoding:

```powershell
# overrides.json (layer A)
$dir = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { $env:APPDATA }
Join-Path $dir 'zhtw-mcp\overrides.json'      # …\zhtw-mcp\packs\ for layer B
```

For full merge / runtime precedence, see `references/schema.md` (one
authoritative list lives there).

---

## 2. Build the rule (layers A & B share one schema)

`overrides.json` and pack files use the **same** JSON shape (a pack adds an
optional `metadata` block). **Before writing anything beyond a plain `from→to`
pair — i.e. before choosing a non-obvious `type` or adding any clue/exception
field — read `references/schema.md`** for the full field table, the 7 `type`
values, `exceptions` matching rules, and `positional_clues` syntax.

### Step 0 — check what already exists (don't skip)

Lint the bare `from` term first (see §4 for how). If a built-in rule already
fires for it, your change is an **Override**, not an Add: a single-`to` override
*replaces* the built-in's suggestions (you may be silently dropping other valid
candidates) and changes its severity. Surface this to the user before
proceeding.

### The three operations

| Goal | Shape |
|---|---|
| **Add** a new replacement | `{ "from": "X", "to": ["Y"], "type": "cross_strait" }` |
| **Override** a built-in (cross-layer) | add a NEW object in a higher layer with the same `from` and new `to` (later layer wins at merge) |
| **Disable** a built-in | same `from`, `"disabled": true` (`"to": []` by convention) |

Common `type` → severity (full table in `references/schema.md`):

| `type` | for | severity |
|---|---|---|
| `cross_strait` | 兩岸用詞 (軟件→軟體) | warning |
| `typo` | 錯字 | error |
| `political_coloring` | 政治用語 (祖國/內地) | error |

### Candidates and "firmness" — explain the tradeoff, don't mis-state it

How many forms you put in `to` changes the *fixability*, and often the surfaced
severity:

- **One** candidate → auto-fixable, fires at the rule's full severity (warning
  for cross_strait).
- **Two+** candidates → marked **needs-review and NOT auto-fixable** (the engine
  won't pick between e.g. 本公司 vs 敝公司). Such terms are also Tier-2-eligible,
  so the disambiguator frequently **suppresses them to `info`** (you'll see
  `[tier2: suppressed]` in the JSON `context`). Do not state it as "multiple
  candidates ⇒ info"; the accurate framing is "needs-review / not auto-fixable,
  and usually surfaced at info via Tier-2."

The *same* firm-vs-advisory axis is also controllable explicitly with
`editorial_confidence` (`low` ⇒ not auto-fixable + needs-review) — prefer a
single `to` for "firm + auto-fix", multiple `to` for "human picks". Reach for
`editorial_confidence: low` only when you want a single-candidate term to stay
advisory anyway (a style preference like 優化). Don't apply both mechanisms to
the same rule and expect them to compound.

### Edit the file SAFELY (this is where data gets lost)

- **Read the existing file first** and merge into its arrays — never overwrite
  blind. Within a file, a repeated `from` should **replace** the existing object
  (upsert), not duplicate it. (Note: the across-layer "Override" above is the
  opposite — a *new* object in a *higher* layer; don't confuse the two.)
- **Write UTF-8 *without* BOM.** A BOM ⇒ corrupt ⇒ file reset to empty ⇒ all
  rules lost. Use the Write/Edit tool (no BOM). Do **not** use PowerShell
  `Set-Content`/`Out-File` (they add a BOM by default); if you must, use
  `-Encoding utf8NoBOM` or `[System.IO.File]::WriteAllText`. Avoid stray CRLF
  inside JSON string values.
- **Keep `schema_version: 3`.** Any other value ⇒ backup + reset.
- **If the file is absent**, write the full skeleton
  `{ "schema_version": 3, "spelling": [], "case": [] }`, not a bare array.
- An empty (0-byte) or partially-written file is also treated as corrupt. Because
  all of these reset silently (the warning is invisible without `RUST_LOG`),
  **§4 verification is the only proof the file actually loaded.**

For English casing (e.g. `Javascript`→`JavaScript`) add a `CaseRule` to the
`case[]` array instead — see `references/schema.md` §CaseRule.

---

## 3. Guard against false positives

Short `from` terms match as substrings, so a 2-char term can fire inside an
unrelated word. We hit this live: `我司` matched inside `令我司空見慣`. For any
short term, **brainstorm decoys** (words that contain the `from` characters but
mean something else) and — because the user is the domain expert on real
collisions — **show the decoy list to the user and ask if it's complete** before
relying on the check. When the §4 check trips, pick the narrowest guard and
confirm the choice with the user:

| Tool | Field | When | Watch out |
|---|---|---|---|
| **exception phrase** | `exceptions` | the collision is a specific longer word/idiom | phrase MUST contain `from` verbatim; use the **full** word so it doesn't over-suppress. `["我司空見慣"]` is safe; `["我司法"]` would also kill legit「我司法務」 |
| **negative clue** | `negative_context_clues` | a nearby word signals correct usage | ±40-char window — broad, can over-suppress |
| **positional clue** | `positional_clues` | the constraint is directional | syntax + plain-language gloss in `references/schema.md` |
| **accept it** | — | the collision is rare and low-harm | tell the user; they can `ignore_terms` it per call |

Prefer a full-phrase `exceptions` entry — it's surgical; broad clue windows
aren't.

---

## 4. Verify — and capture the right stream

The user chose auto-verification, and §2–§3 show why it's the only real proof.
Run it every time.

### 4.1 Find a runnable binary (probe first, then proceed)

In order: `target/release/zhtw-mcp.exe` → `target/debug/zhtw-mcp.exe` →
`cargo run --release -- …` (from repo root, slower) → a `zhtw-mcp` on `PATH`.
The binary has **no `--help`**, and running it with no subcommand starts the MCP
server on stdin (not help) — don't do that to probe. If nothing is runnable,
say so, fall back to JSON-validity only (parse the file), and tell the user
verification was partial.

### 4.2 Capture stderr or use JSON — NOT bare stdout

Human-readable output goes to **stderr**; capturing only stdout shows nothing
and looks like "no issues". Two correct ways:

```powershell
# (a) human output — must redirect stderr
& <binary> lint .\tmp-zhtw-verify.md 2>&1

# (b) machine output — JSON goes to STDOUT, parse it
& <binary> lint --format json .\tmp-zhtw-verify.md
```

JSON gives `issues[]` (each with `found`, `suggestions`, `rule_type`,
`severity`, `line`, `col`) plus `total` / `errors` / `warnings` — use these for
programmatic checks (e.g. assert your `from` appears with the expected
`severity` and `suggestions`).

**Global flags go BEFORE the subcommand.** `--pack`, `--config`, `--overrides`,
`--packs-dir` are parsed before `lint`; placing them after the file fails
(`Error: path does not exist: --pack`). Correct:

```powershell
& <binary> --pack <name> lint .\tmp-zhtw-verify.md          # test a pack
& <binary> --config .\.zhtw-mcp.toml lint .\tmp-zhtw-verify.md  # test glossary
```

### 4.3 Craft the test snippet

A temp file (e.g. `tmp-zhtw-verify.md` in the repo dir, **never** in the config
dir) with, per term: the `from` in a **real** context (expect it to fire) and
the `from` chars in **decoy** words (expect silence). Use **fullwidth**
punctuation so you don't get unrelated punctuation warnings muddying the check:

```
貴司提供的報價我司已收到。          ← both should fire
令我司空見慣，本公司司機今日請假。   ← 司空見慣 / 司機 must NOT fire
```

### 4.4 Check output against expectations, then clean up

Confirm every real case fired (right `severity`/`suggestions`) and every decoy
stayed silent. **Quote the before/after output to the user as evidence** — don't
just claim it passed. If a decoy fired, return to §3, add the guard, re-run.
**Always delete the temp file, including on failure.**

### 4.5 Layer-specific verification gotchas

- **Pack (B):** a wrong/unimported pack name is **silent (exit 0)** and falls
  back to the embedded ruleset — which may *also* flag your term, faking success.
  So: `pack validate` → `pack import` → confirm `pack list` shows it → then
  `--pack <name> lint …` and confirm the rule fires with the **pack's** expected
  severity/candidates (not the embedded form). For isolated testing without
  touching the user's real packs dir, point both import and lint at the same
  `--packs-dir <path>`.
- **Glossary (C):** `.zhtw-mcp.toml` is discovered from the **current working
  directory** (walking up to `.git`), not from the target file's location. From
  the wrong cwd it's **silently ignored (exit 0)**. Verify from the repo-root
  cwd, or pass `--config .\.zhtw-mcp.toml`.

---

## 5. When to ask the user

Decisions the skill must not make alone (batch related ones into one zh-TW
question round; never show raw enum values — translate to plain choices):

1. **Which layer** (A/B/C) — when the request doesn't make it obvious.
2. **The target form(s) `to`** — when more than one valid Taiwan form exists
   (本公司 vs 敝公司). The first listed is the preferred default. The *number* of
   forms they give is also the answer to firmness: one ⇒ I'll make it
   auto-fixable; two+ ⇒ advisory so a human picks. Only raise that tradeoff
   explicitly if they seem to want a multi-form term auto-applied.
3. **`type`** — *infer it* when obvious (calque ⇒ `cross_strait`, misspelling ⇒
   `typo`, PRC political term ⇒ `political_coloring`). Ask only when genuinely
   borderline, and ask in plain zh-TW (「這比較像錯字還是用詞差異?」), not by
   listing the 7 enum names.
4. **Short-term decoys** (§3) — show the brainstormed collision list and ask if
   it's complete, before trusting the FP check.
5. **False-positive handling** — when §4 trips, which guard to apply (or accept).
6. **Editing committed config** — **always** confirm before touching
   `.zhtw-mcp.toml` (it's shared, version-controlled team config).
7. **Pack activation** — for layer B, whether to also activate the pack
   (`--pack` / `.zhtw-mcp.toml packs=[…]`); install ≠ activate.

---

## 6. Apply the change

- **CLI** (`zhtw-mcp lint …`) re-reads the files every run → immediate.
- **MCP server** reads `overrides.json` / packs **once at startup**. **Tell the
  user to restart the MCP server** — this is the #1 "why isn't my rule working".
- **Pack:** `pack import` only installs; it applies only once activated via
  `--pack <name>` or `.zhtw-mcp.toml`'s `packs = [...]`.

---

## 7. Layer C: project glossary (.zhtw-mcp.toml)

TOML lists, not SpellingRules. Lives at the repo root and is **committed**
(team-wide) — confirm before editing (§5.6), and merge into any existing
`[glossary]` table without clobbering other keys (`profile`/`exclude`/`packs`).

```toml
profile = "strict"
packs = ["naer-electronics"]   # activate installed packs here

[glossary]
banned       = ["線程", "內存"]    # always flag (highest precedence; forces fire)
preferred    = ["最佳化", "資料庫"] # canonical pick when both variants appear
proper_nouns = ["TSMC", "MediaTek"] # never flag (added to suppression list)
```

Use this layer for *policy* (always/never flag, canonical choice). New
`from→to` rewrite rules belong in a pack (shareable) or overrides (personal).
Verify glossary changes from the repo-root cwd (§4.5).

---

## Pack quick reference (layer B)

```powershell
zhtw-mcp pack validate .\<name>.json   # JSON + dup-from + @seealso check
zhtw-mcp pack import   .\<name>.json   # install to packs dir (atomic); name from filename
zhtw-mcp pack list                     # list installed
zhtw-mcp pack export   <name>          # dump back to <name>.json
```

A pack adds an optional `metadata` block (`name`, `version`, `author`,
`description`, `license`, `source_url`) above the same `spelling`/`case`
arrays; `schema_version` must still be 3. Pack names can't contain path
separators / `..` / Windows reserved names (validated on import). Full field and
`type` reference: `references/schema.md`.
