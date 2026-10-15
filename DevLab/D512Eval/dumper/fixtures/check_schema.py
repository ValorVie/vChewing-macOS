#!/usr/bin/env python3
"""Validate the D512Dump schema and cross-mode defaults; stdlib only."""

import json
import math
from pathlib import Path
import sys


def read_jsonl(path):
    return [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines() if line]


def check(cases_path, span_path, nbest_path):
    cases = read_jsonl(cases_path)
    by_id = {case["id"]: case for case in cases}
    assert cases and len(by_id) == len(cases), "empty input or duplicate ids"
    for case in cases:
        assert isinstance(case["id"], str) and case["id"]
        assert isinstance(case["context"], str)
        assert isinstance(case["gold"], str) and len(case["gold"]) == len(case["reading"])
        assert 2 <= len(case["reading"]) <= 32

    defaults = {mode: {} for mode in ["span", "nbest"]}
    scores = {mode: {} for mode in ["span", "nbest"]}
    counts = {}
    for mode, path in [("span", span_path), ("nbest", nbest_path)]:
        rows = read_jsonl(path)
        counts[mode] = len(rows)
        offsets = {}
        for row in rows:
            assert row["mode"] == mode and row["id"] in by_id
            case = by_id[row["id"]]
            start, end = row["span"]
            assert type(start) is int and type(end) is int and 0 <= start < end <= len(case["reading"])
            assert row["reading"] == case["reading"][start:end]
            assert row["gold"] == case["gold"][start:end]
            assert type(row["engine_default"]) is int and row["engine_default"] == 0
            assert "log10" in row["score_scale"] and "no bigram/trigram" in row["score_scale"]
            assert 1 <= len(row["candidates"]) <= (8 if mode == "nbest" else 16)
            texts = [candidate["text"] for candidate in row["candidates"]]
            assert len(set(texts)) == len(texts) and all(len(text) == end - start for text in texts)
            assert type(row["gold_in_candidates"]) is bool
            assert row["gold_in_candidates"] == (row["gold"] in texts)
            if mode == "span" and end - start == 1:
                assert row.get("text_mode") is True
            else:
                assert "text_mode" not in row
            for candidate in row["candidates"]:
                score = candidate["log_score"]
                assert type(score) in (int, float) and math.isfinite(score) and score <= 0
                cursor = 0
                words = []
                for segment in candidate["segments"]:
                    assert set(segment) == {"Start", "End", "Word", "Partial", "Correction"}
                    assert type(segment["Start"]) is int and type(segment["End"]) is int
                    assert segment["Start"] == cursor < segment["End"] <= end - start
                    assert len(segment["Word"]) == segment["End"] - cursor
                    assert segment["Partial"] is False and segment["Correction"] is False
                    cursor = segment["End"]
                    words.append(segment["Word"])
                assert cursor == end - start and "".join(words) == candidate["text"]
                if mode == "span":
                    assert len(candidate["segments"]) == 1
            values = [candidate["log_score"] for candidate in row["candidates"]]
            assert values[0] == max(values), "candidate 0 must have maximum log_score"
            old_text = defaults[mode].get(row["id"], "")
            assert start == offsets.get(row["id"], 0), "missing, duplicated or out-of-order span"
            assert row["context"] == case["context"] + old_text
            if mode == "nbest":
                assert row["span"] == [0, len(case["reading"])] and not old_text
                values = [candidate["log_score"] for candidate in row["candidates"]]
                assert all(a >= b for a, b in zip(values, values[1:]))
            offsets[row["id"]] = end
            defaults[mode][row["id"]] = old_text + texts[0]
            scores[mode][row["id"]] = scores[mode].get(row["id"], 0) + row["candidates"][0]["log_score"]
        assert set(offsets) == set(by_id)
        assert all(end == len(by_id[case_id]["reading"]) for case_id, end in offsets.items())
    assert defaults["span"] == defaults["nbest"], "candidate 0 disagrees across modes"
    assert all(math.isclose(scores["span"][case_id], scores["nbest"][case_id], abs_tol=1e-9) for case_id in by_id)
    print(f"PASS: {len(cases)} cases, {counts['span']} span requests, {counts['nbest']} nbest requests")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("Usage: python3 check_schema.py cases.jsonl span.jsonl nbest.jsonl")
    try:
        check(*sys.argv[1:])
    except (AssertionError, KeyError, TypeError, ValueError) as error:
        sys.exit(f"FAIL: {error}")
