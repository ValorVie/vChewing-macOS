# D512Eval：D512 離線重排評測 harness

用公開模型 [`Funmula/0c-sequence-d512`](https://huggingface.co/Funmula/0c-sequence-d512)（MIT，固定 revision `d512-pf512-20260926`，commit `66eb4a81…`）替 Homa 引擎倒出的候選重新評分，量測重排前後的 top-1 準確度與延遲。全部檔案位於 `DevLab/D512Eval/harness/`，以下命令都在此目錄執行；程式內路徑都以 `__file__` 為基準，與當下工作目錄無關。

## 檔案

| 檔案 | 說明 |
|---|---|
| `d512eval.py` | 下載、雜湊核對、評分（逐候選，照模型卡範例移植）、評測、報告 |
| `test_d512eval.py` | 自檢：`test_pure_*` 不需模型（`choose()` 門檻與權重、`evaluate()` 覆蓋計數與 delta、輸入契約、雜湊不符必失敗、空輸入與網格旗標解析 exit 2）；其餘需模型（fixture 全流程、與模型卡範例逐張量等價、text 模式張量與回退、自訂網格與對照表截斷、輕聲備援開關） |
| `fixtures/harness/requests.jsonl` | 20 筆自造 fixture（分數為假造，不代表引擎實際表現） |
| `fixtures/harness/text_probe.jsonl` | 6 筆單音節探針：5 組「前文＋常見字 vs 罕見同音字」與 1 筆無前文 |
| `reports/fixture-harness.{md,json}`、`reports/text-probe.{md,json}` | 兩份 fixture 上的範例報告 |
| `models/`、`.venv/` | 不進 git |

## 安裝

```sh
cd DevLab/D512Eval/harness
uv venv --python 3.14 .venv            # onnxruntime 無對應 wheel 時改 --python 3.12
uv pip install --python .venv/bin/python numpy onnxruntime huggingface_hub
```

實測環境（2026-10-15，以上兩行命令 exit 0）：Python 3.14.5、onnxruntime 1.31.0（有 cp314 wheel）、numpy 2.5.4、huggingface_hub 2.2.0。

## 用法

```sh
.venv/bin/python test_d512eval.py                       # 自檢
.venv/bin/python d512eval.py --input fixtures/harness/requests.jsonl --out reports/fixture-harness
```

- 首次執行若 `models/d512-pf512-20260926/model.onnx` 不存在會自動下載；每次執行都會依 `manifest.json` 核對 `model.onnx`、`vocab.json` 的 SHA-256，不符即拋 `HashMismatch` 中止。
- 先驗證輸入契約（見下），不合規即以行號中止，不下載也不載入模型。
- `--no-neutral` 關閉輕聲備援（見「與模型卡的對應」）。
- `--no-text-mode` 讓單音節請求也走 phonetic 任務（見「單音節 text 模式」）。
- `--threads`（預設 2，onnxruntime `intra_op_num_threads`）、`--bootstrap`（預設 1000）、`--model-dir`。
- `--weights 0.5,1,1.5`、`--margins 0.5,1,2` 覆寫 w／τ 網格（逗號分隔的有限數值；格式錯誤 exit 2）。預設不變：w∈{0,1,2,3,5,8}、τ∈{0,0.25,0.5,1}。只影響網格掃描，manifest 操作點一律取自 manifest。
- 報告末段「text 模式與 phonetic 模式分數對照」預設只列前 50 筆 text 請求並註明總數；`--text-compare-all` 列出全部。完整分數一律在 JSON 的 `per_request`。
- 輸入為 0 筆請求時直接報錯 exit 2，不下載也不載入模型。
- 輸出 `<out>.md`（報告）與 `<out>.json`（`meta`、`summary`、`grid`、`subsets_at_manifest_point`、逐請求模型分數與延遲 `per_request`）。

## 與模型卡的對應

`Scorer.log_prob`／`Scorer.score` 逐行移植模型卡 Python 範例。`test_matches_model_card` 會從已下載、固定 revision 的 `models/<rev>/README.md` 抽出範例程式碼直接執行，對 fixture 每個可評分候選比對送進 ONNX 的九個張量（名稱、dtype、shape、值）、推論次數（含輕聲備援）與最終分數，必須完全相同。與範例的刻意差異只有：輕聲備援可關閉（`--no-neutral`）、session 指定 `intra_op_num_threads`、字表外字元在送模型前就判定整例回退（範例是 `KeyError` 後回退，結果相同）。

輕聲備援的比對範圍：規則比對的是最後音節的**基底**（去掉聲調記號後），所以 `ㄅㄚ`、`ㄅㄚˊ`、`ㄅㄚˇ`、`ㄅㄚˋ` 只要基底在 `neutral_tolerant_last` 內、且本身不是 `˙`，都會另以 `基底˙` 再評分一次並取較大者。這與模型卡範例逐字相同。manifest 另有 `neutral_expand_penalty=4.0`，看起來是宿主端的候選擴充：把句尾改讀輕聲後**新增**的候選扣分。本 harness 只對 dumper 給的候選重新評分、不新增候選，因此不實作這一項。

## 單音節 text 模式（`--text-mode`，預設開）

manifest 的 `limits.text_mode = "single_syllable_with_confirmed_context"` 與 `text_weight=2.0`、`text_margin=1.0` 表示 1 音節請求改以「只看前文續寫」的 text 任務評分。這是依 manifest 欄位推論，模型卡沒有明文。

- 條件：讀音恰 1 音節且 `context` 非空。沒有前文時退回 phonetic 任務，並計入 `text_mode_no_context_phonetic`。
- 張量：`[BOS] 前文(≤64) [SEP] [OUT] 候選[:-1]`，不放讀音 token；`bases`／`tones` 全 0，`types` 前段與 `[OUT]` 為 0、候選前綴為 2，`positions` 連續，`proj_pos`／`target_node`／`target_ids` 與 phonetic 同規則。讀音只用來核對候選長度。
- text 任務的 logP 是對整個字表的分布，沒有讀音約束，所以尺度和 phonetic 不同。報告的 manifest 操作點對 text 請求改用 `text_weight`／`text_margin`；w／τ 網格則所有請求共用一組。
- 經驗驗證：`reports/text-probe.md` 與 `reports/fixture-harness.md` 末段並列兩種模式的分數。7 組全部都是常見字最高，ONNX 也接受這個形狀。

## 輸入格式（D512Dump 輸出的 JSONL，一行一個請求）

```json
{"id":"...","mode":"span","span":[0,2],"context":"今天天氣很好我們去","reading":["ㄍㄨㄥ","ㄩㄢˊ"],
 "candidates":[{"text":"公元","log_score":-7.0,"segments":[{"Start":0,"End":2,"Word":"公元","Partial":false,"Correction":false}]}],
 "engine_default":0,"gold":"公園","gold_in_candidates":false,"score_scale":"...","text_mode":false}
```

必要欄位：`id`、`context`、`reading`、`candidates[].text`、`candidates[].log_score`、`gold`。以下任一不符即以行號報錯中止：

- 每個候選 `text` 長度須等於音節數且不重複，`log_score` 須為數值。
- `engine_default`（省略時為 0）須是整數且 `0 ≤ engine_default < len(candidates)`。
- **`log_score[engine_default]` 必須是所有候選中的最大值（並列可）。** 原因：重排公式在 w=0 時退化為引擎分數的 argmax。若預設不是最高分，w=0 也會覆蓋，「w=0 ≡ baseline」這個閘門不變量就不成立，baseline 與重排的比較會被污染。並列不影響，因為覆蓋需要嚴格 > τ。dumper 端須保證候選 0 的分數為路徑總分最高。

`mode` 只用於分組；分組名 `text_mode` 指實際以 text 任務評分的請求，`single_syllable_phonetic` 指退回 phonetic 的單音節請求。

## 指標定義

- baseline top-1：`candidates[engine_default].text == gold`。oracle：gold 在候選內（與 `gold_in_candidates` 欄位不符時計數）。
- 重排：`fused = log_score + w × model_score`；只有非預設候選的 fused 以 **> τ** 勝過預設才覆蓋。網格預設 w∈{0,1,2,3,5,8}、τ∈{0,0.25,0.5,1}，可用 `--weights`／`--margins` 覆寫。
- 有益覆蓋：baseline 錯、重排對；有害覆蓋：baseline 對、重排錯；中性覆蓋：改選了但兩者皆錯。
- 95% CI：每請求 (重排 − baseline) 的 paired bootstrap，1,000 次重抽，固定種子。
- 整例保留預設（不送模型，計入 `fallbacks`）：候選含字表外字元（`oov`）、任一 segment `Correction: true`（`correction`）、超過 32 音節或 16 候選（`out_of_limits`）、讀音基底不在字表（`bad_reading`）。
- 延遲：每請求評分全部候選（含輕聲備援的額外推論）的牆鐘時間；先以第一筆可評分請求暖機 3 次並排除。

## 已知限制

- 只做逐候選評分，未做前綴樹批次評分（模型卡稱分數相同、只差速度；延遲數字因此偏保守）。
- text 模式是依 manifest 推論的實作，不在模型卡內；`neutral_expand_penalty` 不實作（理由見上）。
