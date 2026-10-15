"""測試集 JSONL 自檢：標準函式庫，不需要全域或第三方套件。"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

FIELDS = {"id", "gold", "reading", "context", "source"}
SYLLABLE = re.compile(r"[ㄅ-ㄩ]{1,3}[ˊˇˋ˙]?")


def is_han(char: str) -> bool:
    value = ord(char)
    return (char == "〇" or 0x3400 <= value <= 0x4DBF
            or 0x4E00 <= value <= 0x9FFF or 0xF900 <= value <= 0xFAFF
            or 0x20000 <= value <= 0x323AF)


def check_case(case: object) -> dict:
    if not isinstance(case, dict) or set(case) != FIELDS:
        raise ValueError("欄位必須恰為 id/gold/reading/context/source")
    for key in ("id", "gold", "context", "source"):
        if not isinstance(case[key], str):
            raise ValueError(f"{key} 必須為字串")
    if not case["id"] or not case["source"]:
        raise ValueError("id/source 不能為空")
    reading = case["reading"]
    if not isinstance(reading, list) or not 2 <= len(reading) <= 32:
        raise ValueError("reading 必須包含 2–32 音節")
    if len(case["gold"]) != len(reading) or not all(map(is_han, case["gold"])):
        raise ValueError("gold 必須每音節恰一個漢字")
    if any(not isinstance(phone, str) or SYLLABLE.fullmatch(phone) is None
           for phone in reading):
        raise ValueError("注音或聲調格式錯誤（一聲無記號、輕聲在右）")
    return case


def validate_files(paths: list[Path], minimum_held_out: int = 0) -> dict:
    seen_ids: set[str] = set()
    seen_pairs: set[tuple[str, str]] = set()
    seen_gold: set[str] = set()
    result = {}
    for path in paths:
        count = 0
        with path.open(encoding="utf-8") as stream:
            for number, line in enumerate(stream, 1):
                try:
                    case = check_case(json.loads(line))
                    pair = (case["context"], case["gold"])
                    if case["id"] in seen_ids:
                        raise ValueError("id 重複")
                    if pair in seen_pairs:
                        raise ValueError("context＋gold 重複（含跨分割）")
                    if case["gold"] in seen_gold:
                        raise ValueError("gold 重複（含 dev／held-out 交集；前文不同也禁止）")
                    seen_ids.add(case["id"])
                    seen_pairs.add(pair)
                    seen_gold.add(case["gold"])
                    count += 1
                except (ValueError, TypeError) as exc:
                    raise ValueError(f"{path}:{number}: {exc}") from exc
        result[str(path)] = count
        if path.name == "held-out.jsonl" and count < minimum_held_out:
            raise ValueError(f"held-out 僅 {count} 筆，低於 {minimum_held_out}")
    if not result or any(count == 0 for count in result.values()):
        raise ValueError("資料檔不能為空")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--minimum-held-out", type=int, default=0)
    args = parser.parse_args()
    try:
        result = validate_files(args.paths, args.minimum_held_out)
    except (ValueError, OSError) as exc:
        parser.exit(1, f"自檢失敗：{exc}\n")
    print(json.dumps({"status": "通過", "cases": result}, ensure_ascii=False))


if __name__ == "__main__":
    main()
