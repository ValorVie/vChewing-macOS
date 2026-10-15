#!/usr/bin/env python3
"""D512 offline rerank harness: scores dumper JSONL requests with the public
Funmula/0c-sequence-d512 checkpoint and sweeps the fusion weight / margin.

Usage: .venv/bin/python d512eval.py --input <requests.jsonl> --out <report-stem>
"""
import argparse
import hashlib
import json
import math
import statistics
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = "Funmula/0c-sequence-d512"
REVISION = "d512-pf512-20260926"
MODEL_DIR = HERE / "models" / REVISION
WEIGHTS = (0, 1, 2, 3, 5, 8)
MARGINS = (0, 0.25, 0.5, 1)
TEXT_COMPARE_LIMIT = 50  # requests listed in the text/phonetic comparison unless --text-compare-all
TONES = {"ˊ": 2, "ˇ": 3, "ˋ": 4, "˙": 5}  # no mark = first tone


class HashMismatch(RuntimeError):
    pass


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_files(model_dir):
    """Checks every file listed in manifest.json; raises HashMismatch on any difference."""
    manifest = json.loads((model_dir / "manifest.json").read_text(encoding="utf-8"))
    actual = {name: sha256(model_dir / name) for name in manifest["files"]}
    bad = {n: (manifest["files"][n], h) for n, h in actual.items() if h != manifest["files"][n]}
    if bad:
        raise HashMismatch(f"SHA-256 mismatch (expected, actual): {bad}")
    return manifest, actual


def fetch(model_dir=MODEL_DIR):
    from huggingface_hub import HfApi, snapshot_download

    snapshot_download(REPO, revision=REVISION, local_dir=model_dir)
    return HfApi().model_info(REPO, revision=REVISION).sha


class Scorer:
    def __init__(self, model_dir=MODEL_DIR, threads=2, neutral=True, text_mode=True):
        import onnxruntime as ort

        self.text_mode = text_mode
        self.manifest, self.hashes = verify_files(model_dir)
        vocab = json.loads((model_dir / "vocab.json").read_text(encoding="utf-8"))
        self.chars = {c: i + 8 for i, c in enumerate(vocab["characters"])}  # 0–7 special, 4 = UNK
        self.bases = {b: i + 2 for i, b in enumerate(vocab["bases"])}
        self.neutral = set(self.manifest.get("neutral_tolerant_last", [])) if neutral else set()
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = threads
        opts.inter_op_num_threads = 1
        self.session = ort.InferenceSession(str(model_dir / "model.onnx"), opts, providers=["CPUExecutionProvider"])

    def syllable(self, s):
        base = s[:-1] if s[-1] in TONES else s
        return self.bases[base], TONES.get(s[-1], 1)

    def log_prob(self, context, reading, candidate):
        # Phonetic task, verbatim port of the model card: [BOS] context [SEP] reading×n [OUT] candidate[:-1].
        return self._run(context, [self.syllable(s) for s in reading], candidate)

    def text_log_prob(self, context, candidate):
        # Text task (manifest limits.text_mode, inferred — not in the model card): no reading slots,
        # [BOS] context [SEP] [OUT] candidate[:-1]; bases/tones all 0.
        return self._run(context, [], candidate)

    def _run(self, context, sounds, candidate):
        head = [1] + [self.chars.get(c, 4) for c in context[-64:]] + [2]
        cand = [self.chars[c] for c in candidate]
        n, k, out = len(cand), len(sounds), len(head) + len(sounds)
        ids = head + [0] * k + [3] + cand[:-1]
        bases = [0] * len(head) + [b for b, _ in sounds] + [0] * n
        tones = [0] * len(head) + [t for _, t in sounds] + [0] * n
        types = [0] * len(head) + [1] * k + [0] + [2] * (n - 1)
        L = len(ids)
        row = lambda x: np.array([x], dtype=np.int64)
        feeds = {"ids": row(ids), "bases": row(bases), "tones": row(tones), "types": row(types),
                 "positions": row(list(range(L))), "mask": np.tril(np.ones((L, L), dtype=bool))[None, None],
                 "proj_pos": np.arange(out, L, dtype=np.int64), "target_node": row(list(range(n))),
                 "target_ids": row([x - 6 for x in cand])}
        return float(self.session.run(["scores"], feeds)[0][0])

    def score(self, context, reading, candidate):
        s = self.log_prob(context, reading, candidate)
        last = reading[-1]
        base = last[:-1] if last[-1] in TONES else last
        if base in self.neutral and last[-1] != "˙":  # also score last syllable as neutral tone, keep max
            s = max(s, self.log_prob(context, reading[:-1] + [base + "˙"], candidate))
        return s

    def task(self, req):
        return "text" if self.text_mode and len(req["reading"]) == 1 and req["context"] else "phonetic"

    def score_request(self, req):
        if self.task(req) == "text":
            return [self.text_log_prob(req["context"], c["text"]) for c in req["candidates"]]
        return [self.score(req["context"], req["reading"], c["text"]) for c in req["candidates"]]


