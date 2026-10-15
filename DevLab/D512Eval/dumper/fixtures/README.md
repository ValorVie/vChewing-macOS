---
title: D512Dump 原廠候選匯出
type: guide
date: 2026-10-15
author: ValorVie
status: review
---

# D512Dump 原廠候選匯出

`D512Dump` 是離線 SwiftPM 可執行目標，輸出 D512 評測用的候選 JSONL。它只查詢原廠繁體中文詞庫，不建立輸入法 session。這裡的十筆手寫案例與輸出用於功能驗證，不是模型效果評測集；手寫案例以 CC0-1.0 提供。

本輪 baseline 是**原廠詞庫、純 unigram、無 POM／個人選字學習**，比使用者日常含個人學習的實際引擎弱。閘門報告須註明這個差別；對此 baseline 的重排增益不代表對日常個人化引擎有相同增益。

## 執行

在 dumper worktree 根目錄執行，先備妥官方 `vChewing-VanguardLexicon` **4.8.8** 生成的 `VanguardFactoryDict4Typing.txtMap`，放在 `DevLab/D512Eval/dumper/.cache/`。詞庫與下載快取不入庫。程式不自動搜尋 App bundle 或任何使用者目錄。

若尚無詞庫，可在此 worktree 內取得專案原已相依的官方來源並生成（不執行安裝指令）：

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
git clone --depth 1 --branch 4.8.8 \
  https://github.com/vChewing/vChewing-VanguardLexicon.git \
  DevLab/D512Eval/dumper/.cache/VanguardLexicon
(
  cd DevLab/D512Eval/dumper/.cache/VanguardLexicon
  env -u SMALL_TESTABLE_SAMPLE swift run --configuration release VCDataBuilder vanguardTextMap
)
cp DevLab/D512Eval/dumper/.cache/VanguardLexicon/Build/Release/vanguard-textmap/VanguardFactoryDict4Typing.txtMap \
  DevLab/D512Eval/dumper/.cache/VanguardFactoryDict4Typing.txtMap
```

以下指令產生兩種輸出並驗證：

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift build --package-path Packages/vChewing_OSNeutral_LibVanguard
swift run --package-path Packages/vChewing_OSNeutral_LibVanguard D512Dump \
  --factory DevLab/D512Eval/dumper/.cache/VanguardFactoryDict4Typing.txtMap \
  --input DevLab/D512Eval/dumper/fixtures/cases.jsonl --mode span \
  > DevLab/D512Eval/dumper/fixtures/span.jsonl
swift run --package-path Packages/vChewing_OSNeutral_LibVanguard D512Dump \
  --factory DevLab/D512Eval/dumper/.cache/VanguardFactoryDict4Typing.txtMap \
  --input DevLab/D512Eval/dumper/fixtures/cases.jsonl --mode nbest --k 8 \
  > DevLab/D512Eval/dumper/fixtures/nbest.jsonl
python3 DevLab/D512Eval/dumper/fixtures/check_schema.py \
  DevLab/D512Eval/dumper/fixtures/cases.jsonl \
  DevLab/D512Eval/dumper/fixtures/span.jsonl \
  DevLab/D512Eval/dumper/fixtures/nbest.jsonl
swift test --package-path Packages/vChewing_OSNeutral_LibVanguard
```

JSONL 寫到 stdout，診斷寫到 stderr。`--factory`、`--input`、`--mode` 必填；`--k` 預設 8，範圍 1–8。單一案例的語義或引擎失敗會略過並繼續；至少一案成功且沒有結構性錯誤時回傳 exit code 0。詞庫／檔案載入失敗、JSON 格式或欄位型別錯誤、重複 id、零成功案例仍回傳 exit code 1。檢查 exit code 後才使用輸出，因為結構性錯誤仍可能留下前段輸出。`--help` 顯示用法。

stderr 的逐案例診斷為單行 JSON，例如 `{"event":"skip","id":"bad","reason":"invalid_reading","detail":"..."}`，id 與原因碼可供整合端追蹤。結尾的 `event: "summary"` 列出 `processed`（已解碼案例）、`succeeded`、`skipped`、`requests` 和各 `skip_reasons` 次數。每案先完整建立並編碼所有請求，才寫到 stdout，失敗案例不會留下半個案例的輸出。結構性錯誤時，summary 只涵蓋已處理的前綴，另有致命診斷。

