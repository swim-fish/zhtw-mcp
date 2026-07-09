# Rule Pack 定義與使用指南

本文整理 `zhtw-mcp` 目前的 rule pack 定義、匯入方式、啟用方式與載入順序。目標讀者是要維護、建立或散發領域詞庫的開發者。

Rule pack 適合承載可分享、可版本化的領域規則，例如醫療、法律、電子工程或特定組織的翻譯對照。若只是個人偏好，通常使用 `overrides.json`；若是專案層政策，例如一定要 flag 或永遠不要 flag 某些專有名詞，通常使用 `.zhtw-mcp.toml` 的 `[glossary]`。

## Pack 是什麼

Pack 是一個 JSON 檔案，安裝後會放在 packs 目錄，並在啟用時疊加到內建 ruleset 與使用者 overrides 之上。

Pack 和 `overrides.json` 共用同一個頂層資料格式：

```json
{
  "schema_version": 3,
  "metadata": {
    "name": "naer-electronics",
    "version": "1.0.0",
    "author": "your-name",
    "description": "國教院樂詞網電子工程領域對照",
    "license": "CC-BY-4.0",
    "source_url": "https://terms.naer.edu.tw/"
  },
  "spelling": [
    {
      "from": "三極管",
      "to": ["電晶體"],
      "type": "cross_strait",
      "english": "transistor",
      "context": "@domain electronics",
      "tags": ["electronics"]
    }
  ],
  "case": [
    {
      "term": "MOSFET",
      "alternatives": ["mosfet", "Mosfet"]
    }
  ]
}
```

注意：pack 使用的是 overrides schema，頂層欄位是 `spelling` 與 `case`。不要把內建 `assets/ruleset.json` 的 `spelling_rules`、`case_rules` 直接當成 pack 頂層欄位。

`metadata` 是選填，主要用於來源、版本與授權資訊。`pack list` 會顯示 `description`，所以公開散發的 pack 建議填寫。

`schema_version` 應固定填 `3`。目前 `pack validate` 與 `pack import` 主要是確認 JSON 能 parse 成 pack 結構，並不強制比對版本號碼；仍建議固定填入 `3`，避免未來 schema 行為改變時難以追蹤。

## Spelling 規則

`spelling` 是詞彙替換規則清單。常用欄位如下：

| 欄位 | 必填 | 說明 |
| --- | --- | --- |
| `from` | 是 | 要被偵測或替換的來源詞 |
| `to` | 是 | 建議替換詞清單；單一候選通常可自動修正，多候選通常需要人工判斷 |
| `type` | 是 | 規則類型，例如 `cross_strait`、`typo`、`political_coloring` |
| `disabled` | 否 | 設為 `true` 時停用同 `from` 的規則 |
| `context` | 否 | 人可讀的規則背景，也可放 `(@seealso ...)` 互參 |
| `english` | 否 | 英文錨點，適合兩岸同詞異義的情境 |
| `exceptions` | 否 | 例外片語，命中時不 flag |
| `context_clues` | 否 | 正向上下文線索 |
| `negative_context_clues` | 否 | 負向上下文線索，命中時抑制規則 |
| `positional_clues` | 否 | 有方向性的上下文線索 |
| `tags` | 否 | 領域或來源標籤 |
| `editorial_confidence` | 否 | `high`、`medium`、`low`；低信心規則會偏向需要人工審閱 |

`tags` 目前可用來標示來源或領域，但 CLI 尚未提供依 tag 啟用或過濾規則的參數。

目前可用的 `type` 值如下：

| `type` | 用途 |
| --- | --- |
| `cross_strait` | 兩岸用詞差異 |
| `typo` | 錯字或拼寫修正 |
| `political_coloring` | 政治色彩用語 |
| `confusable` | 易混淆詞 |
| `variant` | 異體字或標準字形差異 |
| `ai_filler` | AI 常見空泛補語或填充語 |
| `translationese` | 翻譯腔或歐化中文 |

停用一條既有規則時，放入同一個 `from` 並設定 `disabled: true`：

```json
{
  "from": "優化",
  "to": [],
  "type": "cross_strait",
  "disabled": true
}
```

## Case 規則

`case` 用於英文專有名詞大小寫校正。

```json
{
  "term": "JavaScript",
  "alternatives": ["javascript", "Javascript", "JAVASCRIPT"]
}
```

`term` 是標準寫法，`alternatives` 是會被偵測的其他寫法。`disabled: true` 可停用同一個 `term` 的既有 case 規則。Case 規則合併時會以小寫後的 `term` 當作 key，所以 `JavaScript` 與 `javascript` 視為同一條規則。

## Pack 檔名與安裝位置

Pack 名稱來自匯入來源檔案的檔名，不包含 `.json` 副檔名。例如：

```bash
zhtw-mcp pack import ./naer-electronics.json
```

會安裝成名稱為 `naer-electronics` 的 pack。

`metadata.name` 是描述用資訊，不會決定安裝後的 pack 名稱；目前安裝名稱以來源檔案的 `file_stem` 為準。

預設 packs 目錄是平台設定目錄下的 `zhtw-mcp/packs`：