def load_requests(path):
    """Parses dumper JSONL and enforces the input contract; any violation raises with the line number."""
    reqs = []
    for no, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        r = json.loads(line)
        where = f"{path}:{no}"
        for key in ("id", "context", "reading", "candidates", "gold"):
            if key not in r:
                raise ValueError(f"{where}: missing field {key!r}")
        cands = r["candidates"]
        if not cands:
            raise ValueError(f"{where}: empty candidates")
        texts = [c["text"] for c in cands]
        if any(len(t) != len(r["reading"]) for t in texts) or len(set(texts)) != len(texts):
            raise ValueError(f"{where}: candidate texts must be unique and match reading length")
        scores = [c.get("log_score") for c in cands]
        if not all(isinstance(s, (int, float)) and not isinstance(s, bool) and math.isfinite(s) for s in scores):
            raise ValueError(f"{where}: every candidate needs a finite numeric log_score")
        d = r.setdefault("engine_default", 0)
        if not isinstance(d, int) or isinstance(d, bool) or not 0 <= d < len(cands):
            raise ValueError(f"{where}: engine_default {d!r} out of range 0..{len(cands) - 1}")
        # Without this, w=0 would still override toward the engine argmax and the gate's
        # "w=0 equals baseline" invariant breaks. Ties are fine: overriding needs a strict > τ margin.
        if scores[d] < max(scores):
            raise ValueError(f"{where}: log_score of engine_default ({scores[d]}) is not the maximum ({max(scores)})")
        reqs.append(r)
    return reqs


def fallback_reason(req, scorer):
    """Manifest limits: whole_case_fallback for OOV characters and corrections."""
    lim = scorer.manifest["limits"]
    if len(req["reading"]) > lim["max_syllables"] or len(req["candidates"]) > lim["max_candidates"]:
        return "out_of_limits"
    if any(ch not in scorer.chars for c in req["candidates"] for ch in c["text"]):
        return "oov"
    if any(seg.get("Correction") for c in req["candidates"] for seg in c.get("segments", [])):
        return "correction"
    try:
        [scorer.syllable(s) for s in req["reading"]]
    except (KeyError, IndexError):
        return "bad_reading"
    return None


def score_all(reqs, scorer, warmup=3):
    """Model scores per candidate (independent of w/τ) plus per-request latency in ms."""
    scorable = [r for r in reqs if fallback_reason(r, scorer) is None]
    for r in scorable[:1] * warmup:  # warm-up runs, excluded from latency
        scorer.score_request(r)
    out = []
    for r in reqs:
        reason = fallback_reason(r, scorer)
        if reason:
            out.append({"fallback": reason, "task": None, "model": None, "ms": None})
            continue
        t = time.perf_counter()
        model = scorer.score_request(r)
        entry = {"fallback": None, "task": scorer.task(r), "model": model, "ms": (time.perf_counter() - t) * 1000}
        if entry["task"] == "text":  # side-by-side phonetic scores for the report, outside the timed region
            entry["model_phonetic"] = [scorer.score(r["context"], r["reading"], c["text"]) for c in r["candidates"]]
        out.append(entry)
    return out


