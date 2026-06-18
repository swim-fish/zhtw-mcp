# 自訂詞庫擴充研究筆記

> 整理目的:統整 `zhtw-mcp` 目前的檢查機制、詞庫結構,以及四種「匯入自訂詞庫」的層級與實作方式,作為後續整合外部詞源(例如國家教育研究院樂詞網)的依據。
>
> 文件性質:研究筆記/技術備忘錄,非正式 user-facing 文件。所有結論均附原始碼出處(`file:line`)。

---

## 1. MCP 主要檢查方式

### 1.1 對外介面

整個 MCP 伺服器只暴露 **一個工具** `zhtw`,同時負責 lint / fix / quality gate。所有呼叫是 **stateless 的**,`profile`、`relaxed`、`detect_ai`、`fix_mode`、`max_errors` 等都是每次呼叫傳入。

出處:
- `docs/mcp.md:5-23` — 工具完整參數表
- `src/mcp/tools.rs` — Tool handler 實作

### 1.2 處理管線(10 個階段)

來源:`docs/internals.md:7-19`

| 階段 | 內容 | 對應程式碼 |
|---|---|---|
| 1 | NFC 正規化 + byte offset mapping | `src/engine/normalize.rs` |
| 2 | Content-type 分派:Markdown(pulldown-cmark)/ YAML / 純文字;`MarkdownScanCode` 變體可進入 fenced code | `src/engine/markdown.rs` |
| 3 | Inline 抑制標記 `<!-- zhtw:ignore-next-line -->`、`<!-- zhtw:ignore-block/end-ignore -->` | `src/engine/suppression.rs` |
| 4 | **Spelling pass**:雙 Aho-Corasick(spelling 用 leftmost-longest、case 用大小寫不敏感),context-clue AC 預掃 | `src/engine/scan/spelling.rs`、`src/engine/scan/case_rule.rs` |
| 5 | Punctuation pass:半 → 全形、CN 彎引號、頓號、引號階層、CJK 間距 | `src/engine/scan/punctuation.rs`、`src/engine/scan/quotes.rs`、`src/engine/scan/spacing.rs` |
| 6 | Variant pass:字形正規化 + 例外短語檢查 | `src/engine/scan/grammar.rs`(含 variant) |
| 7 | 重疊處理:長者勝、嚴重度高者勝 | `src/engine/scan/overlap.rs` |
| 8 | Profile 過濾(例:`臺`/`台` 僅在 `strict`) | `src/rules/ruleset.rs:140-191` `Profile::config()` |
| 9 | **Tier 2 本地消歧**:>=0.6 解析、<0.3 抑制、[0.3, 0.6) 升 Tier 3 | `src/engine/disambig.rs` |
| 10 | **Tier 3 LLM Sampling**(選用):透過 MCP Sampling 請主機 LLM 仲裁,結果寫入 persistent judgment cache | `src/mcp/sampling.rs`、`src/rules/judgment_cache.rs` |

### 1.3 關鍵設計位置

| 主題 | 出處 |
|---|---|
| 規則型別與資料結構 | `src/rules/ruleset.rs:404-472` `SpellingRule`、`src/rules/ruleset.rs:520-530` `CaseRule` |
| 兩個 Profile 設定 | `src/rules/ruleset.rs:140-191` `Profile::config()` |
| Scan 子模組 | `src/engine/scan/{spelling,punctuation,grammar,case_rule,quotes,spacing,ellipsis,repetition,acronym,overlap,rule_ir}.rs` |
| 規則載入(編譯期 → 執行期) | `build.rs:69-81`(JSON → postcard)、`src/rules/loader.rs:9-12` `load_embedded_ruleset()` |
| ruleset hash(可重現性) | `src/rules/loader.rs:16-26` `compute_ruleset_hash()` |

---

## 2. 目前的詞庫

### 2.1 內建主詞庫:`assets/ruleset.json`

唯一的權威來源,共 **13021 行**,約 1100+ 條 spelling 規則 + 15 條 case 規則,共 8 個類別:

