# 候選排序功能版建置與安裝指南

本指南適用於包含「依近期有效選字直接組字，候選最近者置首、其餘按累計次數排序」功能的程式碼版本，說明如何在 macOS 建置本機架構的 Release、備份原版、安裝並在 Obsidian 驗收。

**安裝會替換原有唯音。** 修改版沿用 `org.atelierInmu.inputmethod.vChewing` 與相同的輸入法 connection name，無法當作另一套唯音並存。請先完成備份。

## 1. 確認程式碼版本與工具鏈

將下列 `/path/to/vChewing-macOS` 換成自己的 clone 位置；將 `VCH_DEVELOPER_DIR` 換成要使用的 Xcode developer 目錄。範例使用標準的 Xcode 安裝位置，beta 或其他名稱需自行替換。

```sh
cd /path/to/vChewing-macOS
git status --short --branch
git rev-parse HEAD
VCH_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
env DEVELOPER_DIR="$VCH_DEVELOPER_DIR" xcrun swift --version
env DEVELOPER_DIR="$VCH_DEVELOPER_DIR" xcrun xcodebuild -version
```

確認所選版本包含候選排序功能，並記錄分支、HEAD、Swift 與 Xcode 版本；若有不明的程式碼修改，先核對再繼續。後續命令都在 repo 根目錄、同一個終端機 session 執行，以保留變數。