| 案例略過原因碼 | 意義 |
| --- | --- |
| `invalid_case`／`invalid_reading` | 案例字音長度、範圍或 Tekkon 表記不合規 |
| `no_factory_reading` | 至少一個讀音沒有可用的對齊原廠 CHT gram |
| `path_coverage`／`non_aligned_gram` | 路徑不完整或字音不對齊 |
| `score_invariant`／`beam_score` | 預設最高分或路徑計分檢查失敗 |
| `engine_error` | 其他單一案例的引擎錯誤 |

## 正式 App 的原廠載入路徑

本次調查使用 `rg` 搜尋 `factoryTrie`、`VanguardTrie.TextMapTrie`、`LibVanguardChewingData` 與原廠資源檔名，追到以下路徑：

1. [MainAssembly4Darwin manifest](../../../../Packages/vChewing_MainAssembly4Darwin/Package.swift) 已相依原廠詞庫 4.8.8，`VanguardTextMapPlugin` 於建置時生成資源。App 未直接 import `LibVanguardChewingData`；該模組是原廠的建置工具資料層。
2. [LXMgr_Core.swift](../../../../Packages/vChewing_MainAssembly4Darwin/Sources/MainAssembly4Darwin/LXManager/LXMgr_Core.swift) 的 `connectCoreDB(dbPath:)` 將原廠檔案路徑交給 `LXAssembly.LXFacade.connectFactoryDictionary(textMapPath:)`。
3. [LXFacade_TextMapExtension.swift](../../../../Packages/vChewing_OSNeutral_LibVanguard/Sources/LexiconAssembly/LXFacade_TextMapExtension.swift) 以 `Data(contentsOf:options: [.mappedIfSafe])` 讀取檔案，再建立 `VanguardTrie.TextMapTrie(data:)`。bundle 只負責定位資源，後端可直接讀一般 `.txtMap` 檔。
4. `D512Dump` 沿用同一 Data／TextMapTrie 後端，以及 exact factory CHT lookup 的正分數轉負分數規則。CHT type ID 為 6，與 [LX_TrieKitImpl.swift](../../../../Packages/vChewing_OSNeutral_LibVanguard/Sources/LexiconAssembly/LX_TrieKitImpl.swift) 的 `.cht` 相同。

可執行目標只相依 `Homa`、`TrieKit`、`Tekkon`，不建立 `LXFacade` 的共用物件，因此不會初始化它的使用者片語、POM 或偏好模組。沒有增加外部相依，也沒有更動 App 的資源查找或 IME 行為。

## 讀音與分數尺度

[Tekkon_Constants.swift](../../../../Packages/vChewing_OSNeutral_LibVanguard/Sources/Tekkon/Tekkon_Constants.swift) 定義聲調 `ˊ ˇ ˋ ˙`，一聲在 composer 內部可用空白，但辭典查詢字串不帶空白。程式以 `Tekkon.Composer.receiveKey(fromPhonabet:)` 和 `getComposition()` 驗證並要求輸入原樣吻合：例如 `ㄒㄧㄠ`、`ㄒㄧˊ`、`ㄕˇ`、`ㄕˋ`、`ㄉㄜ˙`。輕聲在右側；左側輕聲、數字聲調、空白與逆序符號會被拒絕。每案 2–32 音節，每音節一個 Unicode scalar，未知讀音會由 Homa 拒絕。

