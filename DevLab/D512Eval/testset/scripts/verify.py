"""驗證 testset 交付物；可重跑產生器並保存初審前後 SHA-256。"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

from generate import DEFAULT_LEXICON, ROOT, Lexicon, dump_json, sha256
from validate import validate_files

ARTIFACTS = ["data/generated/dev.jsonl", "data/generated/held-out.jsonl",
             "data/generated/split-manifest.json", "data/sample.jsonl",
             "reports/stats.json", "reports/lexicon-stats.json"]


def verify(reproduce: bool) -> dict:
    before = {name: sha256(ROOT / name) for name in ARTIFACTS}
    if reproduce:
        subprocess.run([sys.executable, str(ROOT / "scripts/generate.py")], cwd=ROOT, check=True)
    after = {name: sha256(ROOT / name) for name in ARTIFACTS}
    if reproduce and before != after:
        raise ValueError("重跑六份交付物的 SHA-256 不一致")
    validation = validate_files([ROOT / "data/generated/dev.jsonl", ROOT / "data/generated/held-out.jsonl"], 3000)
    sample = validate_files([ROOT / "data/sample.jsonl"])
    if next(iter(sample.values())) > 200:
        raise ValueError("小樣本超過 200 筆")
    splits = {name: [json.loads(line) for line in (ROOT / f"data/generated/{name}.jsonl").read_text().splitlines()]
              for name in ("dev", "held-out")}
    gold_sets = {name: {case["gold"] for case in rows} for name, rows in splits.items()}
    if gold_sets["dev"] & gold_sets["held-out"]:
        raise ValueError("dev／held-out gold 交集非空")
    manifest = json.loads((ROOT / "data/generated/split-manifest.json").read_text())
    owners: dict[str, str] = {}
    for row in manifest:
        if row["document"] in owners and owners[row["document"]] != row["split"]:
            raise ValueError("同文件跨集")
        owners[row["document"]] = row["split"]
    if len(manifest) != sum(validation.values()):
        raise ValueError("分割 manifest 筆數不符")
    baseline = json.loads((ROOT / "reports/pre-review-state.json").read_text())
    dp_baseline_path = ROOT / "reports/pre-dp-state.json"
    comparison_baseline = json.loads(dp_baseline_path.read_text()) if dp_baseline_path.exists() else baseline
    for name in ("data/raw/documents.jsonl", "data/raw/download-manifest.json"):
        if sha256(ROOT / name) != baseline["sha256"][name]:
            raise ValueError(f"搬移或修正改動了凍結 raw：{name}")
    by_gold = {case["gold"]: case for rows in splits.values() for case in rows}
    failures = []
    for old in baseline["reviewer_failures"]:
        current = by_gold.get(old["gold"])
        if old["gold"] == "原來貼了新聞沒事" and current is not None:
            if current["reading"][current["gold"].index("了")] != "ㄌㄜ˙":
                raise ValueError("初審的完成助詞了仍錯讀")
        elif current is not None:
            raise ValueError(f"初審應排除的已知錯句仍存在：{old['gold']}")
        failures.append({"id": old["id"], "gold": old["gold"], "before_reading": old["reading"],
                         "after_reading": current["reading"] if current else None,
                         "status": "讀音修正" if current else "整句丟棄"})
    lexicon = Lexicon.load(DEFAULT_LEXICON)
    arabic_segments = lexicon.segment("阿拉伯語中的")
    if arabic_segments != ["阿拉伯語", "中", "的"] or lexicon.annotate("阿拉伯語中的")[0] is not None:
        raise ValueError("阿拉伯語中的 DP 分詞或多音字 fallback 丟棄規則錯誤")
    if "阿拉伯語中的" in by_gold:
        raise ValueError("阿拉伯語中的 應依多音字 fallback 整句丟棄")
    tests = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"],
                           cwd=ROOT, capture_output=True, text=True, check=True)
    match = re.search(r"Ran (\d+) tests", tests.stderr)
    repository = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], cwd=ROOT, text=True).strip())
    prefix = ROOT.relative_to(repository).as_posix() + "/"
    tracked = subprocess.check_output(["git", "diff", "--name-only"], cwd=ROOT, text=True).splitlines()
    untracked = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "--full-name"],
                                        cwd=ROOT, text=True).splitlines()
    if any(not name.startswith(prefix) for name in tracked + untracked):
        raise ValueError("修改／新增檔案超過 testset 範圍")
    for name in tracked + untracked:
        result = subprocess.run(["git", "diff", "--no-index", "--check", "/dev/null", str(repository / name)],
                                capture_output=True, text=True)
        if result.returncode not in (0, 1) or result.stdout or result.stderr:
            raise ValueError(f"空白檢查失敗：{name}")
    ignored = {name: subprocess.run(["git", "check-ignore", "--quiet", "--", str(ROOT / name)],
                                    cwd=ROOT).returncode == 0
               for name in (".venv", "data/raw", "data/generated", "tmp")}
    if not all(ignored.values()):
        raise ValueError("大型資料／環境沒有被 Git 忽略")
    root_prefix = str(ROOT.relative_to(repository))
    command_prefix = f"uv run --directory {root_prefix} --offline --no-sync python "
    report = {
        "status": "通過", "python": sys.version.split()[0], "project_root": str(ROOT.relative_to(ROOT.parents[2])),
        "commands": [command_prefix + "scripts/generate.py",
                     command_prefix + "scripts/validate.py data/generated/dev.jsonl data/generated/held-out.jsonl --minimum-held-out 3000",
                     command_prefix + "-m unittest discover -s tests -v",
                     command_prefix + "scripts/verify.py --reproduce"],
        "schema_validation": {Path(path).relative_to(ROOT).as_posix(): count for path, count in validation.items()},
        "sample_validation": {Path(path).relative_to(ROOT).as_posix(): count for path, count in sample.items()},
        "held_out_minimum": 3000, "gold_overlap": 0, "document_overlap": 0,
        "split_manifest_cases": len(manifest), "known_review_failures": failures,
        "raw_unchanged": True, "unit_tests": {"count": int(match[1]) if match else None,
                                              "returncode": tests.returncode, "output": tests.stderr},
        "reproducibility": {"repeated": reproduce, "files": len(after), "byte_identical": before == after if reproduce else None,
                            "sha256": after},
        "pre_post_baseline": "reports/pre-dp-state.json" if dp_baseline_path.exists() else "reports/pre-review-state.json",
        "pre_post_sha256": {name: {"before": comparison_baseline["sha256"].get(name), "after": digest}
                            for name, digest in after.items()},
        "gitignore_verified": ignored, "tracked_files_modified": tracked, "untracked_scope": prefix,
        "commit_created": False, "push_performed": False,
        "arabic_segmentation": {"gold": "阿拉伯語中的", "segments": arabic_segments,
                                "status": "分詞修正後依既有多音字 fallback 規則整句丟棄"},
        "limitations": ["初審四筆與複審分詞錯例的處置已檢查；新版獨立抽查 20 筆的語境讀音仍待 reviewer 複審"],
    }
    dump_json(ROOT / "reports/verification.json", report)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reproduce", action="store_true", help="重跑一次產生器，比對六份產物")
    args = parser.parse_args()
    try:
        report = verify(args.reproduce)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"驗證失敗：{exc}\n")
    print(json.dumps({"status": report["status"], "cases": report["schema_validation"],
                      "tests": report["unit_tests"]["count"], "gold_overlap": 0,
                      "reproduced": args.reproduce}, ensure_ascii=False))


if __name__ == "__main__":
    main()
