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

請測試手選後繼續輸入、Enter、F1、Esc、關閉開關、切換客體與重新啟動。關閉重排開關應還原原有組句，保留讀音、游標與手選區段。若行為與此不符，關閉兩個開關，保留校準資料供檢查；需要回復安裝時依建置與安裝指南還原 app 與資料。

## 收集校準資料

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
| `applied` | 是否真正套用 D512 pin |
| `personalConflict`、`pomConflict` | 已套用結果是否與個人 pin／POM 自動覆寫衝突 |
| `weight`、`margin`、`bonus` | 當次 w、τ、b |
| `finalCommittedText` | 實際送出文字；可能已經過既有文字轉換 |

## 重算融合與調整參數

v1 使用 `raw + w × modelLogP + b × personalHits`。預設 w=0.5、τ=0.5、b=2.0；b 是待校準的初始值。既有 [Python harness](../harness/README.md) 的原始閘門只涵蓋 raw＋模型，不含個人加權；不要直接將 v1 紀錄當成原始閘門輸入。

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

確定新值後，先切換到其他輸入法並結束唯音行程，依建置與安裝指南備份偏好 plist。SwiftPM sandbox app 的偏好位置如下；其他打包方式請核對實際備份位置：

```sh
vch_prefs="$HOME/Library/Containers/org.atelierInmu.inputmethod.vChewing/Data/Library/Preferences/org.atelierInmu.inputmethod.vChewing"
defaults write "$vch_prefs" D512RerankWeight -float 0.5
defaults write "$vch_prefs" D512RerankMargin -float 0.5
defaults write "$vch_prefs" D512RerankPersonalBonus -float 2.0
defaults read "$vch_prefs" D512RerankWeight
defaults read "$vch_prefs" D512RerankMargin
defaults read "$vch_prefs" D512RerankPersonalBonus
```

重新啟動唯音，開啟短期紀錄，核對新事件中的三個參數並重做使用驗收。若沒有改善，停止校準並還原偏好備份；這三個隱藏鍵不需要重新建置 app。
