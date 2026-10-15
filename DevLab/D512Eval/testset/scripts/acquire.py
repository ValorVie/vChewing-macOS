"""獲得使用者同意後，下載明確授權的兩來源；每來源總量遠低於 2 GB。"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import time
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlencode, urlparse

from generate import ROOT, dump_json, dump_jsonl, sha256

MOZTW_REV = "b473f2a3ee52920dce26d86cc02117479e257c18"
MOZTW_BLOB = "01eeef3ae42fb6697f1a9966c22a8e025c1010cd"
MOZTW_SIZE = 217398
WIKI_LIMIT = 64 * 1024 * 1024
WIKI_TITLES = (
    "物理學 化學 生物學 地理學 地球 太陽 月球 太陽系 行星 星系 宇宙 光 聲音 電 磁場 能量 "
    "熱力學 量子力學 相對論 數學 代數 幾何 微積分 統計學 機率 集合論 數論 拓樸學 "
    "植物 動物 生態系統 光合作用 演化 細胞 遺傳學 水 氧 碳 海洋 山 河流 森林 "
    "音樂 樂器 鋼琴 小提琴 繪畫 書法 雕塑 陶瓷 建築 圖書館 博物館 教育 語言學 "
    "漢語 文字 印刷術 曆法 節氣 烹飪 茶 稻 自行車"
).split()


class Fetcher:
    def __init__(self) -> None:
        self.addresses: dict[str, str] = {}
        self.events: list[dict] = []

    def fetch(self, url: str, maximum_bytes: int, attempt: int = 0) -> bytes:
        if maximum_bytes < 1 or urlparse(url).scheme != "https":
            raise ValueError("HTTPS 下載額度不足或網址不合法")
        command = ["curl", "--fail", "--silent", "--show-error", "--proto", "=https",
                   "--connect-timeout", "5", "--max-time", "60", "--max-filesize", str(maximum_bytes),
                   "--retry", "4", "--retry-delay", "5", "--retry-max-time", "60",
                   "--user-agent", "D512Eval/0.1 (personal offline research; sequential requests)"]
        host = urlparse(url).hostname
        if host in self.addresses:
            command += ["--resolve", f"{host}:443:{self.addresses[host]}"]
        result = subprocess.run(command + [url], capture_output=True, check=False)
        if result.returncode == 6 and host not in self.addresses:
            # 本機 DNS 失敗才使用已驗證 TLS 的 Google 公開 DNS；不修改系統 DNS。
            dns_url = "https://dns.google/resolve?" + urlencode({"name": host, "type": "A"})
            dns = subprocess.run(
                ["curl", "--fail", "--silent", "--show-error", "--proto", "=https",
                 "--resolve", "dns.google:443:8.8.8.8", "--connect-timeout", "5", "--max-time", "15",
                 "--max-filesize", "65536", dns_url], capture_output=True, check=True,
            )
            answers = json.loads(dns.stdout)
            if answers.get("Status") != 0:
                raise ValueError(f"DNS 查詢失敗：{host}")
            addresses = [answer["data"] for answer in answers.get("Answer", []) if answer["type"] == 1]
            if not addresses:
                raise ValueError(f"DNS 缺少 A 記錄：{host}")
            self.addresses[host] = addresses[0]
            self.events.append({"host": host, "resolver": "https://dns.google/resolve", "address": addresses[0]})
            return self.fetch(url, maximum_bytes, attempt)
        # 某些連線代理將 HTTP 429 表示為 curl 56；仍明確退避，不依錯誤碼漏掉重試。
        if result.returncode and b"429" in result.stderr and attempt < 4:
            delay = 10 * (attempt + 1)
            print(f"HTTP 429：等待 {delay} 秒後重試（{attempt + 1}/4）", flush=True)
            time.sleep(delay)
            return self.fetch(url, maximum_bytes, attempt + 1)
        if result.returncode:
            raise ValueError(f"下載失敗（curl {result.returncode}）：{url}；{result.stderr.decode(errors='replace')}")
        if len(result.stdout) > maximum_bytes:
            raise ValueError("下載超過來源額度，拒絕保存")
        return result.stdout


class Paragraphs(HTMLParser):
    """只擷取正文 p；不收表格、引用、註腳、圖片或導航。"""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.paragraphs: list[str] = []
        self.stack: list[tuple[str, bool]] = []
        self.buffer: list[str] = []
        self.in_paragraph = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        classes = set((attributes.get("class") or "").split())
        blocked = (tag in {"table", "sup", "style", "script", "blockquote", "figure", "nav"}
                   or bool(classes & {"reference", "navbox", "reflist", "hatnote", "infobox", "mw-editsection"})
                   or any(skip for _, skip in self.stack))
        if tag not in {"br", "hr", "img", "input", "meta", "link", "wbr", "source"}:
            self.stack.append((tag, blocked))
        if tag == "p" and not blocked:
            self.in_paragraph = True
            self.buffer = []
        if tag == "br" and self.in_paragraph and not blocked:
            self.buffer.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag == "p" and self.in_paragraph:
            text = "".join(self.buffer).strip()
            if text:
                self.paragraphs.append(text)
            self.in_paragraph = False
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                self.stack = self.stack[:index]
                break

    def handle_data(self, data: str) -> None:
        if self.in_paragraph and not any(skip for _, skip in self.stack):
            self.buffer.append(data)


def acquire(approval_note: str) -> dict:
    raw = ROOT / "data/raw"
    raw.mkdir(parents=True, exist_ok=True)
    manifest_path = raw / "download-manifest.json"
    if manifest_path.exists() or (raw / "documents.jsonl").exists():
        raise ValueError("已有凍結下載；重跑產生器即可，不覆寫語料")
    fetcher = Fetcher()
    url = f"https://raw.githubusercontent.com/moztw/cc0-sentences/{MOZTW_REV}/zh-TW/g0v_slack_rand0m.txt"
    path = raw / "moztw-g0v.txt"
    content = path.read_bytes() if path.exists() else fetcher.fetch(url, MOZTW_SIZE)
    if len(content) != MOZTW_SIZE:
        raise ValueError("MozTW 檔案大小與提案 metadata 不符")
    blob = hashlib.sha1(f"blob {len(content)}\0".encode() + content).hexdigest()
    if blob != MOZTW_BLOB:
        raise ValueError("MozTW Git blob 校驗失敗")
    path.write_bytes(content)
    documents = []
    for number, line in enumerate(content.decode("utf-8").splitlines(), 1):
        if line.strip():
            documents.append({
                "source_id": "moztw-g0v-cc0", "document_id": f"{MOZTW_BLOB}:L{number}",
                "ordered_context": False, "paragraphs": [line],
                "attribution": f"MozTW/g0v #rand0m 參與者; CC0-1.0; "
                               f"https://github.com/moztw/cc0-sentences/blob/{MOZTW_REV}/zh-TW/g0v_slack_rand0m.txt#L{number}; "
                               "切句並以 vChewing 詞庫合成注音",
            })
    pages, wiki_bytes = [], 0
    cache = raw / "wikipedia"
    cache.mkdir(exist_ok=True)
    for index, title in enumerate(WIKI_TITLES):
        page_path = cache / f"{index:03d}.json"
        query = {"action": "parse", "page": title, "prop": "text|revid", "variant": "zh-tw",
                 "redirects": 1, "format": "json", "formatversion": 2, "maxlag": 5}
        api_url = "https://zh.wikipedia.org/w/api.php?" + urlencode(query)
        payload = page_path.read_bytes() if page_path.exists() else None
        # 只有未完成下載時才會走到此處；缺少版本欄位的舊暫存不得當作凍結資料。
        downloaded = payload is None or "revid" not in json.loads(payload).get("parse", {})
        if downloaded:
            payload = fetcher.fetch(api_url, WIKI_LIMIT - wiki_bytes)
        wiki_bytes += len(payload)
        if wiki_bytes > WIKI_LIMIT:
            raise ValueError("維基百科下載總量超過 64 MiB")
        data = json.loads(payload)
        if "error" in data:
            raise ValueError(f'維基百科 API 拒絕：{data["error"]}')
        page = data["parse"]
        parser = Paragraphs()
        parser.feed(page["text"])
        if not parser.paragraphs:
            raise ValueError(f"沒有可擷取的正文段落：{title}")
        permanent_url = f'https://zh.wikipedia.org/w/index.php?oldid={page["revid"]}'
        page_path.write_bytes(payload)
        documents.append({
            "source_id": "wikipedia-zh-tw", "document_id": str(page["pageid"]),
            "ordered_context": True, "paragraphs": parser.paragraphs,
            "attribution": f'中文維基百科〈{page["title"]}〉貢獻者; CC-BY-SA-4.0; {permanent_url}; '
                           "zh-tw 變體、擷取段落、切句並以 vChewing 詞庫合成注音",
        })
        pages.append({"requested_title": title, "title": page["title"], "pageid": page["pageid"],
                      "revision": page["revid"], "url": permanent_url, "raw_file": page_path.name,
                      "bytes": len(payload), "sha256": sha256(page_path), "paragraphs": len(parser.paragraphs)})
        print(f"維基百科 {index + 1}/{len(WIKI_TITLES)}：{title}", flush=True)
        if downloaded:
            time.sleep(5)
    dump_jsonl(raw / "documents.jsonl", documents)
    manifest = {"approval_note": approval_note, "sources": {
        "moztw-g0v-cc0": {"url": url, "revision": MOZTW_REV, "git_blob": blob,
                           "bytes": len(content), "sha256": sha256(path), "license": "CC0-1.0"},
        "wikipedia-zh-tw": {"bytes": wiki_bytes, "limit_bytes": WIKI_LIMIT,
                            "license": "CC-BY-SA-4.0", "pages": pages}},
        "dns_fallback": fetcher.events, "documents": len(documents),
        "documents_sha256": sha256(raw / "documents.jsonl")}
    dump_json(manifest_path, manifest)
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--approval-note", required=True, help="使用者實際同意這兩來源的訊息；未同意不得執行")
    args = parser.parse_args()
    if not args.approval_note.strip():
        parser.error("必須保留實際的來源同意訊息")
    try:
        manifest = acquire(args.approval_note)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"下載失敗：{exc}\n")
    print(json.dumps({"documents": manifest["documents"], "status": "下載完成"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