原廠 4.8.8 的 [Unigram.weighten(norm:)](https://github.com/vChewing/vChewing-VanguardLexicon/blob/4.8.8/Sources/LibVanguardChewingData/SubCodes/BaseTypes/Unigram.swift) 使用 `log10` 計算頻率與字長修正後的權重，並保留小數點後三位；部分類別另有固定權重。[TextMap builder](https://github.com/vChewing/vChewing-VanguardLexicon/blob/4.8.8/Sources/LibVanguardChewingData/SubCodes/Builders/DataBuilder_VanguardTextMap.swift) 再將權重輸出到原廠檔案。這是引擎排名權重，不是經正規化的整句機率。

`log_score` 不再取一次對數，也不轉為自然對數 ln。span 的分數是該 gram 的權重；nbest 是路徑各 gram 的權重和。沿用正式 exact lookup 將正權重取負值的處理。不包含 bigram、trigram、backoff、POM、個人選字學習、使用者片語或覆寫加權；`case.context` 只供後續模型使用，不加入引擎計分。每行 `score_scale` 明列原廠純 unigram baseline、與日常個人化引擎的差別及上述尺度。

### 候選 0 分數最高的契約與取捨

兩種 mode 的 `candidates[0]` 都是引擎預設，且其 `log_score` 必須是該請求的最大值，並列可接受。程式在輸出請求前以嚴格 `>=` 檢查，不加容差、不調高分數或重排預設；違反時回傳錯誤。schema 自檢亦嚴格驗證最大值。

span 採用補充契約允許的**同節點 gram 分數**方案。調查 [Homa 的覆寫 API](../../../../Packages/vChewing_OSNeutral_LibVanguard/Sources/Homa/Homa_MainComponents/Homa_CandidateAPIs_FetchAndApply.swift) 後確認，`overrideCandidate` 的 `.withSpecified` 預設會使用 `114514` 強制分數並修改重疊節點；`.withTopGramScore` 則以最高 unigram 分數計分，並非選中候選的原始分數。這些操作有加權與狀態副作用，不能直接當成原廠 log10 分數，因此沒有採用「覆寫後重組整句」評分。

目前只有獨立 unigram、無覆寫／語境加分：Homa 最佳路徑的每個節點使用該節點最高分 gram。同節點候選的局部 gram 分數自然滿足候選 0 最高；固定原分段時，其他段的分數也是共同常數。此方式保留候選間的原廠分數差值，但不模擬覆寫後重新斷詞或個人化的整句重組。若將來供給路徑加入個人化或語境分數，不能沿用此保證而略過重新設計。nbest 仍使用原有路徑總分。

## 兩種模式與座標

`span` 沿 Homa 既有最佳路徑的分段輸出。候選由 `fetchCandidates(at:filter: .beginAt)` 取得，再保留同讀音節點、同長度的 gram，最佳路徑的 gram 放在第 0 位。每段至多 16 個不同文字。context 為原案例前文，加上最佳路徑在該段左側的文字；gold 切取相同音節區間。單音節段另有 `text_mode: true`。

`nbest` 在 [HomaBeam.swift](../../../../Packages/vChewing_OSNeutral_LibVanguard/Sources/D512Dump/HomaBeam.swift) 提供可執行目標內專用的擴充。它讀取既有 lattice，每個終點保留 k 個分數最高的不同文字前綴，擴展節點內所有 unigram。對目前的獨立 unigram 分數與一音節一字限制，這保留該 lattice 的 k 個最高分不同文字；同文字的不同分段只保留最高分那條。並列最高分以既有 Homa 預設的文字與分段為準。它不改寫 assembler、`assemble()`、`PathFinder.run` 或原有 Homa 檔案。最多輸出 8 個不同文字。

`span` 的 `[start,end]` 是原案例 reading 的左閉右開座標。每個 candidate 的 `segments[].Start/End` 都從該請求的 reading 起點 0 計算，左閉右開，與 candidate text 對齊；`Word` 是該段文字，`Partial` 和 `Correction` 恆為 false。`engine_default` 恆為 0，`gold_in_candidates` 由實際候選計算，gold 不會被額外注入。

## 驗證與限制

[check_schema.py](check_schema.py) 只使用 Python 標準函式庫，驗證候選上限、去重、字長、座標、有限分數、gold 命中、完整 span 覆蓋及 context，並交叉比對兩種模式的候選 0 與總分。它也會拒絕比候選 0 高 `1e-12` 的非預設候選。Swift 的 `D512DumpTests` 用手算小型 lattice 驗證最高分去重、候選 0、分段、上下文、oracle 未命中、k 上限、讀音拒絕及低於其他候選的預設值拒絕。

### 正式原廠供給路徑同等性

[D512DumpEquivalenceTests.swift](../../../../Packages/vChewing_OSNeutral_LibVanguard/Tests/D512DumpTests/D512DumpEquivalenceTests.swift) 用**同一份完整 TextMap**，分別經 CLI 實際共用的 standalone 載入器，以及 `LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData:)` 搭配正式 `LXFactoryGramSupplier`，以 CHT `.cht`（相當於 `isCHS=false`）餵給另一個 Homa.Assembler。

使用者已確認採用這條靜態載入＋factory supplier 參考路徑，避免完整 `LXFacade` 實例的 `PrefMgr`／UserDefaults 初始化。比對不載入使用者片語或 POM，也不呼叫全域偏好同步。正式 supplier 不沿用 standalone 的資格過濾或分數轉換程式碼，因此能獨立檢查這些處理的影響。

最初 10 案的完整 `assembledSentence`（含 gram 內容／分數與明確覆寫旗標）和整句總分逐項相同；22 個 span 的 `fetchCandidates(.beginAt)` **全部 696 個候選**在長度過濾與 16 候選裁切前，讀音、文字、順序、分數亦逐項相同，沒有差異。歷史結果在 [equivalence.json](equivalence.json)。測試現接受任意非空案例集，報告與訊息列出實際案例／span／候選數及 `all_equal`，並逐一驗證每個輸入前綴的路徑與總分。真實 held-out 的 200 案（150 案 >10 音節、50 案 ≤10 音節）、2,320 個前綴、1,219 spans、35,202 個完整有序候選均相同，見 [held-out-equivalence-200.json](../reports/held-out-equivalence-200.json)。

同等性範圍為原廠 CHT、exact reading、純 unigram、預設節長上限 10 的持續逐音節組字；未啟用 POM／個人學習／覆寫、CNS、符號／日期巨集或組字溢位提交，不宣稱等同完整 LXFacade／IME 事件流程或所有語料。

在 worktree 根目錄可重跑；未指定資料環境變數時，這個需完整原廠檔案的測試會略過，九個純 Swift 核心測試仍執行：

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
D512_FACTORY_TEXTMAP="$PWD/DevLab/D512Eval/dumper/.cache/VanguardFactoryDict4Typing.txtMap" \
D512_DUMPER_CASES="$PWD/DevLab/D512Eval/dumper/fixtures/cases.jsonl" \
D512_EQUIVALENCE_REPORT="$PWD/DevLab/D512Eval/dumper/fixtures/equivalence.json" \
swift test --package-path Packages/vChewing_OSNeutral_LibVanguard --filter D512Dump
```

本目標只匯出繁體中文原廠 exact unigram。未支援 CNS fallback、部分匹配、簡拼、更正、使用者詞庫、前文引擎調分或非一音節一字資料。nbest 只涵蓋 Homa 既有 lattice（預設最大幅節長度 10），不宣稱列舉詞庫中每個任意長詞。原有 Homa 分數並列的取捨仍由引擎決定。

### 長輸入與非一音節一字條目

held-out 案例 `d512-003a6e0b826f8b78c0e8a0db`（「但正式場合使用文言文體」，11 音節）的原失敗是 **dumper 建圖 bug**，不是詞庫字音不對齊。一次 `insertKeys` 在 cursor 0 時只更新前 10 格的增量視窗，第 11 格無節點，Homa 最佳路徑為空。首次修正曾以 `refreshExisting` 全建 lattice；載入器與正式 supplier 參照測試現都依真實輸入流程，對每個完成的音節呼叫 `insertKey`，由既有增量建圖自動 `assemble`，不再使用全刷新。11／32 音節測試及該案的兩種 mode 均已通過；這案不應被略過。

正式路徑為 `InputHandler.handleComposition` → `BPMFFullMatchTypewriter.composeReadingIfReady` → `assembler.insertKey(readingKey)`（`Typewriter_BPMFFullMatch.swift:409`）。Homa 在每次插入後、游標遞增前，依當時游標填入增量視窗並組句（`Homa_Assembler.swift:189–222、371–445`）；逐音節插入會讓視窗沿整句移動。舊同等性測試卻一次插入整句，因此五批 50 個長句的參照路徑全部為空、分數為不可達值 `-2147483648`。逐案雙邊路徑／總分與修正結果見 [longbatch-reference-differences.json](../reports/longbatch-reference-differences.json)；這是參照建圖方式的錯誤，不能據此推論 factory supplier 的詞條或分數不同。

同一原廠 4.8.8 TextMap 的稽核顯示，該案可匹配的 313 個 raw CHT 詞條皆對齊。252,827 個 raw CHT 詞條中另有一筆三音節 `ㄉㄠˋ-ㄙㄢ-ㄐㄧㄠˇ` 對應四字「倒三角形」。其他型別也有非一音節一字資料：符號詞語的 `ㄔˇ-ㄗ˙` 對應 `📏`、三音節長頸鹿對應 `🦒`；假名的 `ㄅㄧㄚ` 對應兩字 `びゃ`；注音文的一音節可輸出多個注音符號。符號還可能含多個 Unicode scalar 的組合或變體選擇符。

上述非對齊條目不能直接表示成這次要求的一音節一個 Unicode scalar，原有資格過濾會排除它們；本目標不補字、不猜讀音，也不改原廠資產。若其他對齊條目仍可組句，就保留案例；若案例無可用對齊路徑，略過並記錄原因才合理。原長句建圖錯誤則已修正，不以略過掩蓋。

此次已通過 10 案、22 個 span 請求與 10 個 nbest 請求；其中 6 個 span 為單音節。原廠預設包括「我愛城市」與「試試的消息」，各案的 gold 沒有被預先放進候選。來源版本、原廠檔案與三個 JSONL 的 SHA-256 記在 [provenance.json](provenance.json)。
