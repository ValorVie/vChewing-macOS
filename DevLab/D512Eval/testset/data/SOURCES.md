# D512 評測語料來源

查證日期：2026-10-15。使用者已明確同意以下兩個來源；正式語料與口語語料都保留來源識別，只使用授權明確的文字。每一來源的下載總量上限為 2,000,000,000 bytes；維基百科另受核准的 64 MiB 上限約束。

| 來源與用途 | 授權與證據 | 取得方式與大小 | 與 0c 訓練資料重疊的可能性 |
| --- | --- | --- | --- |
| 中文維基百科 `zh-tw` 變體，百科說明作為正式文體 | [Wikimedia 使用條款 §7](https://foundation.wikimedia.org/wiki/Policy:Terms_of_Use#7._Licensing_of_Content)：文字可依 CC BY-SA 4.0 重用。每筆附原條目永久版本網址、授權與「切句、加注音」修改說明；抽樣衍生資料依 CC BY-SA 4.0 釋出 | 透過 MediaWiki Action API，固定 64 個一般知識條目，`action=parse&prop=text\|revid&variant=zh-tw`，擷取段落、不抓圖片或完整 dump。**凍結原始回應 21,310,404 bytes（20.32 MiB）**，低於 64 MiB；逐頁 revision／SHA-256 存 raw manifest | 論文第 4 頁指出 0c 使用新聞與財經討論；一般知識條目降低同領域比例，但條目可能引用新聞，也可能被訓練資料轉載。沒有公開訓練逐句清單，不能保證不重疊 |
| MozTW CC0 句庫的 `zh-TW/g0v_slack_rand0m.txt`，社群聊天作為口語文體 | [zh-TW README](https://github.com/moztw/cc0-sentences/blob/master/zh-TW/README.md) 明載此檔由參與者聲明 CC0；[LICENSE.md](https://github.com/moztw/cc0-sentences/blob/master/LICENSE.md) 連到 CC0 1.0。[此檔整理說明](https://github.com/moztw/cc0-sentences/blob/master/zh-TW/g0v_slack_rand0m_README.md) 說明去識別、切句並隨機打散 | GitHub 固定 blob `01eeef3ae42fb6697f1a9966c22a8e025c1010cd`；[Git tree metadata](https://api.github.com/repos/moztw/cc0-sentences/git/trees/master?recursive=1) 查得 **217,398 bytes**，約 0.21 MiB。只下載此檔，排除整庫、GPT-4、政府新聞稿、轉載等其他 txt | 日常聊天與財經討論有文體交集，也可能談到新聞／投資；不排除重複或模型已見過。這是清理後的公開句庫，不代表原始聊天室分佈 |

## 語料邊界與重跑

- PTT 的「網頁公開可讀」不能代替可再散布的著作授權；本次不抓 PTT。
- MozTW 此檔已經打散，無法確認上一行是同篇前一句；因此 `context` 一律空字串，不以相鄰行杜撰前文。
- 維基百科按原段落與句序保留同篇前一句；到段落邊界重設前文。`context` 保留原句，模型端自行取最後 64 字。
- 不把數字或英文刪掉後拼接成新句；有無讀音字的標點分句整句丟棄。標點先分句，再把超過 32 字的可反查分句切成連續片段。
- 原始 HTTP 回應、下載清單與校驗碼存 `data/raw/`，完整 dev／held-out 存 `data/generated/`；兩者都被此目錄的 `.gitignore` 排除。Git 可收錄的小樣本最多 200 筆。
- 全部交付物現位於 worktree 的 `DevLab/D512Eval/testset/`；raw 的 revision、blob 與 SHA-256 未重新下載或改寫。分詞現採使用者核准的 `sum(log(max(freq,1)/Z))` DP；選路徑後仍遇多音字單字 fallback 或最高頻並列異讀詞條即丟棄整句，只保留原五個單字助詞例外，切分前以 gold 全域去重。
- 下載後凍結原始內容與 revision／blob；相同 raw、詞庫與 seed 必須產生相同 JSONL。重新抓取維基百科可能改變版本，不宣稱只靠 seed 可重現跨版本語料。

## 查證狀態

已核對指定詞庫 HEAD 為 `a7548f42ccdf523a2cc8ab533b3990561eba7288`。下載同意已取得，原始檔將以來源版本、檔案大小與 SHA-256 凍結於 `download-manifest.json`。查詢單檔大小時，GitHub contents 接口曾在同意前連同語料文字一起回傳；當時未保存到工作目錄、未用作案例，後續查大小改讀 tree metadata；正式 raw 在取得同意後重新下載並校驗。

本 session 的 HTTP 命令曾回報 DNS 無法解析；下載器透過 HTTPS 查 DNS，再指定該次查到的 IP，保留原 hostname 的 TLS 驗證，不修改系統設定。論文 PDF 已取得，摘要以實讀全文與第 9 頁表格核對頁碼；它與測試語料分開保存於 `tmp/`。

兩來源 raw 已下載並凍結。聊天檔案 SHA-256 為 `6bde40bb34ddc97b860876d03de1a04171787854bfb6aefaf596a0d2ded8086f`；整理後 `documents.jsonl` 為 `434bed46e9a819b21691691dfaccfd7fdec54f9454cd62049da7df069d280a99`。每次產生前都核對這些摘要與全部百科原始回應，拒絕悄悄改用新文字。每筆 `source` 的條目標題保留 API 原始識別字（可能含簡化字），`gold` 則取已轉換的 `zh-tw` 正文；不改寫來源識別字。
