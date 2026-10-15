#!/bin/bash
# D512 閘門執行腳本（單機、非互動、只讀原始碼與資料）。
# 用途：以 release 版 D512Dump 對 held-out／dev 匯出 span 與 nbest 請求，再以 harness 評分，
#       產出四份報告到 DevLab/D512Eval/reports/gate/。
# 前提：所在 worktree 已含 harness／dumper／testset 三份；harness/.venv 與 harness/models 已就緒；
#       dumper/.cache/VanguardFactoryDict4Typing.txtMap 存在；testset/data/generated/{held-out,dev}.jsonl 已產生。
#       Swift 6.4 需要 Xcode-beta（DEVELOPER_DIR 可由環境覆寫）。
# 用法：bash DevLab/D512Eval/run-gate.sh [OUT_DIR]
# 成功條件：四次匯出 exit 0、略過數為 0 或已記錄；四份 report-*.md 產生；腳本 exit 0。
# 不會異動：原始碼、測試集、模型；只寫 OUT_DIR。
set -Eeuo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
E=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$E/DevLab/D512Eval/reports/gate}
LOG=$OUT/logs
mkdir -p "$OUT" "$LOG"
PKG=$E/Packages/vChewing_OSNeutral_LibVanguard
FACTORY=$E/DevLab/D512Eval/dumper/.cache/VanguardFactoryDict4Typing.txtMap
HARNESS=$E/DevLab/D512Eval/harness
DATA=$E/DevLab/D512Eval/testset/data/generated

echo "[gate] 建置 release D512Dump"
( cd "$PKG" && swift build -c release --product D512Dump > "$LOG/build.log" 2>&1 )
BIN="$(cd "$PKG" && swift build -c release --show-bin-path | tail -1)/D512Dump"
[ -x "$BIN" ] || { echo "[gate] 找不到 D512Dump：$BIN" >&2; exit 1; }
echo "[gate] revision: $(git -C "$E" rev-parse --short HEAD)  factory sha256: $(shasum -a 256 "$FACTORY" | cut -c1-16)"

for split in held-out dev; do
  for mode in span nbest; do
    IN="$DATA/${split}.jsonl"; REQ="$OUT/${split}-${mode}.jsonl"
    echo "[gate] 匯出 ${split} ${mode}"
    # macOS 內建 bash 3.2 在 set -u 下不接受空陣列展開，所以兩種模式分開呼叫
    if [ "$mode" = nbest ]; then
      "$BIN" --factory "$FACTORY" --input "$IN" --mode nbest --k 8 > "$REQ" 2> "$LOG/dump-${split}-${mode}.err"
    else
      "$BIN" --factory "$FACTORY" --input "$IN" --mode span > "$REQ" 2> "$LOG/dump-${split}-${mode}.err"
    fi
    tail -1 "$LOG/dump-${split}-${mode}.err" || true
    # 變數後面緊接全形標點時 bash 會把多位元組字元首位元組併入變數名，所以一律用 ${var}
    echo "[gate] 評分 ${split} ${mode} ($(wc -l < "$REQ") 個請求)"
    ( cd "$HARNESS" && PYTHONDONTWRITEBYTECODE=1 .venv/bin/python d512eval.py --input "$REQ" --out "$OUT/report-${split}-${mode}" > "$LOG/harness-${split}-${mode}.log" 2>&1 )
  done
done
echo "[gate] 完成；報告在 $OUT"