| RuleType | 用途 | 預設嚴重度 | 出處 |
|---|---|---|---|
| `cross_strait` | 兩岸用詞(軟件→軟體) | Warning | `src/rules/ruleset.rs:347` |
| `political_coloring` | 政治色彩(祖國、內地) | Error | `src/rules/ruleset.rs:345` |
| `confusable` | 容易混淆(字體 vs 字型) | Warning | `src/rules/ruleset.rs:351` |
| `typo` | 錯字(乞業→企業) | Error | `src/rules/ruleset.rs:349` |
| `variant` | 字形(裏→裡,僅 strict)| Warning | `src/rules/ruleset.rs:354` |
| `ai_filler` | AI 贅詞(值得注意的是) | Info | `src/rules/ruleset.rs:357` |
| `translationese` | 翻譯腔/歐化 | Info | `src/rules/ruleset.rs:362` |
| `case` | 大小寫(JavaScript、GitHub) | — | `src/rules/ruleset.rs:520` |

預設嚴重度對應表:`src/rules/ruleset.rs:393-401` `RuleType::default_severity()`

#### SpellingRule 完整欄位

出處:`src/rules/ruleset.rs:404-472`

| 欄位 | 必填 | 說明 |
|---|---|---|
| `from` | ✅ | 觸發詞 |
| `to[]` | ✅ | 建議替代詞(陣列) |
| `type` | ✅ | RuleType 枚舉 |
| `disabled` | | 是否停用 |
| `context` | | 給 AI agent 的使用情境註解(支援 `@seealso` 互參) |
| `english` | | 英文錨點,用於跨海峽詞義消歧 |
| `exceptions[]` | | 例外短語(`分類` 不觸發 `類` 警告) |
| `context_clues[]` | | 正向 clue:周邊出現時才觸發 |
| `negative_context_clues[]` | | 反向 clue:周邊出現時跳過(veto) |
| `positional_clues[]` | | 位置條件:`before:TERM` / `after:TERM` / `adjacent:TERM` / `not_before:TERM` / `not_after:TERM` |
| `tags[]` | | 分類標籤,方便 pack 過濾 |
| `editorial_confidence` | | `high` / `medium` / `low`;`low` 會被標 `auto_fix_safe = false` + `needs_review = true` |

### 2.2 OpenCC 資料(離線 SC→TC 轉換)

`data/opencc/` 收三個原始檔:
- `STCharacters.txt`
- `STPhrases.txt`
- `TWVariants.txt`

由 `scripts/gen-s2t-tables.py` 在編譯期預生成成 Rust 表格(`src/engine/s2t_data.rs`),執行期不需 OpenCC 依賴。

出處:`docs/internals.md:31` — *"Built-in SC→TC converter (`s2t.rs` + `s2t_data.rs`) eliminates the OpenCC runtime dependency for the `convert` subcommand."*

### 2.3 執行期套疊優先順序

由高到低(`src/rules/glossary.rs:1-10` 開頭註解 — TODO 35.9 precedence):

```
glossary.banned  >  Translation Memory  >  glossary.preferred
                 >  domain pack  >  embedded ruleset
```

詳細合併流程見第 5 節。

---

## 3. 自訂詞庫的四個層級

由「修改範圍」由窄到寬排列。

### A. 單次呼叫:`ignore_terms` 參數

只影響該次 MCP 呼叫,該詞降級為 Info。

```json
{"text": "這個軟件很好用", "ignore_terms": ["軟件"]}
```

出處:`docs/mcp.md:19, 47-52`

### B. 專案層:`.zhtw-mcp.toml`(team-wide,**推薦給團隊共用**)

放在 git repo 根目錄,自動沿 cwd 向上找(碰到 `.git` 停止)。

```toml
profile = "strict"
max_errors = 0
exclude = ["vendor/**"]
packs = ["medical", "naer-electronics"]

[glossary]
banned       = ["線程", "內存"]          # 一定要 flag(高優先)
preferred    = ["最佳化", "資料庫"]       # 多候選時優先採用
proper_nouns = ["TSMC", "MediaTek"]       # 永遠不 flag
```

出處:
- `src/config.rs:12-31` `ProjectConfig` + `CONFIG_FILENAME = ".zhtw-mcp.toml"`
- `src/config.rs:43-61` `GlossaryConfig`
- `src/config.rs:94-110` `find_config_file()`(向上尋找,碰 `.git` 停)
- `src/rules/glossary.rs:54-120` `apply_glossary()` — banned 會合成 Error issue;proper_noun 會抑制
- `docs/cli.md:86-98`

注意:**glossary 區塊只能放在 `.zhtw-mcp.toml`,pack 內不支援**(`src/config.rs:49` 是 ProjectConfig 子結構)。