def choose(engine, model, default, w, tau):
    if model is None:
        return default
    fused = [e + w * m for e, m in zip(engine, model)]
    best = max(range(len(fused)), key=fused.__getitem__)
    return best if best != default and fused[best] - fused[default] > tau else default


def paired_bootstrap(base, rerank, n=1000, seed=20261015):
    diff = np.asarray(rerank, float) - np.asarray(base, float)
    idx = np.random.default_rng(seed).integers(0, len(diff), (n, len(diff)))
    means = diff[idx].mean(axis=1)
    return float(np.percentile(means, 2.5)), float(np.percentile(means, 97.5))


def evaluate(reqs, scored, w, tau, bootstrap=1000, text_params=None):
    """text_params=(w, τ) overrides the pair for requests scored with the text task."""
    base, rerank, helped, hurt, neutral_swap = [], [], 0, 0, 0
    for r, s in zip(reqs, scored):
        d = r.get("engine_default", 0)
        texts = [c["text"] for c in r["candidates"]]
        rw, rt = text_params if text_params and s.get("task") == "text" else (w, tau)
        pick = choose([c["log_score"] for c in r["candidates"]], s["model"], d, rw, rt)
        b, k = texts[d] == r["gold"], texts[pick] == r["gold"]
        base.append(b)
        rerank.append(k)
        helped += k and not b
        hurt += b and not k
        neutral_swap += pick != d and not b and not k
    n = len(reqs)
    lo, hi = paired_bootstrap(base, rerank, bootstrap)
    return {"w": w, "tau": tau, "text_params": text_params, "n": n, "baseline_top1": sum(base) / n,
            "rerank_top1": sum(rerank) / n, "delta_pp": 100 * (sum(rerank) - sum(base)) / n,
            "ci95_pp": [100 * lo, 100 * hi], "helpful_overrides": helped, "harmful_overrides": hurt,
            "neutral_overrides": neutral_swap}


def subset_of(r, s):
    if s.get("task") == "text":
        return "text_mode"
    return "single_syllable_phonetic" if len(r["reading"]) == 1 else r.get("mode", "unknown")


def summarize(reqs, scored, scorer):
    ms = [s["ms"] for s in scored if s["ms"] is not None]
    oracle = [r["gold"] in {c["text"] for c in r["candidates"]} for r in reqs]
    flagged = sum(1 for r, o in zip(reqs, oracle) if "gold_in_candidates" in r and r["gold_in_candidates"] != o)
    fallbacks = {}
    for s in scored:
        if s["fallback"]:
            fallbacks[s["fallback"]] = fallbacks.get(s["fallback"], 0) + 1
    no_context = sum(1 for r, s in zip(reqs, scored)
                     if scorer.text_mode and s["task"] == "phonetic" and len(r["reading"]) == 1)
    lat = {}
    if ms:
        q = sorted(ms)
        lat = {"n": len(q), "median_ms": statistics.median(q), "p95_ms": q[min(len(q) - 1, int(0.95 * len(q)))],
               "mean_ms": statistics.fmean(q), "max_ms": q[-1]}
    return {"n": len(reqs), "oracle_top1": sum(oracle) / len(reqs), "gold_in_candidates_field_mismatch": flagged,
            "fallbacks": fallbacks, "text_mode_no_context_phonetic": no_context, "latency": lat}


def manifest_point(scorer):
    m = scorer.manifest
    return m["weight"], m["margin"], (m["text_weight"], m["text_margin"])


def run(reqs, scorer, bootstrap=1000, weights=WEIGHTS, margins=MARGINS):
    scored = score_all(reqs, scorer)
    grid = [evaluate(reqs, scored, w, t, bootstrap) for w in weights for t in margins]
    w, tau, text_params = manifest_point(scorer)
    subsets = {"all": evaluate(reqs, scored, w, tau, bootstrap, text_params)}
    for name in sorted({subset_of(r, s) for r, s in zip(reqs, scored)}):
        sub_reqs, sub_scored = zip(*[(r, s) for r, s in zip(reqs, scored) if subset_of(r, s) == name])
        subsets[name] = evaluate(list(sub_reqs), list(sub_scored), w, tau, bootstrap, text_params)
    return {"summary": summarize(reqs, scored, scorer), "grid": grid, "subsets_at_manifest_point": subsets,
            "per_request": [{"id": r["id"], **s} for r, s in zip(reqs, scored)]}


