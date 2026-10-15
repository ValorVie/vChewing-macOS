"""驗證會改變評測標籤或污染封存集的關鍵資料行為。"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from acquire import Paragraphs
from generate import ROOT, Lexicon, chunk_bounds, make_cases, punctuation_segments, split_cases
from validate import check_case, validate_files


class PipelineTest(unittest.TestCase):
    def setUp(self) -> None:
        # 暫存資料只在已授權的 DevLab/D512Eval/testset/tmp/ 中建立。
        (ROOT / "tmp").mkdir(exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=ROOT / "tmp")
        self.path = Path(self.directory.name)
        (self.path / "phrases-test.txt").write_text(
            "# 測試詞條\n銀行 100 ㄧㄣˊ ㄏㄤˊ\n行走 200 ㄒㄧㄥˊ ㄗㄡˇ\n"
            "銀行家 50 ㄧㄣˊ ㄏㄤˊ ㄐㄧㄚ\n行人 5 ㄒㄧㄥˊ ㄖㄣˊ\n"
            "你好 30 ㄋㄧˇ ㄏㄠˇ\n好的 20 ㄏㄠˇ ㄉㄜ˙ #MACOS\n"
            "了解 1000 ㄌㄧㄠˇ ㄐㄧㄝˇ\n算了 10 ㄙㄨㄢˋ ㄌㄜ˙\n目的 1000 ㄇㄨˋ ㄉㄧˋ\n"
            "了解 1 ㄌㄜ˙ ㄐㄧㄝˇ\n看起來 400 ㄎㄢ ㄑㄧˇ ㄌㄞˊ\n看起來 400 ㄎㄢˋ ㄑㄧˇ ㄌㄞˊ\n"
            "嗎啡 1000 ㄇㄚˊ ㄈㄟ\n好嗎 10 ㄏㄠˇ ㄇㄚ˙\n"
            "呢喃 1000 ㄋㄧˊ ㄋㄢˊ\n好呢 10 ㄏㄠˇ ㄋㄜ˙\n"
            "吧台 1000 ㄅㄚ ㄊㄞˊ\n好吧 10 ㄏㄠˇ ㄅㄚ˙\n"
            "長度 100 ㄔㄤˊ ㄉㄨˋ\n成長 200 ㄔㄥˊ ㄓㄤˇ\n"
            "看見 100 ㄎㄢˋ ㄐㄧㄢˋ\n看守 200 ㄎㄢ ㄕㄡˇ\n"
            "阿拉伯語 702 ㄚ ㄌㄚ ㄅㄛˊ ㄩˇ\n中的 11 ㄓㄨㄥˋ ㄉㄧˋ\n"
            "中文 90000 ㄓㄨㄥ ㄨㄣˊ\n文的 90000 ㄨㄣˊ ㄉㄜ˙\n"
            "不合法 1 ㄅㄨˋ ㄏㄜˊ\n", encoding="utf-8")
        self.lexicon = Lexicon.load(self.path, verify_revision=False)

    def tearDown(self) -> None:
        self.directory.cleanup()

    @staticmethod
    def document(identifier: str, text: list[str], ordered: bool = True) -> dict:
        return {"source_id": "測試", "document_id": identifier,
                "paragraphs": text, "ordered_context": ordered, "attribution": "原創測試資料"}

    def test_longest_word_and_unambiguous_single_character_fallback(self) -> None:
        reading, counts = self.lexicon.annotate("銀行家家")
        self.assertEqual(reading, ["ㄧㄣˊ", "ㄏㄤˊ", "ㄐㄧㄚ", "ㄐㄧㄚ"])
        self.assertEqual(counts["word_matched_characters"], 3)
        self.assertEqual(counts["single_character_fallbacks"], 1)
        self.assertIn("行", self.lexicon.polyphonic)
        self.assertEqual(self.lexicon.stats["rejected_rows"], 1)
        self.assertEqual(self.lexicon.annotate("好的")[0][-1], "ㄉㄜ˙")

    def test_dp_splits_arabic_language_middle_and_particle(self) -> None:
        self.assertEqual(self.lexicon.segment("阿拉伯語中的"), ["阿拉伯語", "中", "的"])
        # 中仍是多音字 fallback；分詞修正不能放寬整句丟棄規則。
        self.assertIsNone(self.lexicon.annotate("阿拉伯語中的")[0])

    def test_dp_keeps_a_strong_long_word_instead_of_splitting_every_character(self) -> None:
        self.assertEqual(self.lexicon.segment("銀行家"), ["銀行家"])
        self.assertGreater(self.lexicon.segmentation_score(["銀行家"]),
                           self.lexicon.segmentation_score(["銀", "行", "家"]))

    def test_dp_uses_global_score_instead_of_the_longest_prefix(self) -> None:
        (self.path / "phrases-test.txt").write_text(
            "甲乙丙 1 ㄐㄧㄚˇ ㄧˇ ㄅㄧㄥˇ\n甲乙 10000 ㄐㄧㄚˇ ㄧˇ\n丙丁 10000 ㄅㄧㄥˇ ㄉㄧㄥ\n", encoding="utf-8")
        lexicon = Lexicon.load(self.path, verify_revision=False)
        self.assertEqual(lexicon.greedy_segments("甲乙丙丁"), ["甲乙丙", "丁"])
        self.assertEqual(lexicon.segment("甲乙丙丁"), ["甲乙", "丙丁"])

    def test_dp_equal_scores_prefer_the_earlier_long_word(self) -> None:
        (self.path / "phrases-test.txt").write_text(
            "甲乙 100 ㄐㄧㄚˇ ㄧˇ\n乙丙 100 ㄧˇ ㄅㄧㄥˇ\n甲丙 100 ㄐㄧㄚˇ ㄅㄧㄥˇ\n", encoding="utf-8")
        lexicon = Lexicon.load(self.path, verify_revision=False)
        self.assertAlmostEqual(lexicon.segmentation_score(["甲乙", "丙"]),
                               lexicon.segmentation_score(["甲", "乙丙"]))
        self.assertEqual(lexicon.segment("甲乙丙"), ["甲乙", "丙"])

    def test_polyphonic_fallback_rejects_whole_punctuation_segment(self) -> None:
        for char in ("行", "看", "長"):
            with self.subTest(char=char):
                self.assertIsNone(self.lexicon.annotate("銀行家" + char)[0])
        records, stats = make_cases([self.document("a", ["銀行家行。你好"])], self.lexicon)
        self.assertEqual([row["case"]["gold"] for row in records], ["你好"])
        self.assertEqual(stats["測試"]["discarded_polyphonic_fallback_segments"], 1)
        self.assertEqual(stats["測試"]["polyphonic_fallback_discard_ratio"], .5)
        long_records, _ = make_cases([self.document("b", ["你好" * 20 + "行"])], self.lexicon)
        self.assertEqual(long_records, [])

    def test_five_particle_exceptions_apply_only_to_single_character_fallback(self) -> None:
        expected = {"了": "ㄌㄜ˙", "的": "ㄉㄜ˙", "嗎": "ㄇㄚ˙", "呢": "ㄋㄜ˙", "吧": "ㄅㄚ˙"}
        for char, reading in expected.items():
            with self.subTest(char=char):
                self.assertEqual(self.lexicon.annotate("銀行家" + char)[0][-1], reading)
        self.assertEqual(self.lexicon.annotate("了解")[0], ["ㄌㄧㄠˇ", "ㄐㄧㄝˇ"])
        self.assertEqual(self.lexicon.annotate("目的")[0], ["ㄇㄨˋ", "ㄉㄧˋ"])
        self.assertEqual(self.lexicon.annotate("呢喃")[0], ["ㄋㄧˊ", "ㄋㄢˊ"])

    def test_highest_frequency_tied_word_readings_reject_whole_segment(self) -> None:
        self.assertIsNone(self.lexicon.annotate("銀行家看起來")[0])
        records, stats = make_cases([self.document("a", ["你好。銀行家看起來"])], self.lexicon)
        self.assertEqual([row["case"]["gold"] for row in records], ["你好"])
        self.assertEqual(stats["測試"]["discarded_tied_word_reading_segments"], 1)
        self.assertEqual(stats["測試"]["tied_word_reading_discard_ratio"], .5)
        self.assertEqual(self.lexicon.annotate("了解")[0], ["ㄌㄧㄠˇ", "ㄐㄧㄝˇ"])

    def test_unknown_drops_entire_segment_and_context_is_previous_source_text(self) -> None:
        records, stats = make_cases([self.document("a", ["你好。銀行甲行。好的！", "行走。銀行家。"])], self.lexicon)
        self.assertEqual([row["case"]["gold"] for row in records], ["你好", "好的", "行走", "銀行家"])
        self.assertEqual(records[1]["case"]["context"], "銀行甲行")
        self.assertEqual(records[2]["case"]["context"], "")
        self.assertEqual(stats["測試"]["discarded_unknown_segments"], 1)
        self.assertEqual(stats["測試"]["unknown_discard_ratio"], 0.2)

    def test_shuffled_chat_cannot_invent_context(self) -> None:
        records, _ = make_cases([self.document("a", ["你好。好的。"], ordered=False)], self.lexicon)
        self.assertTrue(all(row["case"]["context"] == "" for row in records))

    def test_punctuation_numbers_and_window_remainder(self) -> None:
        self.assertEqual(punctuation_segments("你好，銀行家（英文A1）；好的！"), ["你好", "銀行家", "英文A1", "好的"])
        self.assertEqual(punctuation_segments("你好⋯好的"), ["你好", "好的"])
        for length in (2, 31, 32, 33, 64, 65, 97):
            windows = chunk_bounds(length)
            self.assertEqual(sum(end - begin for begin, end in windows), length)
            self.assertTrue(all(2 <= end - begin <= 32 for begin, end in windows))

    def test_documents_and_globally_unique_gold_stay_together(self) -> None:
        docs = [self.document("a", ["你好。好的"]), self.document("b", ["銀行家。好的"]),
                self.document("c", ["行走。銀行"]), self.document("d", ["行人。銀行家"])]
        records, _ = make_cases(docs, self.lexicon)
        split, _, assignments = split_cases(records, 20261015, 0.2)
        again, _, repeated = split_cases(records, 20261015, 0.2)
        self.assertEqual(split, again)
        self.assertEqual(assignments, repeated)
        locations: dict[str, set] = {}
        for row in assignments:
            locations.setdefault(row["document"], set()).add(row["split"])
        self.assertTrue(all(len(names) == 1 for names in locations.values()))
        self.assertFalse({(r["case"]["context"], r["case"]["gold"]) for r in split["dev"]}
                         & {(r["case"]["context"], r["case"]["gold"]) for r in split["held-out"]})
        self.assertFalse({r["case"]["gold"] for r in split["dev"]}
                         & {r["case"]["gold"] for r in split["held-out"]})
        gold = [row["case"]["gold"] for rows in split.values() for row in rows]
        self.assertEqual(len(gold), len(set(gold)))
        retained = [row for rows in split.values() for row in rows if row["case"]["gold"] == "好的"]
        self.assertEqual(len(retained), 1)
        self.assertEqual(retained[0]["document"], "測試:a")
        self.assertFalse({r["group"] for r in assignments if r["split"] == "dev"}
                         & {r["group"] for r in assignments if r["split"] == "held-out"})

    def test_split_retains_both_source_domains(self) -> None:
        records = []
        for source_index, source in enumerate(("formal", "colloquial")):
            for i in range(20):
                records.append({"case": {"id": f"{source}-{i}", "gold": "你好" + chr(0x4E00 + 20 * source_index + i),
                                         "reading": ["ㄋㄧˇ", "ㄏㄠˇ", "ㄧ"], "context": f"{source}-{i}",
                                         "source": "原創測試資料"},
                                "document": f"{source}-{i}", "source_id": source,
                                "polyphonic_occurrences": 0})
        split, info, _ = split_cases(records, 20261015, .2)
        for rows in split.values():
            self.assertEqual({row["source_id"] for row in rows}, {"formal", "colloquial"})
        self.assertEqual(info["dev_fraction_by_source"], {"formal": .2, "colloquial": .2})

    def test_schema_rejects_left_neutral_tone_extra_field_and_length_mismatch(self) -> None:
        valid = {"id": "sample", "gold": "好的", "reading": ["ㄏㄠˇ", "ㄉㄜ˙"],
                 "context": "", "source": "原創測試資料"}
        check_case(valid)
        for invalid in ({**valid, "reading": ["ㄏㄠˇ", "˙ㄉㄜ"]}, {**valid, "extra": 1},
                        {**valid, "gold": "好"}, {**valid, "reading": ["ㄏㄠˇ", "ㄉㄜˉ"]}):
            with self.assertRaises(ValueError):
                check_case(invalid)
        first, second = self.path / "dev.jsonl", self.path / "held-out.jsonl"
        first.write_text(json.dumps(valid) + "\n", encoding="utf-8")
        second.write_text(json.dumps({**valid, "id": "other"}) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "context＋gold 重複"):
            validate_files([first, second])

    def test_validator_rejects_cross_split_gold_with_different_context(self) -> None:
        case = {"id": "dev-case", "gold": "你好", "reading": ["ㄋㄧˇ", "ㄏㄠˇ"],
                "context": "校準前文", "source": "原創測試資料"}
        first, second = self.path / "dev.jsonl", self.path / "held-out.jsonl"
        first.write_text(json.dumps(case) + "\n", encoding="utf-8")
        second.write_text(json.dumps({**case, "id": "held-case", "context": "不同前文"}) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "gold 重複"):
            validate_files([first, second])

    def test_html_excludes_footnote_table_quote_and_tracks_paragraphs(self) -> None:
        parser = Paragraphs()
        parser.feed('<p>你好<sup class="reference">[1]</sup>，銀行家。</p>'
                    '<table><tr><td><p>表格</p></td></tr></table>'
                    '<blockquote><p>引用</p></blockquote><p>好的。</p>')
        self.assertEqual(parser.paragraphs, ["你好，銀行家。", "好的。"])


if __name__ == "__main__":
    unittest.main()