**Swift 6.4 以上為必要條件。** 版本不足時停止，選用符合需求的工具鏈後重新確認；不要降低 manifest 要求。`DEVELOPER_DIR` 只影響該命令，不需改全域 `xcode-select`。其他工具鏈組合及系統需求見 [README 系統需求](README.md#系統需求)。

## 2. 建置可安裝的 Release app

完整 stdout／stderr 存入獨立 log，保留命令的結束狀態：

```sh
VCH_BUILD_LOG="$(mktemp -t vchewing-build)"
env DEVELOPER_DIR="$VCH_DEVELOPER_DIR" xcrun swift package \
  --allow-writing-to-package-directory bundle-apps \
  > "$VCH_BUILD_LOG" 2>&1
VCH_BUILD_EXIT=$?
printf 'exit=%s\nlog=%s\n' "$VCH_BUILD_EXIT" "$VCH_BUILD_LOG"
```

只有 `exit=0` 才繼續。失敗時保留 log，可用 `tail -n 80 "$VCH_BUILD_LOG"` 查看末段並釐清錯誤，不要改產品程式碼來繞過建置失敗。需要長期留存時，將 log 另存到自己的紀錄目錄。

此命令直接呼叫既有 `BundleApps` plugin；省略 `--debug` 與 `--build-dir` 時，會建置**本機架構的 Release，非 universal**，輸出：

- `Build/Products/Release/vChewing.app`
- `Build/Products/Release/vChewingInstaller.app`
- 安裝程式內嵌的 IME：`Build/Products/Release/vChewingInstaller.app/Contents/Resources/vChewing.app`

plugin 會重建輸出目錄中的上述兩個 app、打包資源與動態函式庫並做 ad-hoc 簽章，**不會安裝**。此路徑未做發行用簽章或公證。

本指南沿用 checkout 的依賴版本，不需執行 `make update`。配置助手與 `tsc` 為選用項目，未備妥時由既有 plugin 跳過，不影響輸入法本體的建置。

## 3. 核對版本、架構與簽章

以 `Release-Version.plist` 為版本來源，以下三組版本值應相同；架構依 `lipo` 的實際輸出判斷：

```sh
for VCH_INFO_PLIST in Release-Version.plist \
  Build/Products/Release/vChewing.app/Contents/Info.plist \
  Build/Products/Release/vChewingInstaller.app/Contents/Info.plist; do
  printf '%s\n' "$VCH_INFO_PLIST"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$VCH_INFO_PLIST"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$VCH_INFO_PLIST"
done
lipo -archs Build/Products/Release/vChewing.app/Contents/MacOS/vChewing
lipo -archs Build/Products/Release/vChewingInstaller.app/Contents/MacOS/vChewingInstaller
codesign --verify --deep --strict --verbose=2 Build/Products/Release/vChewing.app
codesign --verify --deep --strict --verbose=2 Build/Products/Release/vChewingInstaller.app
codesign --verify --deep --strict --verbose=2 Build/Products/Release/vChewingInstaller.app/Contents/Resources/vChewing.app
shasum -a 256 \
  Build/Products/Release/vChewing.app/Contents/MacOS/vChewing \
  Build/Products/Release/vChewingInstaller.app/Contents/Resources/vChewing.app/Contents/MacOS/vChewing
```

三份 app 的簽章驗證都應成功；建置 IME 與內嵌 IME 的執行檔 hash 應相同。任何一項不符，先停止安裝並保留診斷。

已知編譯診斷包括 `CandidateRankingStore` 的 `ActorIsolatedCall` 警告；此指南不宣稱該警告已消失。建置與簽章成功只確認產物，完成第 6 節的實機驗收後，才算驗證自己的環境。

## 4. 安裝前備份原版、設定與資料

先結束組字、儲存正在編輯的文字，切換到 **ABC**，關閉唯音偏好設定及語彙編輯器。用 Finder 建立新的 `vChewing-backup-日期時間` 資料夾，保留供回復使用，不要只依賴資源回收筒。

用 Finder 的「前往資料夾」（Shift+Command+G）核對下列位置。**存在才複製；首次安裝可略過不存在的項目。**

1. 前往 `~/Library/Input Methods`，將舊 `vChewing.app` 複製到備份資料夾。也核對 `/Library/Input Methods` 是否有同 connection name 的版本；若有，另行備份並記錄原安裝位置，避免混淆。
2. 前往 `~/Library/Preferences`，若有 `org.atelierInmu.inputmethod.vChewing.plist`，複製並在備份內命名為 `preferences-global.plist`。
3. 前往下列容器內的 `Preferences`；若有同名 plist，另存為 `preferences-container.plist`。
4. 前往下列容器內的 `Application Support`，複製 `vChewing` 資料夾；另複製同層所有 `vChewing_override-model-data-*.dat*` 與 `vChewing_candidate-ranking-*.json` 檔案。這包含繁簡資料及 POM journal。
5. 若偏好設定指定了自訂詞庫資料夾，另外複製該資料夾。記下第 6 節兩個排序選項的原始勾選狀態，方便回復。

容器內的預設位置為：

```text
~/Library/Containers/org.atelierInmu.inputmethod.vChewing/Data/Library/Preferences
~/Library/Containers/org.atelierInmu.inputmethod.vChewing/Data/Library/Application Support
```

此 plugin 產物啟用 sandbox。預設使用者詞庫位於上方 `Application Support/vChewing/`；POM 與排序 JSON 在它的父目錄。請核對實際位置，不要直接假設資料位於一般的 `~/Library/Application Support/vChewing/`。自訂詞庫目錄不會改變 POM 或排序檔的預設位置。

程式透過 `UserDefaults.standard` 存取偏好設定；一般與容器內的 plist 都需核對。`defaults export org.atelierInmu.inputmethod.vChewing` 不能當成完整的 sandbox 設定與資料備份。

排序資料與 POM 分開，繁簡檔案名稱為：

```text
vChewing_candidate-ranking-cht.json
vChewing_candidate-ranking-chs.json
```

**直接開啟排序檔所在目錄：**

```sh
open "$HOME/Library/Containers/org.atelierInmu.inputmethod.vChewing/Data/Library/Application Support"
```

JSON 位於此 `Application Support` 目錄的**直接下層**，不在它的 `vChewing` 子資料夾。各模式只有在有效選字遞交後才建立自己的檔案；首次只用繁體，不必同時看到簡體的 CHS 檔。不必手動建立檔案，也不要編輯或刪除詞庫、POM 或排序資料。

確認備份已包含所需 app 與資料，並記錄舊 app 的版本。下列命令只在舊 app 存在時執行；若它安裝於系統目錄，改成該 app 的實際位置：

```sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HOME/Library/Input Methods/vChewing.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$HOME/Library/Input Methods/vChewing.app/Contents/Info.plist"
```

在備份的 app 上核對相同兩個欄位，應與舊 app 的紀錄一致。首次安裝沒有原版時，無須記錄舊版或執行原版回復步驟。

## 5. 手動安裝，再確認已換成建置版

保持 ABC、確認備份已完成，再從 repo 根目錄開啟 GUI 安裝程式：

```sh
open Build/Products/Release/vChewingInstaller.app
```

閱讀提示並按安裝按鈕。安裝程式會終止原輸入法及附屬編輯器、移走相同 connection name 的舊 bundle，將內嵌 IME 安裝到 `~/Library/Input Methods/vChewing.app`，並處理輸入源註冊、啟用及文字輸入選單重新載入。若系統目錄有同 connection name 的輸入法，會要求管理員授權改名。

使用第 4 節命令查看已安裝版本，應與第 3 節的 `Release-Version.plist` 相同；再比較執行檔與排序功能所在的引擎函式庫：

```sh
shasum -a 256 \
  Build/Products/Release/vChewing.app/Contents/MacOS/vChewing \
  "$HOME/Library/Input Methods/vChewing.app/Contents/MacOS/vChewing"
shasum -a 256 \
  Build/Products/Release/vChewing.app/Contents/Frameworks/libVanguard.dylib \
  "$HOME/Library/Input Methods/vChewing.app/Contents/Frameworks/libVanguard.dylib"
```

每組兩個 hash 應相同。這確認磁碟檔案一致；接著才切回唯音測試。若安裝程式報錯、hash 不同或版本不符，停止驗收並保留訊息。若檔案正確但仍見舊行為或無法選用輸入法，先儲存工作、登出再登入；不要用 `sudo cp`、廣泛刪檔或強制終止程序替代安裝程式。

## 6. 啟用排序，在 Obsidian 驗收

開啟唯音偏好設定的選字設定頁，確認**「使用個人選字偏好」**已開啟（預設 ON）。這個總開關同時控制長期學習、候選排序與預設組字；OFF 保留歷史、不更改 POM 設定，ON 可恢復偏好。使用一般整句模式，想讓選字窗也依偏好排列時，關閉：

- **「以固定順序來陳列選字窗內的候選字」**：開啟時會保留固定順序。
- **「對所有單漢字候選字強制施加倚天中文DOS系統排序」**：想讓單字也依歷史重排時須關閉；保留此項仍可重排一般多字詞。

上述固定順序與倚天排序只限制窗內排序，不會禁止偏好組字。關閉總開關會停止本功能學習並撤回自動偏好；未遞交讀音與當次手選仍保留，不會自動送出文字。已開候選窗維持原 snapshot 與數字對應，關窗後更新。

只有真正手動選取、最後成功遞交的字詞才學習；選字窗與組字區 Tab／Shift+Tab 都適用。自動套用偏好不會累加次數，既有 POM 開關也不是此功能的總開關。

同一完整讀音群組內，候選最近有效選取置首，其餘按次數由高到低；同次數與零歷史保留原始順序，不同讀音／詞長槽位互不移動。預設組字也採近期偏好，當次手選優先；相交已學詞選較長完整讀音，單字偏好不拆已有長詞。不存在的候選不會被加回；SCPC、字根及特殊 Furious 模式不在範圍。

在 Obsidian 建立測試筆記，用同一繁體或簡體模式完成以下操作：

1. 輸入同音字詞並開選字窗，例如 `ㄕˋ ㄕˋ` 的「試試／逝世／世事」。候選不同時，選現有的同音多字詞即可，不要為測試修改詞庫。先記錄順序。
2. 手動選其中一詞，按 Enter 確認文字已進筆記；重打同讀音，未開窗的組字及 Enter 應直接採該詞。再開窗確認群組最前者；改選另一詞並遞交後，組字與最前者應更新。
3. 在三個候選皆存在時，讓其中一詞的有效遞交次數較多，最後選另一詞遞交；重開窗應見最近者第一，其餘按累計次數排列。
4. 手動選字後取消整段組字，再重打開窗；取消的選擇不應增加次數或改變最近者。只移動反白預覽也不應學習。
5. 在組字區分別用 Tab、Shift+Tab 輪替，確認文字再按 Enter；重開窗應反映最後實際遞交的選擇。反覆輪替只學最後有效者，輪替後取消不學。
6. 手動選字後刪除該字詞，再按 Enter 遞交剩餘文字；被刪的選擇不應學習。改選成另一詞時，遞交後只應學最後者。
7. OFF 應恢復原有組字與候選排序，ON 應恢復已存偏好；都不得清空組字或自行遞交。儲存筆記、登出再登入後，歷史與總開關設定應保留；繁簡模式各用自己的歷史。

若結果不符，記錄版本、輸入模式、操作與候選順序，保留資料供核對；不要以清空歷史作為第一個處理步驟。安裝程式能開啟或簽章通過，都不能代替上述實機驗收。

## 7. 回復備份的原版

先結束組字、儲存文字並切到 ABC。優先使用已保留的原版官方安裝程式重新安裝；若沒有，使用 app 備份：

1. 在 Finder 前往 `~/Library/Input Methods`，將修改版 `vChewing.app` 移到另一個保存資料夾。
2. 將備份的原版 `vChewing.app` 複製回 `~/Library/Input Methods`，不要把備份資料夾本身放進去。
3. 儲存工作、登出再登入，再選用唯音。核對版本與安裝前的備份紀錄一致，並在 Obsidian 確認可輸入；需要時還原兩個排序選項的原始勾選狀態。

若原版來自系統層安裝，優先由該原版的官方安裝程式處理；不要直接覆寫 `/Library/Input Methods`。若 Finder 無法換檔或原版仍無法載入，停止並保留錯誤，不要強制刪除。只有完成版本與實際輸入檢查，才算在自己的環境回復成功。

回復 app 時保留現有詞庫、POM 與排序 JSON；偏好設定及資料備份也繼續保存。不要整包覆寫資料，以免蓋掉安裝後新增的詞彙或設定。

## 命令與路徑來源

- [Makefile](Makefile)：通用建置入口；`install-debug`／`install-release` 開啟既有安裝程式。
- [BundleApps plugin](Plugins/BundleApps/plugin.swift)：本機架構 Release 建置、app 組裝、內嵌 IME 與簽章。
- [InstallerVMProtocol](Packages/vChewing_InstallerAssembly4Darwin/Sources/InstallerAssembly4Darwin/InstallerVMProtocol.swift)、[InstallerShared](Packages/vChewing_InstallerAssembly4Darwin/Sources/InstallerAssembly4Darwin/InstallerShared.swift)：替換、註冊流程與使用者安裝位置。
- [LXMgr_Utilities](Packages/vChewing_MainAssembly4Darwin/Sources/MainAssembly4Darwin/LXManager/LXMgr_Utilities.swift)、[UserDefaults helper](Packages/vChewing_OSNeutral_LibVanguard/Deps/VanguardSwiftExtension/Sources/SwiftExtension/SwiftFoundationImpl.swift)：資料路徑與偏好設定存取。
- [繁體中文設定字串](Sources/vChewingIME_macOS/Resources/zh-Hant.lproj/Localizable.strings)：兩個排序選項的顯示文字。
