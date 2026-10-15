#!/usr/bin/env python3
"""Self-checks. Run: .venv/bin/python test_d512eval.py
The test_pure_* checks need no model; the rest load models/<rev>/."""
import json
import tempfile
from pathlib import Path

import d512eval as d

FIXTURE = d.HERE / "fixtures" / "harness" / "requests.jsonl"
PROBE = d.HERE / "fixtures" / "harness" / "text_probe.jsonl"


# ---- pure functions (no model) ----

def test_pure_choose():
    # fused = [-1 + 1*-2, -2 + 1*-0.5] = [-3, -2.5]: margin 0.5
    assert d.choose([-1, -2], [-2, -0.5], 0, 1, 0.5) == 0  # margin == τ keeps the default
    assert d.choose([-1, -2], [-2, -0.5], 0, 1, 0.49) == 1  # margin > τ overrides
    assert d.choose([-1, -2], [-2, -0.5], 0, 1, 0) == 1
    # w=0: fused == engine, so the result is the engine argmax, i.e. the default
    assert d.choose([-1, -2, -3], [-9, 0, 0], 0, 0, 0) == 0
    assert d.choose([-1, -1], [-9, 0], 0, 0, 0) == 0  # tie at w=0 still keeps the default
    # doubling w flips the decision
    engine, model = [-1, -2.25], [-2, -0.5]
    assert d.choose(engine, model, 0, 1, 1) == 0  # fused [-3, -2.75], margin 0.25 ≤ 1
    assert d.choose(engine, model, 0, 2, 1) == 1  # fused [-5, -3.25], margin 1.75 > 1
    assert d.choose(engine, None, 2, 8, 0) == 2  # fallback keeps the default


def test_pure_evaluate():
    req = lambda gold, *texts: {"id": gold, "reading": ["x"] * len(gold), "gold": gold, "engine_default": 0,
                                "candidates": [{"text": t, "log_score": -1.0 - i} for i, t in enumerate(texts)]}
    reqs = [req("乙", "甲", "乙"),        # baseline wrong, model picks 乙 → helpful
            req("甲", "甲", "乙"),        # baseline right, model picks 乙 → harmful
            req("丙", "甲", "乙", "丙")]  # baseline wrong, model picks 乙 → neutral
    scored = [{"model": [-5.0, 0.0], "task": "phonetic"}] * 2 + [{"model": [-5.0, 0.0, -9.0], "task": "phonetic"}]
    g = d.evaluate(reqs, scored, 1, 0, bootstrap=50)
    assert (g["helpful_overrides"], g["harmful_overrides"], g["neutral_overrides"]) == (1, 1, 1)
    assert g["baseline_top1"] == 1 / 3 and g["rerank_top1"] == 1 / 3 and g["delta_pp"] == 0
    g = d.evaluate(reqs[:1], scored[:1], 1, 0, bootstrap=50)
    assert g["delta_pp"] == 100 and g["ci95_pp"] == [100, 100]
    assert d.evaluate(reqs, scored, 0, 0, bootstrap=50)["rerank_top1"] == 1 / 3  # w=0 == baseline
    # text_params replaces (w, τ) only for text-task requests: margin 4 for both, τ=5 blocks all overrides
    text_scored = [dict(s, task="text") for s in scored]
    g = d.evaluate(reqs, text_scored, 1, 0, bootstrap=50, text_params=(1, 5))
    assert g["helpful_overrides"] + g["harmful_overrides"] + g["neutral_overrides"] == 0
    g = d.evaluate(reqs, scored, 1, 0, bootstrap=50, text_params=(1, 5))  # phonetic: unaffected
    assert g["helpful_overrides"] == 1