def markdown(res, meta, reqs, compare_limit=TEXT_COMPARE_LIMIT):
    s, lat = res["summary"], res["summary"]["latency"]
    pct = lambda x: f"{100 * x:.2f}%"
    w, tau, (tw, tt) = meta["manifest_point"]
    lines = [f"# D512 離線重排評測報告", "",
             f"- 輸入：`{meta['input']}`（{s['n']} 筆請求）",
             f"- 模型：`{REPO}` @ `{REVISION}`；model.onnx `{meta['hashes']['model.onnx']}`、vocab.json `{meta['hashes']['vocab.json']}`（與 manifest 一致）",
             f"- 輕聲備援：{'開' if meta['neutral'] else '關'}；單音節 text 模式：{'開' if meta['text_mode'] else '關'}；"
             f"onnxruntime {meta['ort']}，CPU，intra_op_num_threads={meta['threads']}",
             f"- 產生時間：{meta['time']}", "",
             "## 總覽", "",
             f"- baseline top-1（引擎預設 == gold）：{pct(res['grid'][0]['baseline_top1'])}",
             f"- oracle（gold 在候選內）：{pct(s['oracle_top1'])}",
             f"- 整例保留預設（不送模型）：{s['fallbacks'] or '無'}",
             f"- 單音節但無前文、退回 phonetic 模式：{s['text_mode_no_context_phonetic']} 筆",
             f"- `gold_in_candidates` 欄位與實算不符：{s['gold_in_candidates_field_mismatch']} 筆"]
    if lat:
        lines.append(f"- 每請求延遲（{lat['n']} 筆，排除暖機）：中位 {lat['median_ms']:.1f} ms、p95 {lat['p95_ms']:.1f} ms、"
                     f"平均 {lat['mean_ms']:.1f} ms、最大 {lat['max_ms']:.1f} ms")
    lines += ["", "## w／τ 網格掃描", "", "fused = engine_log_score + w × model_score；非預設候選須以 > τ 勝過預設才覆蓋。"
              "全部請求（含 text 模式）共用同一組 w／τ。CI 為 paired bootstrap 95%（重排 − baseline，pp）。", "",
              "| w | τ | 重排 top-1 | Δ (pp) | 95% CI (pp) | 有益覆蓋 | 有害覆蓋 | 中性覆蓋 |", "|---|---|---|---|---|---|---|---|"]
    for g in res["grid"]:
        lines.append(f"| {g['w']} | {g['tau']} | {pct(g['rerank_top1'])} | {g['delta_pp']:+.2f} | "
                     f"[{g['ci95_pp'][0]:+.2f}, {g['ci95_pp'][1]:+.2f}] | {g['helpful_overrides']} | "
                     f"{g['harmful_overrides']} | {g['neutral_overrides']} |")
    lines += ["", f"## manifest 操作點（w={w}、τ={tau}；text 模式請求 w={tw}、τ={tt}）", "",
              "| 分組 | n | baseline | 重排 | Δ (pp) | 95% CI (pp) | 有益 | 有害 | 中性 |", "|---|---|---|---|---|---|---|---|---|"]
    for name, g in res["subsets_at_manifest_point"].items():
        lines.append(f"| {name} | {g['n']} | {pct(g['baseline_top1'])} | {pct(g['rerank_top1'])} | {g['delta_pp']:+.2f} | "
                     f"[{g['ci95_pp'][0]:+.2f}, {g['ci95_pp'][1]:+.2f}] | {g['helpful_overrides']} | "
                     f"{g['harmful_overrides']} | {g['neutral_overrides']} |")
    dual = [(r, p) for r, p in zip(reqs, res["per_request"]) if p.get("model_phonetic")]
    if dual:
        lines += ["", "## text 模式與 phonetic 模式分數對照", "",
                  "text 模式依 manifest `limits.text_mode` 推論（模型卡無明文）：只放前文、不放讀音 token。"
                  "下表為同一候選在兩種模式下的 logP；★ 為 gold。"
                  + (f"共 {len(dual)} 筆 text 請求，只列前 {compare_limit} 筆；加 `--text-compare-all` 列出全部，"
                     "完整分數另見 JSON `per_request`。" if compare_limit is not None and len(dual) > compare_limit else ""), "",
                  "| id | 前文 | 讀音 | 候選 | text logP | phonetic logP |", "|---|---|---|---|---|---|"]
        for r, p in dual[:compare_limit]:
            for c, t, ph in zip(r["candidates"], p["model"], p["model_phonetic"]):
                star = "★" if c["text"] == r["gold"] else ""
                lines.append(f"| {r['id']} | {r['context']} | {r['reading'][0]} | {c['text']}{star} | {t:.2f} | {ph:.2f} |")
    return "\n".join(lines) + "\n"


