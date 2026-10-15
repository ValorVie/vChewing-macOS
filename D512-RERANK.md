---
title: D512 句級重排安裝與校準
type: guide
date: 2026-10-15
author: vChewing Project
status: experimental
---

# D512 句級重排安裝與校準

此功能需要 macOS 14 或更新版本。主開關與校準紀錄開關預設都關閉；請先備份、安裝，再放入固定版本模型。安裝與 IMK 客體行為需要在使用者機器上驗收。

## 建置與安裝

在 repository 根目錄以 Swift 6.4 或更新工具鏈執行 `make release`。產物為 `Build/Products/Release/vChewing.app` 與 `vChewingInstaller.app`。依[建置與安裝指南](../../../BUILD-INSTALL.md)備份目前 app、偏好設定、詞庫、POM 與個人排序資料，再由使用者執行安裝程式。安裝後先保持兩個 D512 開關關閉。

模型目錄固定為輸入法行程的 `Application Support/vChewing/D512/d512-pf512-20260926/`，不受自訂詞庫目錄影響。SwiftPM 組裝的 app 啟用 sandbox，對應使用者磁碟位置如下：

```sh
vch_support="$HOME/Library/Containers/org.atelierInmu.inputmethod.vChewing/Data/Library/Application Support"
vch_model_target="$vch_support/vChewing/D512/d512-pf512-20260926"
vch_model_source="/path/to/d512-pf512-20260926"

# 先安裝並啟動過一次唯音，再切換到其他輸入法及結束唯音行程。
# 若目標已有模型，先保留一份備份。
if test -d "$vch_model_target"; then
  ditto "$vch_model_target" "$vch_model_target.backup-$(date +%Y%m%d%H%M%S)"
fi
mkdir -p "$vch_model_target"
for vch_file in model.onnx vocab.json manifest.json; do
  test -f "$vch_model_source/$vch_file" || exit 1
  cp "$vch_model_source/$vch_file" "$vch_model_target/$vch_file"
done
shasum -a 256 "$vch_model_target/model.onnx" "$vch_model_target/vocab.json"
```

應得到：

| 檔案 | SHA-256 |
| --- | --- |
| `model.onnx` | `71af1f0e77b2752cc71cbc04bf19c8e8f2e765662246f766e65a2822bab4e66e` |
| `vocab.json` | `556dffaffbf4c05211a846dcee55ef735cea68c5754f9bffcc6f9588124172b3` |

`manifest.json` 提供輕聲備援規則，需使用同一模型版本的檔案；目前不在 SHA-256 釘選範圍。若上述雜湊不同，停止啟用，還原備份或重新取得指定版本模型。

重新啟動唯音，開啟設定的「候選字」頁，勾選「使用 D512 句級重排（實驗性）」。缺檔、驗證失敗或 macOS 版本不足時，開關停用並顯示原因。模型更換後需重新啟動行程，背景評分器不支援熱換模型。

## 驗收使用效果

輸入完整的 2–32 音節句子，停頓約 150 ms。模型贏過目前畫面句，且融合差距嚴格大於 τ，才更新組字內容；否則畫面保持原句。字表外字元、讀音不完整、修正型候選或推論失敗均保留原句。

手選區段固定。模型可以蓋過個人偏好或繞過 POM 自動覆寫；這些模型選擇不回饋個人學習、POM 或使用者詞庫。下一鍵先撤回 D512 pin，重新套用個人偏好；Enter 送出當時畫面所示的文字。前文只在 session 記憶體保存最近 64 個已實際送出字元，切換客體或失焦時清空。

### 切換客體後的第一句

前文只存在記憶體，切換 App、輸入欄失焦或換 session 都會清空，所以切過去之後送出第一句以前，模型是在沒有前文的狀態下重排；之後每次送出都會累積前文。離線 held-out 7,190 句、w=0.5、baseline 82.43% 的實測（有前文取自 [A1 閘門報告](../reports/gate/gate-report.md)，無前文取自 [無前文重跑](../reports/noctx/report-noctx.md)）：

