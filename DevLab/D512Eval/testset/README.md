# D512 公開語料測試集

語料下載必須先獲得使用者同意；來源、授權、檔案大小與已知限制見 [SOURCES.md](data/SOURCES.md)。執行不使用輸入法、UserDefaults、POM 或使用者詞庫；詞庫只讀指定的九個 `phrases-*.txt`。

## 環境與執行

使用已安裝的 Python 3.11+、`uv`、`curl`；程式只用 Python 標準函式庫，沒有第三方相依。從此 worktree 根目錄執行：

```sh
uv venv --python python3 --no-python-downloads DevLab/D512Eval/testset/.venv
# 只有使用者實際同意兩來源後，才能執行下行；引號內保留實際同意訊息。
uv run --directory DevLab/D512Eval/testset --offline --no-sync python scripts/acquire.py --approval-note '使用者實際同意訊息'
```

取得並凍結 raw 後，**單一命令離線重跑產生器**：

```sh
uv run --directory DevLab/D512Eval/testset --offline --no-sync python scripts/generate.py
```

預設 seed `20261015`、dev 目標 20%、held-out 最少 3,000 筆。完整 JSONL 產於 `data/generated/dev.jsonl` 與 `held-out.jsonl`；最多 200 筆跨來源／分割樣本存 `data/sample.jsonl`。分組隔離可能使實際 dev 比例偏離目標；不透過拆開群組湊數。raw 未取得或資料不足時退出碼為 1，不宣稱通過最低筆數。

```sh
uv run --directory DevLab/D512Eval/testset --offline --no-sync python scripts/validate.py data/generated/dev.jsonl data/generated/held-out.jsonl --minimum-held-out 3000
uv run --directory DevLab/D512Eval/testset --offline --no-sync python -m unittest discover -s tests -v
uv run --directory DevLab/D512Eval/testset --offline --no-sync python scripts/verify.py --reproduce
```

下載器預設依序擷取固定 64 個一般知識條目；重試會使用已保存的單頁 HTTP 回應，完整 manifest 存在時拒絕覆寫。若本機 DNS 無法解析，透過 HTTPS 查 Google 公開 DNS，再用 `curl --resolve` 指定查到的 IP；TLS 仍驗證原 hostname，不變更系統設定。Mozilla 檔案固定 commit 與 Git blob；Wikipedia raw 記錄當次 revision 和 SHA-256。相同 raw、詞庫與 seed 可重現；重新取得新 revision 不保證與舊版一致。

## 標註、隔離與統計

1. 詞庫跳過註解；兩列尾端 `#MACOS` 當註解解析。拒絕非漢字、字音數不等或注音格式不符的列，位置記在 `reports/lexicon-stats.json`／`stats.json`。
2. 分詞使用 **Viterbi／DAG DP**，最大化 `sum(log(max(freq,1)/Z))`；詞邊頻次取詞條最高頻，單字邊取現有最高頻投影讀音的累計頻次，`Z` 為所有詞／字邊有效頻次之和。零頻取 1，避免 `log(0)`；分數差至多 `1e-12` 視為同分，由左至右優先較長詞。所有邊用同一 Z，避免直接累加原始對數頻次時幾乎逐字切分。貪婪最長匹配只保留作新舊比較，不再產生 reading。
3. **選好 DP 路徑後**套既有讀音規則：最高頻並列異讀詞條使整句丟棄，不改選次佳路徑。單字 fallback 遇多種投影讀音使整句丟棄；非多音字照舊。唯一的單字例外表仍是 **了→ㄌㄜ˙、的→ㄉㄜ˙、嗎→ㄇㄚ˙、呢→ㄋㄜ˙、吧→ㄅㄚ˙**，只在單字 fallback 時套用，不改詞條讀音或分詞頻次。例如「阿拉伯語中的」切為「阿拉伯語＋中＋的」，但中仍屬多音字 fallback，整句排除。沒有新增其他助詞或語境規則，也沒有另讀單字字典。
4. NFC 正規化後按 Unicode 標點分句。未知字出現時丟棄整個標點分句；不刪除英文／數字後拼接漢字。合法長句連續切為 2–32 音節，33 字分成 31＋2，避免留下孤字。前文只取同一原段落的前一標點分句；打散的聊天各行視為獨立文件、前文留空。
5. 切分前以 **gold 全域去重，保留第一次出現**；第一次指固定來源／文件排序後的產生器遍歷順序。然後按原文件分組，以固定 seed 分割並依來源分層。相同 gold 即使前文不同也不再出現，dev／held-out 的 gold 交集必須為空。`split-manifest.json` 保存案例、文件、群組與分割的對應。未做整篇近重複稽核，不能聲稱已隔離所有相似文章。
6. `stats.json` 保存案例數、來源、2–32 音節分佈、字數、多音字出現次數／總字數、含多音字案例數、三種讀音丟棄句數與比例，以及 `segmentation_comparison` 的比較句數、切分變更句數與五筆例子。切分比較以至少兩字且每字可投影讀音的原始標點分句為單位，發生於丟棄前；不能與輸出案例數混用。三種反查丟棄比例皆以反查嘗試分句數為分母，先排短句、未知字，再按 DP 路徑遇到的第一個異讀原因互斥計數。多音字含變調與零頻項，不等同人工判讀的歧義率。

schema 位於 [case.schema.json](data/case.schema.json)；自檢額外驗證每音節一漢字、五聲調位置、全域 ID／gold／前文＋目標唯一性及 held-out 筆數。`verify.py --reproduce` 比對六檔 SHA-256，驗證 raw 未變、文件／gold 不跨集與初審／複審錯例處置，並更新 [verification.json](reports/verification.json)。DP 前的數字與摘要保存於 `reports/pre-dp-state.json`。若 held-out 不足 3,000，產生器只寫 `reports/insufficient-data.json` 診斷，停止並等待使用者決定，不自動放寬讀音規則或改寫正式 JSONL。大檔、raw、`.venv` 與暫存檔均忽略。

## 評測界線

本集是輸入讀音／參考文字，尚未由 dumper 產生候選，故不提供 top-1、oracle 或重排延遲。詞庫反查標籤尚未人工校正；沒有公開的 0c 訓練逐句清單可查重，也未實作 MinHash 近重複稽核。百科前文是參考文字，沒有模擬前次引擎錯誤。用 dev 校準 `w/τ`，held-out 只作最終評測；不可挑選候選內已有 gold 的案例再算主指標。

論文協定與頁碼見 [paper-summary.md](notes/paper-summary.md)。