def float_list(text):
    """argparse type for --weights/--margins: comma-separated finite numbers, e.g. 0.5,1,1.5."""
    try:
        vals = tuple(float(x) for x in text.split(","))
    except ValueError:
        raise argparse.ArgumentTypeError(f"expected comma-separated numbers, got {text!r}")
    if not all(math.isfinite(v) for v in vals):
        raise argparse.ArgumentTypeError(f"values must be finite, got {text!r}")
    return vals


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", required=True, help="dumper JSONL")
    ap.add_argument("--out", required=True, help="output stem; writes <stem>.md and <stem>.json")
    ap.add_argument("--no-neutral", action="store_true", help="disable the neutral-tone fallback rule")
    ap.add_argument("--no-text-mode", action="store_true", help="score 1-syllable requests with the phonetic task")
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--bootstrap", type=int, default=1000)
    ap.add_argument("--model-dir", type=Path, default=MODEL_DIR)
    ap.add_argument("--weights", type=float_list, default=WEIGHTS, help="grid w values, e.g. 0.5,1,1.5")
    ap.add_argument("--margins", type=float_list, default=MARGINS, help="grid tau values, e.g. 0.5,1,2")
    ap.add_argument("--text-compare-all", action="store_true",
                    help=f"list every text request in the text/phonetic comparison (default: first {TEXT_COMPARE_LIMIT})")
    args = ap.parse_args(argv)

    reqs = load_requests(args.input)  # validate input before any download or model load
    if not reqs:
        ap.error(f"{args.input}: no requests")  # exits 2
    if not (args.model_dir / "model.onnx").exists():
        print(f"downloading {REPO}@{REVISION} -> {args.model_dir}", file=sys.stderr)
        print(f"commit {fetch(args.model_dir)}", file=sys.stderr)
    import onnxruntime

    scorer = Scorer(args.model_dir, args.threads, neutral=not args.no_neutral, text_mode=not args.no_text_mode)
    for name, h in scorer.hashes.items():
        print(f"sha256 OK {name} {h}", file=sys.stderr)
    res = run(reqs, scorer, args.bootstrap, args.weights, args.margins)
    meta = {"input": args.input, "hashes": scorer.hashes, "neutral": not args.no_neutral,
            "text_mode": not args.no_text_mode, "manifest_point": manifest_point(scorer), "threads": args.threads,
            "ort": onnxruntime.__version__, "time": time.strftime("%Y-%m-%d %H:%M:%S %z"),
            "repo": REPO, "revision": REVISION, "weights": list(args.weights), "margins": list(args.margins)}
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.with_suffix(".json").write_text(json.dumps({"meta": meta, **res}, ensure_ascii=False, indent=1), encoding="utf-8")
    out.with_suffix(".md").write_text(markdown(res, meta, reqs, None if args.text_compare_all else TEXT_COMPARE_LIMIT), encoding="utf-8")
    print(f"wrote {out.with_suffix('.md')} and {out.with_suffix('.json')}", file=sys.stderr)


if __name__ == "__main__":
    main()