| 前文 | τ | 重排 top-1 | Δ (pp) | 有害／有益 | 閘門（≥ +3.0 pp 且有害 ≤ 有益 1/3） |
| --- | --- | --- | --- | --- | --- |
| 有 | 0.5（預設） | 86.59% | +4.16 | 112／411 = 0.27 | 通過 |
| 有 | 1.0 | 86.84% | +4.41 | 61／378 = 0.16 | 通過（參考點，非 dev 選出） |
| 無 | 0.5（預設） | 85.35% | +2.92 | 136／346 = 0.39 | 兩項都不過 |
| 無 | 1.0 | 85.73% | +3.30 | 82／319 = 0.26 | 通過 |

v1 只有單一 τ，沒有針對無前文另設門檻。試用時若覺得「切過去的第一句常被改掉」，這是已知取捨，不是模型或安裝出問題。校準時可把隱藏鍵 `D512RerankMargin` 調成 1.0：無前文時改壞比降到 0.26；有前文時 held-out 沒有變差，dev 1,794 句則少 0.34 pp（+3.68 → +3.34）。預設維持 0.5，因為閘門協議只在 dev 上選操作點。

請測試手選後繼續輸入、Enter、F1、Esc、關閉開關、切換客體與重新啟動。關閉重排開關應還原原有組句，保留讀音、游標與手選區段。若行為與此不符，關閉兩個開關，保留校準資料供檢查；需要回復安裝時依建置與安裝指南還原 app 與資料。

## 收集校準資料

在「候選字」設定頁選擇 D512 校正模式。預設「自動套用」（`D512RerankMode=0`）維持原有行為；「僅建議」（`D512RerankMode=1`）在停頓後保留畫面句與游標，以 `⇥ 變動片段` 提示建議，多段以 `／` 分隔。主開關關閉時模式選項停用。

僅建議模式可在「接受建議的按鍵」選擇 Tab（預設，`D512SuggestionAcceptKey=0`）、Ctrl+Tab（`=1`）或右方向鍵（`=2`）。右方向鍵只在句尾接受；直排使用下方向鍵，句中仍移動游標並丟棄建議。主開關關閉或模式為自動時，接受鍵選項停用。

選 Tab 時，組字中的無修飾鍵 Tab 專用於接受建議，沒有建議或接受失敗時不改組字、不輪替候選。選 Ctrl+Tab 時，只有單獨按住 Ctrl 的 Tab 接受建議，沒有建議或接受失敗時不改組字、不輪替候選，無修飾鍵 Tab 維持輪替。選方向鍵時，句尾沒有建議或接受失敗會維持原提示音。Shift+Tab 的反向輪替、選字窗內 Tab、狂拼前方讀音的 Tab 固化與自動模式的既有按鍵行為均維持不變。

接受整句勝者的變動節點視同手選：個人排序等實際送出後更新，POM 沿用既有開關與觀察門檻。其他按鍵、Enter、Esc、切換客體或設定重繪會丟棄建議，不因忽略而學習。

勾選「記錄 D512 校準資料」後，事件寫入：

```sh
vch_log="$vch_support/vChewing/D512/calibration.jsonl"
```

這是個人打字資料，包含讀音、所有候選文字、分數與最終送出文字。請只在需要校準的期間開啟，檢查或分享前先去除敏感內容。關閉開關後不再排入新紀錄。

每個事件以相同 `id` 關聯兩列：`phase=rerank` 立即保存計分，`phase=commit` 補上實際送出文字，或以 `phase=cancel` 表示取消／客體已變更。尚未送出的事件 `finalCommittedText` 為 `null`；取消列也為 `null`。