### C. 使用者層:`overrides.json`(個人偏好,跨專案生效)

預設路徑(`src/rules/store.rs:313-317` `default_overrides_path()`):
- Linux:`~/.config/zhtw-mcp/overrides.json`(或 `$XDG_CONFIG_HOME`)
- macOS:`~/Library/Application Support/zhtw-mcp/overrides.json`
- Windows:`%APPDATA%\zhtw-mcp\overrides.json`

Schema 與 `assets/ruleset.json` 相同(`src/rules/store.rs:62-72` `Overrides`):

```json
{
  "schema_version": 3,
  "spelling": [
    {"from": "優化", "to": ["最佳化"], "type": "cross_strait", "disabled": true}
  ],
  "case": []
}
```

關鍵實作:
- `src/rules/store.rs:96-126` `OverrideStore::open()` — 含 schema 不符自動備份重置
- `src/rules/store.rs:151-201` `upsert_spelling_override()` / `disable_spelling_rule()`
- `src/rules/store.rs:275-292` `atomic_write_json()` — tempfile + rename 原子寫入
- `src/rules/store.rs:24-36` `acquire_lock()` — fs2 advisory lock 防多伺服器搶寫
- `src/rules/store.rs:17` `SCHEMA_VERSION = 3` — schema 版號常數

### D. 領域知識包:`pack`(可分享、可版本化)

詳見第 5 節完整實作說明。

### E. 直接 PR 進主詞庫

修改 `assets/ruleset.json`,跑驗證腳本:

```bash
python scripts/check-ruleset.py --lint
```

出處:`scripts/check-ruleset.py:1-10`(去重、排序、緊湊格式化、語意衝突偵測)

---

## 4. Pack 完整實作說明

### 4.1 Pack JSON 範本

Schema 與 `Overrides` 完全相同,額外可加 `metadata`:

```json
{
  "schema_version": 3,
  "metadata": {
    "name": "naer-electronics",
    "version": "1.0.0",
    "author": "your-name",
    "description": "國教院樂詞網 — 電子工程領域對照",
    "license": "CC-BY-4.0",
    "source_url": "https://terms.naer.edu.tw/"
  },
  "spelling": [
    {
      "from": "三極管",
      "to": ["電晶體"],
      "type": "cross_strait",
      "english": "transistor",
      "context": "@domain 電子",
      "tags": ["electronics"]
    },
    {
      "from": "二極管",
      "to": ["二極體"],
      "type": "cross_strait",
      "english": "diode",
      "context": "@domain 電子"
    }
  ],
  "case": [
    { "term": "MOSFET", "alternatives": ["mosfet", "Mosfet"] }
  ]
}
```

注意事項:
- `schema_version` **必須是 3**(否則被當作不相容自動備份重置 — `src/rules/store.rs:101-115`)
- `spelling[].type` 限定 7 種值(同 §2.1)
- `metadata` 整段 optional(向後相容於純 overrides)

出處:
- `src/rules/store.rs:41-54` `PackMetadata`
- `src/rules/store.rs:62-72` `Overrides`(pack 共用此結構)
- `src/rules/store.rs:60-61` 註解:*"Used for both ~/.config/zhtw-mcp/overrides.json and pack files in ~/.config/zhtw-mcp/packs/"*

### 4.2 安裝

```bash
zhtw-mcp pack import ./naer-electronics.json
# Installed pack 'naer-electronics' to <packs_dir>
```

實作流程(`src/main.rs:2158-2167` + `src/rules/store.rs:845-855`):
1. 用 `file_stem()` 從檔名推得 pack 名稱(去掉 `.json`)
2. `serde_json::from_str::<Overrides>` 預先驗證 schema
3. `atomic_write_json` 原子地寫入 `<packs_dir>/<name>.json`

預設安裝位置(`src/rules/store.rs:768-772` `default_packs_dir()`):

```
Linux:    ~/.config/zhtw-mcp/packs/              (或 $XDG_CONFIG_HOME)
macOS:    ~/Library/Application Support/zhtw-mcp/packs/
Windows:  %APPDATA%\zhtw-mcp\packs\
fallback: ./packs/
```

可用 `--packs-dir <path>` 自訂(`src/main.rs:120-124`)。

### 4.3 安全防護:Pack 名稱驗證