| 平台 | 預設位置 |
| --- | --- |
| Windows | `%APPDATA%\zhtw-mcp\packs\` |
| macOS | `~/Library/Application Support/zhtw-mcp/packs/` |
| Linux | `~/.config/zhtw-mcp/packs/` |

若 `$XDG_CONFIG_HOME` 是絕對路徑，會優先使用 `$XDG_CONFIG_HOME/zhtw-mcp/packs/`。若找不到平台設定目錄，會退回相對路徑 `./packs/`。

可以用 `--packs-dir` 指定自訂 packs 目錄：

```bash
zhtw-mcp --packs-dir ./packs pack import ./naer-electronics.json
zhtw-mcp --packs-dir ./packs --pack naer-electronics lint docs/
```

`--packs-dir` 是 top-level 參數。建議放在 subcommand 前面，讓命令意圖清楚。

Pack 名稱會做安全檢查，避免 path traversal 或 Windows 保留名稱。名稱不得包含 `/`、`\`、`..`、null byte，不得是空字串、`.`，也不得以 `.` 或空白結尾。

`CON`、`PRN`、`AUX`、`NUL`、`COM1` 到 `COM9`、`LPT1` 到 `LPT9` 也會被拒絕。

## 建立與驗證 Pack

建議先在 repo 或暫存目錄建立 pack JSON，再執行驗證：

```bash
zhtw-mcp pack validate ./naer-electronics.json
```

目前 `pack validate` 會做三件事：

1. 確認 JSON 能 parse 成 pack 結構。
2. 檢查同一個 pack 內是否有重複的 `spelling[].from`。
3. 檢查 `context` 內的 `(@seealso ...)` 是否指到同一個 pack 內已有的 `from`。

若只有警告，命令仍會完成。匯入前仍應修掉警告，因為同 pack 內重複的 `from` 會在實際合併時變成後者覆蓋前者，讀者很難從 JSON 順序判斷意圖。

`pack validate` 不會檢查跨 pack 衝突，也不會檢查 pack 是否已安裝或已啟用。

## 匯入、列出與匯出

匯入：

```bash
zhtw-mcp pack import ./naer-electronics.json
```

匯入流程會：

1. 從來源檔案的 `file_stem` 推得 pack 名稱。
2. 驗證 pack 名稱是否合法。
3. 建立 packs 目錄。
4. 讀取來源 JSON，確認能 parse 成 pack 結構。
5. 寫入 `<packs-dir>/<name>.json`。

`pack import` 不會執行 `pack validate` 的重複 `from` 與 `@seealso` 警告檢查。匯入前請先手動跑 `pack validate`。

匯入不等於啟用。匯入只是把 pack 安裝到 packs 目錄；要讓 lint 使用它，還需要 `--pack` 或 `.zhtw-mcp.toml`。

列出已安裝 pack：

```bash
zhtw-mcp pack list
```

`pack list` 只列出 packs 目錄中的 `.json` 檔案，依檔名排序，且只顯示能成功載入的 pack。輸出會包含 pack 名稱、`spelling` 數量、`case` 數量，以及 `metadata.description`。

匯出：

```bash
zhtw-mcp pack export naer-electronics
```

匯出會把已安裝的 pack 寫到目前工作目錄的 `naer-electronics.json`。目前 CLI 不支援指定匯出目的檔。

## 啟用方式

### CLI 單次啟用

```bash
zhtw-mcp --pack naer-electronics lint docs/
```

`--pack` 是 top-level 參數，建議放在 `lint` 前面。若寫成下列形式，`--pack` 會落入 `lint` 自己的參數解析，不會被當成 active pack：

```bash
# 不建議
zhtw-mcp lint docs/ --pack naer-electronics
```

多個 pack 可以重複指定：

```bash
zhtw-mcp --pack medical --pack legal lint docs/
```

CLI 的 `--pack` 依出現順序加入 active pack 清單。

### 專案設定啟用

在 repo 根目錄放 `.zhtw-mcp.toml`：

```toml
profile = "strict"
packs = ["naer-electronics", "medical"]
```

`lint` 模式會從目前工作目錄往上尋找 `.zhtw-mcp.toml`，直到 `.git` 根目錄或檔案系統根目錄為止。也可以用 `--config <path>` 指定設定檔。

CLI 與設定檔可以合併使用：

```bash
zhtw-mcp --pack local-hotfix lint docs/
```

若 `.zhtw-mcp.toml` 同時有：

```toml
packs = ["naer-electronics", "medical"]
```

實際 active pack 清單會是：

```text
local-hotfix → naer-electronics → medical
```

從設定檔追加 pack 時，若名稱已存在於 active pack 清單，就不會再加入。CLI `--pack` 本身若重複指定，解析階段不會去重。

### MCP server 啟用

MCP server 啟動時也可以用 `--pack`：

```bash
zhtw-mcp --pack naer-electronics
```

Server mode 會在啟動時固定載入 active packs。若變更 pack 檔案或啟用清單，需要重啟 MCP server 才能保證新規則生效。

目前 server mode 不會自動讀取 `.zhtw-mcp.toml` 的 `packs = [...]`；要讓 server 使用 pack，請在啟動命令中傳入 `--pack`。

## 載入與覆蓋順序

Lint 與 server 會把規則合併成單一規則集合。實際合併順序如下，越右邊優先度越高：

```text
embedded ruleset → overrides.json → active pack[0] → active pack[1] → ... → active pack[N]
```

合併規則是後面的 layer 覆蓋前面的 layer：

- `spelling` 以 `from` 當 key。
- `case` 以小寫後的 `term` 當 key。
- 若最後勝出的規則有 `disabled: true`，該規則會被移除。

範例：

```bash
zhtw-mcp --pack medical --pack legal lint docs/
```

若 `medical` 和 `legal` 都定義 `from: "術語A"`，而 `to` 不同，`legal` 會勝出，因為它在 active pack 清單中比較後面。

若 CLI 與 `.zhtw-mcp.toml` 同時啟用不同 pack，CLI pack 會先進入清單，設定檔中的 pack 會追加在後面。因此當兩者有相同 `from` 時，設定檔中的 pack 可能覆蓋 CLI pack。

## 和其他自訂機制的關係

| 機制 | 檔案或參數 | 適用情境 |
| --- | --- | --- |
| `ignore_terms` | MCP 單次呼叫參數；`.zhtw-mcp.toml` 欄位 | 單次忽略，不適合長期規則；CLI lint 目前未套用設定檔欄位 |
| `overrides.json` | 使用者設定目錄 | 個人偏好，跨專案生效 |
| rule pack | packs 目錄中的 JSON | 可分享、可版本化的領域詞庫 |
| `.zhtw-mcp.toml` `packs` | repo 根目錄設定 | 專案啟用哪些已安裝 pack |
| `.zhtw-mcp.toml` `[glossary]` | repo 根目錄設定 | 專案層政策，例如 banned、preferred、proper_nouns |
| `assets/ruleset.json` | repo 內建規則 | 要貢獻回主詞庫時才修改 |

Pack JSON 不支援 `[glossary]`。若需要「專案一定要 flag 這些詞」或「這些專有名詞永遠不要 flag」，請在 `.zhtw-mcp.toml` 設定：

```toml
[glossary]
banned = ["非標準詞A", "非標準詞B"]
preferred = ["最佳化", "資料庫"]
proper_nouns = ["TSMC", "MediaTek"]
```

## 常見陷阱

### 匯入不等於啟用

`pack import` 只會把 JSON 安裝到 packs 目錄。Lint 不會自動套用所有已安裝 pack；必須藉由 `--pack` 或 `.zhtw-mcp.toml` 啟用。

### Validate 不是完整語意稽核

`pack validate` 會檢查 JSON 結構、同 pack 內重複 `from`、以及 `@seealso` 參照，但不會檢查跨 pack 衝突，也不會驗證每個詞是否真的是台灣用語。公開散發前仍應用實際文字跑 `lint` 驗證。

### 跨 Pack 衝突靠載入順序決定

程式內有 `detect_pack_conflicts` 可找出多個 pack 之間同 `from` 但 `to` 不同的情況，但目前 pack CLI 的 validate、import 與實際 merge 路徑沒有使用它。實際執行時以 active pack 順序決定誰覆蓋誰。

### Pack 載入失敗不一定中止

合併 active packs 時，單一 pack 載入失敗會寫入 tracing warning 並繼續。若發現某個 pack 沒有生效，請先確認 pack 名稱、packs 目錄與啟動參數，並用 `pack list` 確認是否能被載入。

### Convert 目前不套用 Pack

`convert` 子命令目前不啟用 active packs。若需要驗證 pack 規則，請使用 `lint`。

### 修改後需要重啟 Server

CLI 每次執行都會重新讀取 pack。MCP server 則是在啟動時建立 scanner；修改 pack 檔案或啟用清單後，請重啟 server。

## 建議工作流程

1. 建立 pack JSON，填入 `schema_version: 3` 與 `metadata`。
2. 每個 `spelling` 規則先確認 `from`、`to`、`type`，短詞要加上 `exceptions` 或上下文線索。
3. 執行 `zhtw-mcp pack validate ./your-pack.json`。
4. 修掉重複 `from` 與 `@seealso` 警告。
5. 執行 `zhtw-mcp pack import ./your-pack.json`。
6. 用 `zhtw-mcp --pack your-pack lint <test-file>` 驗證實際文字。
7. 若要讓團隊固定啟用，在 `.zhtw-mcp.toml` 加入 `packs = ["your-pack"]`。
8. 若給 MCP server 使用，在 server 啟動命令加入 `--pack your-pack` 並重啟。

## 實作參考

- `src/rules/store.rs`：`PackMetadata`、`Overrides`、`PackStore`、pack 驗證與合併邏輯。
- `src/main.rs`：`--pack`、`--packs-dir`、`pack` 子命令與 `lint` active pack 合併。
- `src/config.rs`：`.zhtw-mcp.toml` 的 `packs` 與 `[glossary]` 設定。
- `docs/cli.md`：CLI 使用摘要。
- `docs/lexicon-extension-research.md`：自訂詞庫與 pack 研究筆記。