def test_pure_load_requests_contract():
    good = {"id": "a", "context": "", "reading": ["ㄅㄚ", "ㄅㄚ"], "gold": "八八", "engine_default": 0,
            "candidates": [{"text": "八八", "log_score": -1.0}, {"text": "吧吧", "log_score": -1.0}]}
    bad = [dict(good, engine_default=-1), dict(good, engine_default=2), dict(good, engine_default=True),
           dict(good, engine_default=1, candidates=[{"text": "八八", "log_score": -1.0}, {"text": "吧吧", "log_score": -2.0}]),
           dict(good, candidates=[{"text": "八八", "log_score": -3.0}, {"text": "吧吧", "log_score": -2.0}]),
           dict(good, candidates=[{"text": "八八"}, {"text": "吧吧", "log_score": -2.0}]),
           # json.loads accepts NaN/Infinity; NaN compares false with everything and would slip past the max check
           dict(good, engine_default=1, candidates=[{"text": "八八", "log_score": float("nan")}, {"text": "吧吧", "log_score": -2.0}]),
           dict(good, candidates=[{"text": "八八", "log_score": float("inf")}, {"text": "吧吧", "log_score": -2.0}])]
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "r.jsonl"
        path.write_text(json.dumps(good, ensure_ascii=False) + "\n", encoding="utf-8")
        assert len(d.load_requests(path)) == 1  # tie with the default is accepted
        for b in bad:
            path.write_text("\n" + json.dumps(b, ensure_ascii=False) + "\n", encoding="utf-8")
            try:
                d.load_requests(path)
            except ValueError as e:
                assert ":2:" in str(e), e  # error names the line
            else:
                raise AssertionError(f"accepted {b}")


def test_pure_hash_mismatch_fails():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "a.bin").write_bytes(b"abc")
        (tmp / "manifest.json").write_text(json.dumps({"files": {"a.bin": d.sha256(tmp / "a.bin")}}))
        d.verify_files(tmp)  # matching hash passes
        (tmp / "a.bin").write_bytes(b"abd")
        try:
            d.verify_files(tmp)
        except d.HashMismatch:
            return
        raise AssertionError("tampered file passed verification")


def test_pure_cli_empty_input_and_grid_flags():
    def exit_code(argv):
        try:
            d.main(argv)
        except SystemExit as e:
            return e.code
    with tempfile.TemporaryDirectory() as tmp:
        empty = Path(tmp) / "empty.jsonl"
        empty.write_text("\n", encoding="utf-8")
        # 0 requests must stop with exit 2 before any model load, not ZeroDivisionError in evaluate.
        assert exit_code(["--input", str(empty), "--out", f"{tmp}/r", "--model-dir", f"{tmp}/none"]) == 2
        assert not (Path(tmp) / "none").exists()
        for bad in ("0.5,,1", "a", "1,nan", "inf"):
            assert exit_code(["--input", str(FIXTURE), "--out", f"{tmp}/r", "--weights", bad]) == 2, bad
            assert exit_code(["--input", str(FIXTURE), "--out", f"{tmp}/r", "--margins", bad]) == 2, bad
    assert d.float_list("0.5,1,1.5") == (0.5, 1.0, 1.5) and d.float_list("2") == (2.0,)


# ---- with model ----

def test_fixture_end_to_end():
    reqs = d.load_requests(FIXTURE)
    assert len(reqs) == 20
    res = d.run(reqs, d.Scorer(), bootstrap=100)
    s = res["summary"]
    # Oracle: recomputed from scratch must equal the hand-built gold_in_candidates flags.
    assert s["oracle_top1"] == sum(r["gold_in_candidates"] for r in reqs) / 20 == 18 / 20
    assert s["gold_in_candidates_field_mismatch"] == 0
    assert s["fallbacks"] == {"oov": 1, "correction": 1}
    for g in res["grid"]:
        if g["w"] == 0:  # with w=0 only engine scores count, so the default always wins
            assert g["rerank_top1"] == g["baseline_top1"]
            assert g["helpful_overrides"] == g["harmful_overrides"] == g["neutral_overrides"] == 0
            assert g["ci95_pp"] == [0.0, 0.0]
        assert g["rerank_top1"] <= s["oracle_top1"]
    assert res["subsets_at_manifest_point"]["text_mode"]["n"] == 2
    assert sum(p["task"] == "text" for p in res["per_request"]) == 2


