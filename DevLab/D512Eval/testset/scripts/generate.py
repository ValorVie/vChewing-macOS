"""只讀固定原始語料與 phrases-*.txt，以固定 seed 產生 dev／held-out。"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import subprocess
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

from validate import SYLLABLE, check_case, is_han, validate_files

ROOT = Path(__file__).resolve().parents[1]
LEXICON_REV = "a7548f42ccdf523a2cc8ab533b3990561eba7288"
# 指向 repo 根目錄 `swift package resolve` 後的詞庫 checkout。
DEFAULT_LEXICON = (
    ROOT.parents[2] / ".build/checkouts/vChewing-VanguardLexicon"
    / "Sources/LibVanguardChewingData/Resources/components/cht"
)
SEED = 20261015
# 使用者核准的全部句尾／助詞例外，只在單字 fallback 使用；不改詞條讀音。
PARTICLE_FALLBACKS = {"了": "ㄌㄜ˙", "的": "ㄉㄜ˙", "嗎": "ㄇㄚ˙", "呢": "ㄋㄜ˙", "吧": "ㄅㄚ˙"}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dump_json(path: Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8")


def dump_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")


@dataclass
class Lexicon:
    words: dict[str, tuple[str, ...]]
    chars: dict[str, str]
    polyphonic: set[str]
    tied_words: set[str]
    max_word_length: int
    stats: dict
    word_frequencies: dict[str, int]
    character_frequencies: dict[str, int]
    log_scores: dict[str, float]

    @classmethod
    def load(cls, directory: Path, verify_revision: bool = True) -> Lexicon:
        files = sorted(directory.glob("phrases-*.txt"))
        if not files:
            raise ValueError("找不到 phrases-*.txt")
        if verify_revision:
            head = subprocess.check_output(
                ["git", "-C", str(directory), "rev-parse", "HEAD"], text=True
            ).strip()
            if head != LEXICON_REV:
                raise ValueError(f"詞庫 revision 錯誤：{head}")
            if subprocess.check_output(
                ["git", "-C", str(directory), "status", "--porcelain", "--", "phrases-*.txt"],
                text=True,
            ).strip():
                raise ValueError("指定詞庫檔案存在修改，停止反查")
        entries: dict[tuple[str, tuple[str, ...]], int] = {}
        counts: Counter = Counter()
        rejected = []
        for path in files:
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                counts["input_rows"] += 1
                if "#" in line:
                    counts["inline_comment_rows"] += 1
                fields = line.split("#", 1)[0].split()
                try:
                    word, frequency, *phones = fields
                    freq = int(frequency)
                    if freq < 0 or len(word) != len(phones) or not all(map(is_han, word)):
                        raise ValueError("頻次、漢字或字音長度不合法")
                    if not all(SYLLABLE.fullmatch(phone) for phone in phones):
                        raise ValueError("注音格式不合法")
                except ValueError:
                    counts["rejected_rows"] += 1
                    rejected.append({"file": path.name, "line": number})
                    continue
                counts["accepted_rows"] += 1
                key = (word, tuple(phones))
                entries[key] = max(entries.get(key, 0), freq)
        variants: dict[str, list[tuple[int, tuple[str, ...]]]] = defaultdict(list)
        char_votes: dict[str, Counter] = defaultdict(Counter)
        direct_chars: dict[str, Counter] = defaultdict(Counter)
        for (word, phones), freq in sorted(entries.items()):
            variants[word].append((freq, phones))
            for char, phone in zip(word, phones, strict=True):
                char_votes[char][phone] += freq
            if len(word) == 1:
                direct_chars[word][phones[0]] = freq
        # 同一詞＋讀音的跨檔重複先取最大頻次，再投影累計；零頻讀音仍計入多音字。
        words = {word: min(rows, key=lambda row: (-row[0], row[1]))[1]
                 for word, rows in variants.items()}
        tied_words = {word for word, rows in variants.items()
                      if len({phones for freq, phones in rows if freq == max(row[0] for row in rows)}) > 1}
        chars = {}
        character_frequencies = {}
        for char, votes in char_votes.items():
            choices = direct_chars.get(char, votes)
            chars[char] = min(choices, key=lambda phone: (-choices[phone], phone))
            character_frequencies[char] = choices[chars[char]]
        polyphonic = {char for char, votes in char_votes.items() if len(votes) > 1}
        word_frequencies = {word: max(freq for freq, _ in rows) for word, rows in variants.items() if len(word) > 1}
        frequencies = {**word_frequencies, **character_frequencies}
        # 零頻項取 1，使每條邊有定義的 log 分數；所有詞／字使用同一正規化總量。
        total_frequency = sum(max(freq, 1) for freq in frequencies.values())
        log_total = math.log(total_frequency)
        log_scores = {token: math.log(max(freq, 1)) - log_total for token, freq in frequencies.items()}
        stats = {
            **counts, "unique_word_readings": len(entries), "unique_words": len(words),
            "character_types": len(chars), "polyphonic_character_types": len(polyphonic),
            "direct_single_character_types": len(direct_chars),
            "single_character_policy": "單字 fallback 的投影讀音超過一種時丟棄整個標點分句；非多音字照舊；唯一例外是核准的五個助詞讀音",
            "particle_fallbacks": PARTICLE_FALLBACKS,
            "word_policy": "正規化頻次 DP 選路徑後，選中最高頻並列異讀詞條時丟棄整句；最高頻唯一者照舊",
            "segmentation": {"algorithm": "Viterbi/DAG", "score": "sum(log(max(freq,1)/Z))",
                             "normalization_total": total_frequency, "zero_frequency_floor": 1,
                             "character_frequency": "現有最高頻投影讀音的累計頻次；助詞例外只改輸出讀音",
                             "tie_break": "分數差至多 1e-12 視為同分，按路徑由左至右優先較長詞",
                             "filter_order": "先選最大分數路徑，再套既有丟棄規則；不改選次佳路徑"},
            "highest_frequency_tied_word_types": len(tied_words),
            "polyphonic_definition": "同字在合法詞條投影中有至少兩種帶調讀音，含零頻與變調",
            "rejected_row_locations": rejected,
            "files": [{"name": path.name, "bytes": path.stat().st_size,
                       "sha256": sha256(path)} for path in files],
            "revision": LEXICON_REV if verify_revision else "測試資料",
        }
        return cls(words, chars, polyphonic, tied_words, max(map(len, words)), stats,
                   word_frequencies, character_frequencies, log_scores)

    def greedy_segments(self, text: str) -> list[str] | None:
        """僅供新舊切分統計，保留舊的貪婪選詞；不套讀音丟棄規則。"""
        segments = []
        cursor = 0
        while cursor < len(text):
            for length in range(min(self.max_word_length, len(text) - cursor), 1, -1):
                word = text[cursor:cursor + length]
                if word in self.words:
                    segments.append(word)
                    cursor += length
                    break
            else:
                if text[cursor] not in self.chars:
                    return None
                segments.append(text[cursor])
                cursor += 1
        return segments

    def segmentation_score(self, segments: list[str]) -> float:
        return math.fsum(self.log_scores[token] for token in segments)

    def segment(self, text: str) -> list[str] | None:
        """DAG 每個位置取最大總 log 頻率；同分優先較早的較長詞。"""
        count = len(text)
        scores = [-math.inf] * (count + 1)
        lengths: list[tuple[int, ...]] = [()] * (count + 1)
        previous = [-1] * (count + 1)
        scores[0] = 0.0
        for start in range(count):
            if scores[start] == -math.inf:
                continue
            for size in range(1, min(self.max_word_length, count - start) + 1):
                token = text[start:start + size]
                if token not in self.log_scores:
                    continue
                end = start + size
                score = scores[start] + self.log_scores[token]
                tied = math.isclose(score, scores[end], rel_tol=0, abs_tol=1e-12)
                if ((score > scores[end] and not tied)
                        or (tied and lengths[start] + (size,) > lengths[end])):
                    scores[end] = score
                    lengths[end] = lengths[start] + (size,)
                    previous[end] = start
        if scores[count] == -math.inf:
            return None
        segments = []
        end = count
        while end:
            start = previous[end]
            segments.append(text[start:end])
            end = start
        return list(reversed(segments))

    def annotate_segments(self, segments: list[str] | None) -> tuple[list[str] | None, Counter]:
        reading = []
        counts: Counter = Counter()
        if segments is None:
            return None, counts
        for token in segments:
            if len(token) > 1:
                if token in self.tied_words:
                    counts["ambiguous_word_matches"] += 1
                    return None, counts
                reading.extend(self.words[token])
                counts["word_matches"] += 1
                counts["word_matched_characters"] += len(token)
            else:
                char = token
                if char in PARTICLE_FALLBACKS:
                    reading.append(PARTICLE_FALLBACKS[char])
                    counts["particle_fallbacks"] += 1
                elif char in self.polyphonic:
                    counts["ambiguous_single_character_fallbacks"] += 1
                    return None, counts
                else:
                    reading.append(self.chars[char])
                counts["single_character_fallbacks"] += 1
        return reading, counts

    def annotate(self, text: str) -> tuple[list[str] | None, Counter]:
        return self.annotate_segments(self.segment(text))


def punctuation_segments(text: str) -> list[str]:
    # 空白不從句中刪除，避免把英文、數字或無讀音字兩側接成新的正確答案。
    result, current = [], []
    for char in unicodedata.normalize("NFC", text):
        if unicodedata.category(char).startswith("P") or char in "\n\r\t~～⋯":
            if segment := "".join(current).strip():
                result.append(segment)
            current = []
        else:
            current.append(char)
    if segment := "".join(current).strip():
        result.append(segment)
    return result


def chunk_bounds(length: int) -> list[tuple[int, int]]:
    result = []
    cursor = 0
    while length - cursor > 32:
        size = 31 if length - cursor == 33 else 32
        result.append((cursor, cursor + size))
        cursor += size
    if length - cursor >= 2:
        result.append((cursor, length))
    return result


def make_cases(documents: list[dict], lexicon: Lexicon) -> tuple[list[dict], dict]:
    records = []
    counters: dict[str, Counter] = defaultdict(Counter)
    unknown: dict[str, Counter] = defaultdict(Counter)
    segmentation_examples: dict[str, list[dict]] = defaultdict(list)
    for document in sorted(documents, key=lambda doc: (doc["source_id"], doc["document_id"])):
        source_id = document["source_id"]
        counts = counters[source_id]
        counts["documents"] += 1
        previous = ""
        for part, paragraph in enumerate(document["paragraphs"]):
            # 原始來源以段落提供邊界；已打散句庫的各行是獨立文件。
            previous = ""
            for sentence, text in enumerate(punctuation_segments(paragraph)):
                counts["punctuation_segments"] += 1
                context = previous if document["ordered_context"] else ""
                previous = text
                if len(text) < 2:
                    counts["discarded_too_short_segments"] += 1
                    continue
                counts["attempted_segments"] += 1
                missing = [char for char in text if char not in lexicon.chars]
                if missing:
                    counts["discarded_unknown_segments"] += 1
                    unknown[source_id].update(missing)
                    continue
                chosen = lexicon.segment(text)
                greedy = lexicon.greedy_segments(text)
                if chosen is None or greedy is None:
                    raise ValueError("已確認每字覆蓋，卻找不到完整分詞路徑")
                counts["segmentation_compared_segments"] += 1
                if chosen != greedy:
                    counts["segmentation_changed_segments"] += 1
                    if len(text) <= 32 and len(segmentation_examples[source_id]) < 5:
                        segmentation_examples[source_id].append({
                            "text": text, "document": f'{source_id}:{document["document_id"]}',
                            "greedy": greedy, "dp": chosen,
                            "greedy_log_score": lexicon.segmentation_score(greedy),
                            "dp_log_score": lexicon.segmentation_score(chosen),
                        })
                phones, matches = lexicon.annotate_segments(chosen)
                if phones is None:
                    if matches["ambiguous_word_matches"]:
                        counts["discarded_tied_word_reading_segments"] += 1
                        continue
                    if matches["ambiguous_single_character_fallbacks"]:
                        counts["discarded_polyphonic_fallback_segments"] += 1
                        continue
                    raise ValueError("通過逐字覆蓋檢查，卻無法反查")
                counts.update(matches)
                counts["annotated_segments"] += 1
                for begin, end in chunk_bounds(len(text)):
                    gold = text[begin:end]
                    case = {
                        "id": "d512-" + hashlib.sha256(
                            f'{source_id}:{document["document_id"]}:{part}:{sentence}:{begin}:{gold}'.encode()
                        ).hexdigest()[:24],
                        "gold": gold, "reading": phones[begin:end], "context": context,
                        "source": document["attribution"],
                    }
                    check_case(case)
                    records.append({"case": case, "document": f'{source_id}:{document["document_id"]}',
                                    "source_id": source_id, "polyphonic_occurrences":
                                    sum(char in lexicon.polyphonic for char in gold)})
                    counts["cases_before_deduplication"] += 1
    stats = {}
    for source_id, counts in sorted(counters.items()):
        attempts = counts["attempted_segments"]
        segments = counts["punctuation_segments"]
        stats[source_id] = {
            **counts,
            "discarded_polyphonic_fallback_segments": counts["discarded_polyphonic_fallback_segments"],
            "discarded_tied_word_reading_segments": counts["discarded_tied_word_reading_segments"],
            "unknown_discard_ratio": counts["discarded_unknown_segments"] / attempts if attempts else 0,
            "polyphonic_fallback_discard_ratio": counts["discarded_polyphonic_fallback_segments"] / attempts if attempts else 0,
            "tied_word_reading_discard_ratio": counts["discarded_tied_word_reading_segments"] / attempts if attempts else 0,
            "segment_discard_ratio": (counts["discarded_unknown_segments"]
                                      + counts["discarded_too_short_segments"]
                                      + counts["discarded_polyphonic_fallback_segments"]
                                      + counts["discarded_tied_word_reading_segments"]) / segments if segments else 0,
            "unknown_characters_top20": unknown[source_id].most_common(20),
            "segmentation_compared_segments": counts["segmentation_compared_segments"],
            "segmentation_changed_segments": counts["segmentation_changed_segments"],
            "segmentation_change_examples": segmentation_examples[source_id],
        }
    return records, stats


def split_cases(records: list[dict], seed: int, dev_fraction: float) -> tuple[dict, dict, list[dict]]:
    # 先全域去重，再按文件分組；移除的重複案例不會再連結不同文章。
    seen: set[str] = set()
    unique = []
    duplicates = Counter()
    for record in records:
        gold = record["case"]["gold"]
        if gold in seen:
            duplicates[record["source_id"]] += 1
            continue
        seen.add(gold)
        unique.append(record)
    buckets: dict[str, list[dict]] = defaultdict(list)
    for record in unique:
        buckets[record["document"]].append(record)
    keys = sorted(buckets)
    random.Random(seed).shuffle(keys)
    # 依來源分層累加整個群組；用各來源的比例誤差決定是否納入 dev。
    totals = Counter(record["source_id"] for record in unique)
    targets = {source: max(1, round(count * dev_fraction)) for source, count in totals.items()}
    dev_sources: Counter = Counter()
    def distance(counts: Counter) -> float:
        return sum(((counts[source] - targets[source]) / totals[source]) ** 2 for source in totals)
    dev_keys: set[str] = set()
    dev_count = 0
    for key in keys:
        size = len(buckets[key])
        source_counts = Counter(record["source_id"] for record in buckets[key])
        if distance(dev_sources + source_counts) <= distance(dev_sources):
            dev_keys.add(key)
            dev_count += size
            dev_sources.update(source_counts)
    split = {"dev": [], "held-out": []}
    assignments = []
    for key in sorted(keys):
        name = "dev" if key in dev_keys else "held-out"
        for record in buckets[key]:
            split[name].append(record)
            assignments.append({"id": record["case"]["id"], "split": name,
                                "document": record["document"], "group": key})
    for rows in split.values():
        rows.sort(key=lambda row: row["case"]["id"])
    info = {"document_groups": len(keys), "largest_group_cases": max(map(len, buckets.values()), default=0),
            "duplicates_removed": dict(duplicates), "target_dev_fraction": dev_fraction,
            "actual_dev_fraction": dev_count / len(unique) if unique else 0,
            "dev_fraction_by_source": {source: dev_sources[source] / count for source, count in totals.items()},
            "deduplication_key": "gold",
            "duplicate_retention": "保留產生器遍歷順序中的第一次出現",
            "grouping": "先以 gold 全域去重，再按文件分組；同文件不跨 split；依來源分層 dev"}
    return split, info, assignments


def summarize(records: list[dict]) -> dict:
    chars = sum(len(record["case"]["reading"]) for record in records)
    polyphonic = sum(record["polyphonic_occurrences"] for record in records)
    return {"cases": len(records), "syllables": chars,
            "syllable_distribution": dict(sorted(Counter(len(record["case"]["reading"])
                                                         for record in records).items())),
            "polyphonic_character_occurrences": polyphonic,
            "polyphonic_character_occurrence_ratio": polyphonic / chars if chars else 0,
            "cases_with_polyphonic_characters": sum(record["polyphonic_occurrences"] > 0 for record in records),
            "cases_with_context": sum(bool(record["case"]["context"]) for record in records),
            "by_source": dict(sorted(Counter(record["source_id"] for record in records).items()))}


def filtering_summary(source_stats: dict) -> dict:
    keys = ("punctuation_segments", "attempted_segments", "discarded_unknown_segments",
            "discarded_too_short_segments", "discarded_polyphonic_fallback_segments", "discarded_tied_word_reading_segments")
    result = {key: sum(source.get(key, 0) for source in source_stats.values()) for key in keys}
    attempts = result["attempted_segments"]
    for label, key in (("unknown", "discarded_unknown_segments"), ("polyphonic_fallback", "discarded_polyphonic_fallback_segments"),
                       ("tied_word_reading", "discarded_tied_word_reading_segments")):
        result[f"{label}_discard_ratio"] = result[key] / attempts if attempts else 0
    result["discard_ratio_denominator"] = "三種反查丟棄比例均以 attempted_segments 為分母；先排短句、未知字，再依 DP 路徑遇到的首個異讀原因分類，互斥計數"
    all_segments = result["punctuation_segments"]
    result["segment_discard_ratio"] = sum(result[key] for key in keys if key.startswith("discarded_")) / all_segments if all_segments else 0
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", type=Path, default=ROOT / "data/raw/documents.jsonl")
    parser.add_argument("--lexicon", type=Path, default=DEFAULT_LEXICON)
    parser.add_argument("--seed", type=int, default=SEED)
    parser.add_argument("--dev-fraction", type=float, default=0.2)
    parser.add_argument("--minimum-held-out", type=int, default=3000)
    args = parser.parse_args()
    if not 0 < args.dev_fraction < 1 or args.minimum_held_out < 1:
        parser.error("dev 比例必須介於 0 與 1；held-out 最低筆數須為正")
    try:
        lexicon = Lexicon.load(args.lexicon)
        dump_json(ROOT / "reports/lexicon-stats.json", lexicon.stats)
        if not args.raw.is_file():
            raise ValueError("尚無 raw/documents.jsonl；語料需先獲同意並取得，未產生正式案例")
        manifest = json.loads((args.raw.parent / "download-manifest.json").read_text(encoding="utf-8"))
        if sha256(args.raw) != manifest["documents_sha256"]:
            raise ValueError("raw/documents.jsonl 與凍結 manifest 的 SHA-256 不符")
        moztw = manifest["sources"]["moztw-g0v-cc0"]
        if sha256(args.raw.parent / "moztw-g0v.txt") != moztw["sha256"]:
            raise ValueError("MozTW raw 與凍結 manifest 不符")
        for page in manifest["sources"]["wikipedia-zh-tw"]["pages"]:
            if sha256(args.raw.parent / "wikipedia" / page["raw_file"]) != page["sha256"]:
                raise ValueError(f"維基百科 raw 與凍結 manifest 不符：{page['title']}")
        documents = [json.loads(line) for line in args.raw.read_text(encoding="utf-8").splitlines()]
        if {doc["source_id"] for doc in documents} != {"wikipedia-zh-tw", "moztw-g0v-cc0"}:
            raise ValueError("raw 必須含已同意的正式與口語兩來源")
        records, source_stats = make_cases(documents, lexicon)
        splits, split_info, assignments = split_cases(records, args.seed, args.dev_fraction)
        filtering = filtering_summary(source_stats)
        compared = sum(source["segmentation_compared_segments"] for source in source_stats.values())
        changed = sum(source["segmentation_changed_segments"] for source in source_stats.values())
        comparison = {"compared_segments": compared, "changed_segments": changed,
                      "changed_ratio": changed / compared if compared else 0,
                      "definition": "原始至少兩字、每字皆有投影讀音的標點分句；套丟棄規則之前比較完整詞／字切分",
                      "examples": [example for source in source_stats.values()
                                   for example in source["segmentation_change_examples"]][:5]}
        if not splits["dev"] or len(splits["held-out"]) < args.minimum_held_out:
            dump_json(ROOT / "reports/insufficient-data.json", {
                "status": "資料不足，停止等待使用者決定", "seed": args.seed,
                "splits": {name: summarize(rows) for name, rows in splits.items()},
                "filtering_overall": filtering, "segmentation_comparison": comparison,
            })
            raise ValueError(f"分組後 dev={len(splits['dev'])}，held-out={len(splits['held-out'])}；"
                             "無法滿足非空 dev 與 held-out 最低筆數，停止而不鬆綁隔離")
        output = ROOT / "data/generated"
        output.mkdir(parents=True, exist_ok=True)
        for name, rows in splits.items():
            dump_jsonl(output / f"{name}.jsonl", [record["case"] for record in rows])
        validation = {Path(path).relative_to(ROOT).as_posix(): count for path, count in
                      validate_files([output / "dev.jsonl", output / "held-out.jsonl"], args.minimum_held_out).items()}
        if {row["group"] for row in assignments if row["split"] == "dev"} & {
            row["group"] for row in assignments if row["split"] == "held-out"
        }:
            raise ValueError("dev／held-out 文件群組重疊")
        for source in ("wikipedia-zh-tw", "moztw-g0v-cc0"):
            if any(not any(record["source_id"] == source for record in rows) for rows in splits.values()):
                raise ValueError(f"dev／held-out 缺少來源 {source}，停止而不拆開文件群組")
        sample = []
        for name in ("dev", "held-out"):
            for source in ("wikipedia-zh-tw", "moztw-g0v-cc0"):
                pool = [record["case"] for record in splits[name] if record["source_id"] == source]
                sample.extend(random.Random(args.seed).sample(pool, min(50, len(pool))))
        dump_jsonl(ROOT / "data/sample.jsonl", sample)
        stats = {
            "status": "已產生並自檢", "seed": args.seed, "lexicon": lexicon.stats,
            "raw_sha256": sha256(args.raw), "source_filtering": source_stats,
            "source_downloads": {source: {key: value for key, value in details.items() if key != "pages"}
                                 for source, details in manifest["sources"].items()},
            "split_policy": split_info, "splits": {name: summarize(rows) for name, rows in splits.items()},
            "overall": summarize([record for rows in splits.values() for record in rows]),
            "filtering_overall": filtering, "segmentation_comparison": comparison,
            "sample_cases": len(sample), "validation": validation,
            "artifacts": {name: {"sha256": sha256(output / f"{name}.jsonl"),
                                  "bytes": (output / f"{name}.jsonl").stat().st_size}
                          for name in splits},
            "limitations": ["注音由詞庫正規化頻次 DP 分詞合成，尚未人工全面標音驗證", "未核對未公開的 0c 訓練逐句資料",
                            "只做精確目標／前文與文件分組，未做 MinHash 近重複隔離",
                            "前文為來源文字，不模擬前次引擎錯誤；聊天句庫無可靠前文"],
        }
        dump_json(output / "split-manifest.json", assignments)
        dump_json(ROOT / "reports/stats.json", stats)
        print(json.dumps({"status": stats["status"], "seed": args.seed,
                          "dev_cases": len(splits["dev"]), "held_out_cases": len(splits["held-out"]),
                          "sample_cases": len(sample)}, ensure_ascii=False))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"產生失敗：{exc}\n")


if __name__ == "__main__":
    main()