| 欄位 | 內容 |
| --- | --- |
| `reading` | 完整讀音陣列 |
| `candidates` | 每個候選的 `text`、`raw`、`modelLogP`、`personalHits`、`fused` |
| `defaultIndex` | 重排前畫面句；即使不在 k-best 也納入計分 |
| `winnerIndex` | 融合最高分者，尚未套用 τ 門檻 |
| `mode` | `automatic` 或 `suggest`；保存當次評估模式 |
| `suggested` | rerank 時是否真的掛起通過 τ 門檻的建議 |
| `accepted` | commit／cancel 列：suggest 模式以 `true` 表示 Tab 接受、`false` 表示未接受；automatic 為 `null` |
| `applied` | 是否真正套用 D512 pin |
| `personalConflict`、`pomConflict` | 已套用結果是否與個人 pin／POM 自動覆寫衝突 |
| `weight`、`margin`、`bonus` | 當次 w、τ、b |
| `finalCommittedText` | 實際送出文字；可能已經過既有文字轉換 |

suggest 的 rerank 列尚未套用，`applied=false`；Tab 接受後的後續列會補上 `accepted=true` 與 `applied=true`。忽略建議不會改變分數、產生負訊號或新增學習。以下重算腳本仍使用原有分數欄位，新增欄位不影響融合重算。

## 重算融合與調整參數

v1 使用 `raw + w × modelLogP + b × personalHits`。預設 w=0.5、τ=0.5、b=2.0；b 是待校準的初始值。切換客體後第一句若常被改壞，可先試 τ=1.0（見上文「切換客體後的第一句」）。既有 [Python harness](../harness/README.md) 的原始閘門只涵蓋 raw＋模型，不含個人加權；不要直接將 v1 紀錄當成原始閘門輸入。

先複製紀錄。以下命令只用已記下的分數重算選擇，不需要再次推論。修改命令中的三個數值比較結果：

```sh
python3 - "$vch_log" 0.5 0.5 2.0 <<'PY'
import json, sys
path, w, tau, b = sys.argv[1], *map(float, sys.argv[2:])
events = {}
with open(path) as source:
    for line in source:
        event = json.loads(line)
        events[event['id']] = event
for event in events.values():
    if event['phase'] != 'commit':
        continue
    candidates, default = event['candidates'], event['defaultIndex']
    pick = default
    if all(c['modelLogP'] is not None for c in candidates):
        scores = [c['raw'] + w*c['modelLogP'] + b*c['personalHits'] for c in candidates]
        winner = max(range(len(scores)), key=scores.__getitem__)
        if winner != default and scores[winner] - scores[default] > tau:
            pick = winner
    print(json.dumps({'id': event['id'], 'text': candidates[pick]['text'],
                      'submitted': event['finalCommittedText']}, ensure_ascii=False))
PY
```

最終送出文字不能直接當成正確答案，因為使用者可能直接接受模型結果。請人工標註樣本的正確句，再比較有益與有害覆蓋；保留一部分樣本作為未參與校準的驗收資料。

確定新值後，先切換到其他輸入法並結束唯音行程，依建置與安裝指南備份偏好 plist。app 雖啟用 sandbox，但 entitlement 對 `~/Library/Preferences/org.atelierInmu.inputmethod.vChewing.plist` 有 home-relative 讀寫例外，偏好實際存在該處而不是容器內（2026-10-15 實機核對）。請以 domain 名稱讀寫：

```sh
vch_prefs=org.atelierInmu.inputmethod.vChewing
defaults write "$vch_prefs" D512RerankWeight -float 0.5
defaults write "$vch_prefs" D512RerankMargin -float 0.5
defaults write "$vch_prefs" D512RerankPersonalBonus -float 2.0
defaults read "$vch_prefs" D512RerankWeight
defaults read "$vch_prefs" D512RerankMargin
defaults read "$vch_prefs" D512RerankPersonalBonus
```

重新啟動唯音，開啟短期紀錄，核對新事件中的三個參數並重做使用驗收。若沒有改善，停止校準並還原偏好備份；這三個隱藏鍵不需要重新建置 app。