def test_text_mode_tensors_and_fallback():
    sc = d.Scorer()
    seen, run = [], sc.session.run
    sc.session.run = lambda names, feeds: (seen.append(feeds), run(names, feeds))[1]
    sc.text_log_prob("我", "好")
    f = {k: v.tolist() for k, v in seen[0].items()}
    me, hao = sc.chars["我"], sc.chars["好"]
    assert f["ids"] == [[1, me, 2, 3]] and f["bases"] == f["tones"] == [[0, 0, 0, 0]]
    assert f["types"] == [[0, 0, 0, 0]] and f["positions"] == [[0, 1, 2, 3]]
    assert f["proj_pos"] == [3] and f["target_node"] == [[0]] and f["target_ids"] == [[hao - 6]]
    probe = d.load_requests(PROBE)
    no_ctx = next(r for r in probe if not r["context"])
    assert sc.task(no_ctx) == "phonetic" and d.Scorer(text_mode=False).task(probe[0]) == "phonetic"
    res = d.run(probe, sc, bootstrap=50)
    assert res["summary"]["text_mode_no_context_phonetic"] == 1
    for r, p in zip(probe, res["per_request"]):  # sanity: the common character wins in text mode
        if p["task"] == "text":
            gold = [c["text"] for c in r["candidates"]].index(r["gold"])
            assert max(range(len(p["model"])), key=p["model"].__getitem__) == gold, r["id"]
    # Custom grid + truncated text/phonetic comparison (5 text requests, limit 2).
    res = d.run(probe, sc, bootstrap=10, weights=(0.5, 1), margins=(2,))
    assert [(g["w"], g["tau"]) for g in res["grid"]] == [(0.5, 2), (1, 2)]
    meta = {"input": "probe", "hashes": sc.hashes, "neutral": True, "text_mode": True, "ort": "x", "threads": 2,
            "time": "t", "manifest_point": d.manifest_point(sc)}
    rows = lambda md: {line.split(" | ")[0] for line in md.splitlines() if line.startswith("| probe-")}
    cut, full = d.markdown(res, meta, probe, compare_limit=2), d.markdown(res, meta, probe, compare_limit=None)
    assert len(rows(cut)) == 2 and len(rows(full)) == 5
    assert "共 5 筆 text 請求，只列前 2 筆" in cut and "只列前" not in full


def card_namespace():
    """Executes the model card's own Python example (from the pinned README) against the local model."""
    readme = (d.MODEL_DIR / "README.md").read_text(encoding="utf-8")
    code = readme.split("```python\n", 1)[1].split("```", 1)[0]
    code = code.replace('snapshot_download("Funmula/0c-sequence-d512")', repr(str(d.MODEL_DIR)))
    code = code.split("\nprint(", 1)[0]  # drop the trailing demo
    ns = {}
    exec(code, ns)
    return ns


def capture_feeds(session):
    seen, run = [], session.run
    session.run = lambda names, feeds: (seen.append(feeds), run(names, feeds))[1]
    return seen


def test_matches_model_card():
    """Every tensor fed to ONNX and every phonetic score must equal the model card example on the whole fixture."""
    card, mine = card_namespace(), d.Scorer()
    card_feeds, my_feeds = capture_feeds(card["session"]), capture_feeds(mine.session)
    n = 0
    for r in d.load_requests(FIXTURE):
        if d.fallback_reason(r, mine):
            continue
        for c in r["candidates"]:
            card_feeds.clear(), my_feeds.clear()
            a, b = card["score"](r["context"], r["reading"], c["text"]), mine.score(r["context"], r["reading"], c["text"])
            assert a == b, (r["id"], c["text"], a, b)
            assert len(card_feeds) == len(my_feeds)  # same number of runs (neutral fallback included)
            for fa, fb in zip(card_feeds, my_feeds):
                assert fa.keys() == fb.keys()
                for k in fa:
                    assert fa[k].dtype == fb[k].dtype and fa[k].shape == fb[k].shape and (fa[k] == fb[k]).all(), k
            n += 1
    assert n >= 40, n


def test_neutral_rule_toggle():
    on, off = d.Scorer(), d.Scorer(neutral=False)
    args = ("我們走", ["ㄏㄠˇ", "ㄅㄚ"], "好吧")
    assert on.score(*args) >= off.score(*args)
    assert off.score(*args) == off.log_prob(*args)


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