`src/rules/store.rs:859-886` `validate_pack_name()` 拒絕:
- 路徑分隔符(`/`、`\`)、`..`、null bytes、空字串、`.`
- 結尾為 `.` 或空白(Windows 檔名問題)
- Windows 保留名:`CON` / `PRN` / `AUX` / `NUL` / `COM1-9` / `LPT1-9`

→ 防 path traversal。對應測試:`src/rules/store.rs:1404-1417`

### 4.4 啟用

三種方式擇一(可組合):

```bash
# CLI 一次性
zhtw-mcp --pack naer-electronics lint docs/

# 多個 pack(後者優先,見 §4.6)
zhtw-mcp --pack medical --pack legal lint docs/

# 寫入專案設定,團隊共用
# .zhtw-mcp.toml
packs = ["naer-electronics", "medical"]
```

實作:
- CLI 解析:`src/main.rs:116-119` `--pack` 旗標
- Config 合併:`src/main.rs:574-578` — CLI active_packs 在前,config packs 追加在後(去重後追加)
- MCP 伺服器啟動時固定載入:`src/main.rs:651, 672`

### 4.5 管理子命令

```bash
zhtw-mcp pack list
zhtw-mcp pack validate ./naer-electronics.json
zhtw-mcp pack export naer-electronics    # 匯出回 naer-electronics.json
zhtw-mcp pack import ./naer-electronics.json
```

實作:`src/main.rs:2126-2195` `run_pack_cmd()`

驗證細項(`src/rules/store.rs:894-933` `PackStore::validate()`):
1. JSON schema 解析
2. 重複 `from` 鍵偵測
3. `@seealso` 互參完整性(指向未知 `from` 會警告)

### 4.6 載入合併管線

**核心函式**:`src/rules/store.rs:970-1001` `build_merged_rules()`

```rust
let mut layers = vec![
    store.load_spelling_rules(base_spelling),  // 第 1 層:embedded ruleset + overrides.json
];
for pack_name in active_packs {                 // 第 2+ 層:依 --pack 順序
    layers.push(pack_store.load(pack_name)?.spelling);
}
merge_spelling_rules(&layers)                   // 合併
```

**合併規則**(`src/rules/store.rs:1008-1025` `merge_spelling_rules()`):
- 用 `HashMap<from_key, index>` 追蹤
- **同 `from`,後者覆蓋前者**(later layers override earlier)
- 最後 `retain(|r| !r.disabled)` 清掉被 disable 的規則

→ **優先度由低到高**:

```
embedded ruleset → overrides.json → pack[0] → pack[1] → ... → pack[N]
```

→ **想用 pack 停用主詞庫某條規則**,在 pack 內放:
```json
{ "from": "優化", "to": [], "type": "cross_strait", "disabled": true }
```

Case rules 同理:`src/rules/store.rs:1029-1047` `merge_case_rules()`(以 lower-case term 為鍵)。

### 4.7 衝突偵測

當 **多個 pack 定義同一個 `from` 但 `to` 不同時**,會回報 `PackConflict`。

出處:
- `src/rules/store.rs:784-791` `PackConflict` 結構
- `src/rules/store.rs:941-965` `detect_pack_conflicts()`

注意:衝突 **只是警告,不阻擋執行**,merge 仍以「後者覆蓋」進行。建議作為發佈前的 lint 檢查。

---

## 5. 整合樂詞網(`https://terms.naer.edu.tw/`)的建議流程

### 5.1 現況

目前 `assets/ruleset.json`、`data/opencc/`、`scripts/` 中 **均無 NAER 字串**(全域搜尋無 `naer`/`樂詞`),代表此來源尚未整合。

### 5.2 為何適合做為補強來源

- 國家教育研究院樂詞網是官方學術名詞權威(理工、人文、醫學分類齊全)
- 每筆都有英中對照 → 可直接填入 SpellingRule 的 `english` 欄位作為消歧錨點
- 涵蓋專業領域,可彌補 `assets/ruleset.json` 對學術用語的不足

### 5.3 建議整合路徑

#### 第 1 步:寫一支匯入腳本(`scripts/import-naer.py`)

仿 `scripts/gen-s2t-tables.py` 的模式,偽碼:

```python
# 1. 讀 NAER 來源 (CSV / Excel)
# 2. 對每筆 (英文, 中國大陸用詞, 台灣用詞) 產生一條 SpellingRule:
#       from   = 中國大陸用詞
#       to     = [台灣用詞]
#       type   = "cross_strait"
#       english= 英文
#       context= f"@domain {學科}"
#       tags   = [學科]            # 方便日後過濾
# 3. 去重(from 唯一)
# 4. 與 assets/ruleset.json 對照,跳過已存在的 from
#    (避免覆蓋主詞庫精細的 context_clues 設定)
# 5. 輸出 packs/naer-<學科>.json,套上 metadata
```

#### 第 2 步:驗證

```bash
zhtw-mcp pack validate ./naer-electronics.json
```

#### 第 3 步:分享

- 上傳到 GitHub repo / Gist
- 使用者:`curl -O ... && zhtw-mcp pack import naer-electronics.json`
- 或在 `.zhtw-mcp.toml` 寫 `packs = ["naer-electronics"]`

### 5.4 授權注意

樂詞網資料採政府資料開放授權(CC BY),整合時須在 pack `metadata.license` 與 `metadata.source_url` 註明來源,符合本專案 MIT 授權的可重新散布要求。

---

## 6. 容易踩到的細節

| 議題 | 重點 | 出處 |
|---|---|---|
| MCP 伺服器路徑也吃 pack | server 啟動時就把 `pack_store` + `active_packs` 餵進去,執行期無法切換 active pack | `src/main.rs:651, 672` |
| CLI 順序的優先度 | CLI `--pack` 在前 = 優先度較低(因為合併是「後者覆蓋」) | `src/main.rs:574-578`、`src/rules/store.rs:1008-1025` |
| Pack 沒有 glossary | `banned` / `preferred` / `proper_nouns` 僅支援在 `.zhtw-mcp.toml`;若要分享 banned list,要另外請使用者加進 toml | `src/config.rs:49`、`src/rules/glossary.rs` |
| `editorial_confidence: "low"` | Pack 內條目可標 `low`,自動標 `auto_fix_safe = false`,適合 style preference 型詞條(避免 `--fix` 誤動) | `src/rules/ruleset.rs:481-490` |
| Schema 升級保護 | `schema_version` 不符會自動備份成 `.vN.bak` 重置,避免啟動失敗 | `src/rules/store.rs:101-115` |
| Pack 安全 | path traversal、Windows 保留名都被 `validate_pack_name` 擋掉 | `src/rules/store.rs:859-886` |
| 不破壞 fixer 設計 | confusable 與 clue-gated cross_strait 規則由 scanner 標但 fixer 不動 | `docs/internals.md:57` |

---

## 7. 後續可深入的方向

- [ ] 撰寫 `scripts/import-naer.py` 骨架,並設計合適的學科切分(每學科一個 pack)
- [ ] 設計 pack 規則 lint 機制(目前 `validate` 只檢查 JSON + dup + `@seealso`,可加更多語意檢查)
- [ ] 評估是否在 `.zhtw-mcp.toml` 內支援 pack 巢狀引用(目前 pack 不能引用其他 pack)
- [ ] Pack hot reload(目前 `OverrideStore::reload()` 有 `zh_reload` 介面,pack 沒有)

---

## 附錄 A:相關檔案速查

| 主題 | 路徑 |
|---|---|
| 主詞庫資料 | `assets/ruleset.json` |
| OpenCC 來源 | `data/opencc/{STCharacters,STPhrases,TWVariants}.txt` |
| 規則型別與結構 | `src/rules/ruleset.rs` |
| 規則載入 | `src/rules/loader.rs` |
| Overrides + Pack 儲存 | `src/rules/store.rs` |
| Project glossary | `src/rules/glossary.rs` |
| Project config | `src/config.rs` |
| CLI 入口(pack 子命令在 `run_pack_cmd`) | `src/main.rs` |
| MCP tool 實作 | `src/mcp/tools.rs` |
| Scan 子模組 | `src/engine/scan/*.rs` |
| Tier 2 消歧 | `src/engine/disambig.rs` |
| Tier 3 sampling | `src/mcp/sampling.rs` |
| Judgment cache | `src/rules/judgment_cache.rs` |
| 編譯期 JSON→postcard | `build.rs` |
| Ruleset 驗證腳本 | `scripts/check-ruleset.py` |
| S→T 表格產生器 | `scripts/gen-s2t-tables.py` |
| 既有文件 | `docs/{mcp,internals,rules,cli,moe-standards,release}.md` |
