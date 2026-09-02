---
name: hybrid-workspace
description: 三台裝置輪流工作的專案，四道指令：初始化、開工、收工、代理收工。當使用者說要開工、收工、換機器、換電腦、初始化新專案，或問「上次做到哪」「可以換裝置了嗎」「那台是不是還握著租約」時載入。
---

# hybrid workspace

專案本體在本機 NTFS 以 git 版控；`_drive/` 是掛到 Google Drive 的 junction，放外部素材與
衍生品。**租約**標記哪台裝置手上有未完成的工作，但它從不阻擋任何裝置開工。

## 分工線

**這件事有沒有標準答案。**

建 junction、解析路徑、跑 git、壓縮心跳分支——有標準答案，一律由腳本執行。你負責呼叫它們、
讀懂輸出、把需要判斷的部分帶給使用者。

要不要代理收工、`_drive/` 變成一般資料夾了怎麼辦、推不上去要不要繼續——沒有標準答案，你帶
使用者判斷，但不要替他決定。

**絕對不要自己重做腳本做過的事。** 不要用 `mklink` 建 junction、不要手寫租約檔、不要自己
`git merge` 心跳分支。腳本有測試守著那些行為，你手動做的沒有，兩邊會漂移。

腳本在沒有 Claude Code 的情況下也能單獨執行。你不是必要條件，是方便。

## 找到腳本

**專案自帶腳本。** 初始化時腳本就被複製進 `.hybrid/scripts/` 並進版控，所以 clone 到任何一台
裝置都能直接跑，不必先裝什麼、也不必知道模板 repo 在哪。

依序試，找到就用：

1. `.hybrid/scripts/`（正常情況都是這個）
2. 專案根目錄下的 `scripts/`（在模板 repo 本身裡工作時）
3. `.hybrid/local.json` 裡的 `scriptsRoot`

代價是模板之後的變更不會自動跟上專案。那是已知的取捨，不是壞掉。使用者要更新某個專案的
腳本時，去**模板 repo** 對該專案跑 `scripts\initialise.ps1 -Force -ProjectRoot <該專案路徑>`
——專案 ID 與初始化日期會沿用。**不是**對專案自己的 `.hybrid\scripts\initialise.ps1 -Force`：
來源與目標是同一份，那個指令會 `Copy-TemplateBundle` 判定為 `skipped`，什麼都不會被更新。

## 換到一台還沒有這個專案的裝置

不要打包搬過去——`_drive/` 是 junction，複製會壞。用開工包：把 `dist\開工包` 複製到那台
電腦，**改名成想同步的專案名稱**，雙擊「開工.cmd」。

開工偵測到本機還不是專案時，會用資料夾名去 Drive 的 `_hybrid\` 底下比對（完全相同優先，
其次是唯一的前綴符合），讀該專案的 `origin.json` 拿到 repo 位址，取下來之後接著走正常流程。

**比對不唯一或找不到時它會停下來列出候選。** 這時你的工作是幫使用者確認要哪一個，然後請他
改資料夾名字再跑一次——**不要自己去猜、也不要改成用初始化**。初始化是開新專案用的，會產生
新的專案 ID，跟既有的那個完全斷開。

那台機器第一次還需要：`gh auth login`（私有 repo 認證）、提權註冊心跳、手動離線釘選。
三件都是每台機器一次。

## 四道指令

一律用 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <腳本> -ProjectRoot <專案路徑>`。
`-DriveRoot` 通常不用給——自動偵測掛載點，偵測失敗過的裝置會記在本機設定檔裡。

| 使用者說 | 腳本 | 常用參數 |
| --- | --- | --- |
| 開一個新專案、套用模板 | `initialise.ps1` | `-Force` 重新產生骨架 |
| 開工、換到這台了、繼續做 | `startup.ps1` | `-ReadOnly` 只看不取得租約 |
| 收工、要換機器了、今天到這 | `shutdown.ps1` | `-DriveSynced` 已確認 Drive 同步 |
| 那台忘記收工、替它收 | `proxy-shutdown.ps1` | `-Confirmed` 確定要動手 |
| 這台不做這專案了、要刪資料夾 | `leave-device.ps1` | `-Confirmed` 確定要動手 |
| 這台機器第一次設定心跳 | `install-heartbeat.ps1` | **需要提權，一台機器一次** |
| 把某個專案納入心跳 | `register-heartbeat.ps1` | `-Unregister` 移除，**不需提權** |
| 舊專案要補上不可變身分（projectUuid） | `migrate-project-identity.ps1` | `-Confirmed` 確定要動手；沒帶就只顯示計畫 |
| 升級這台機器實際執行的心跳 | `upgrade-runtime.ps1` | `-Rollback` 回到上一版；`-RefreshBundle -ProjectRoot <路徑>` 用它刷新某個專案自帶的腳本 |
| 看這台機器與所有專案的版本／相容狀態 | `runtime-status.ps1` | 唯讀，不需要任何參數 |

只是要看看或規劃、沒打算真的動手改東西時，開工用 `-ReadOnly`——它不會留下之後需要清理的
租約。

## 讀 exit code

- **0** — 完成。把摘要轉述給使用者，不必加工。
- **1** — 失敗。輸出裡有原因，照著看。
- **2** — **腳本停下來了，因為接下來那一步該由人決定。** 這不是錯誤，是設計。

exit 2 是你的主場。腳本已經把選項印出來了，你的工作是把它變成一個使用者能回答的問題，
拿到答案之後**用對應的參數重跑同一支腳本**——不是自己動手做那件事。

## exit 2 的每一種情況

**重複初始化**（`initialise.ps1`）
目標已經是初始化過的專案。問清楚是不是真的要重新產生骨架，是就加 `-Force` 重跑。專案 ID 與
初始化日期會沿用，不會變。

**`_drive/` 是一般資料夾或檔案**（`startup.ps1`）
那可能是使用者的資料，腳本不刪。兩個選項：內容還要就搬走（或搬進 Drive 端那個資料夾），
不要就自己刪掉再重跑開工。**不要替他刪。**

**別台裝置持有租約**（`startup.ps1`，這個是 exit 0）
環境已經就緒了，開工沒有被擋。但要把腳本印出來的東西帶給使用者判斷：

- 對方的心跳分支存在 → 告訴他有幾筆、最後一筆是什麼時候，問要不要現在代理收工。要的話跑
  `proxy-shutdown.ps1`（先不帶 `-Confirmed`，讓他看過內容再決定）。
- 心跳分支不存在 → 明講代理收工**只能釋放租約，拿不回那台機器上沒提交的變更**。這時候
  「等它自己開機收工」通常才是對的選擇。不要把代理收工講得像是沒有代價。

**Drive 同步還沒確認**（`shutdown.ps1`）
git 那邊已經收好了，卡的是 Drive。Drive 的完成時點無法由程式觀測，這是設計不是缺陷。
請使用者去看 Google Drive 的同步狀態，確認完成後加 `-DriveSynced` 重跑（那時已經沒有東西
要提交，很快）。**不要自己判斷同步好了沒。**

**推送失敗**（`shutdown.ps1` / `proxy-shutdown.ps1`）
輸出裡有 git 的原因。常見是網路不通或需要重新登入。處理完重跑。在推上去之前，結論就是
「尚不可換裝置」——別台裝置拿不到東西。

**代理收工還沒確認**（`proxy-shutdown.ps1`）
腳本印出了對方留下什麼。把它整理給使用者看，問要不要動手。要的話加 `-Confirmed` 重跑。

**自己的工作區不乾淨**（`proxy-shutdown.ps1`）
代理收工要 merge，髒的工作區併不安全。請使用者先提交自己的東西或先收工。

**併入時衝突**（`proxy-shutdown.ps1`）
腳本不替使用者解衝突。解完之後他自己 commit，再跑一次代理收工把租約釋放掉。

**身分矛盾**（`startup.ps1` / `shutdown.ps1` / `proxy-shutdown.ps1` / `migrate-project-identity.ps1` /
`initialise.ps1 -Force`）
本機與 Drive 端的 `projectUuid` 不一致。UUID 是隨機的，任一端都無法重算出另一端——這只能
人工裁決，腳本不猜、兩端都不動。把兩顆 UUID 念給使用者聽，請他確認哪一端才對，處理完再
重跑（有可能是兩台裝置幾乎同時各自遷移了一次）。

**Drive 端 `origin.json` 存在但解析失敗**（同上五種情況）
可能還在同步中、暫時讀不到，也可能是內容損毀——不能當成「這個專案沒有身分」，那正是需要
保留的證據。等 Google Drive 同步完成，或確認檔案內容之後再重跑。

**Drive 端 `origin.json` 不存在**（`startup.ps1` / `shutdown.ps1` / `proxy-shutdown.ps1`，且本機
已有 `projectUuid`）
這個檔案不存在，不代表「這個專案沒有身分」——真正的半遷移一定會有這個檔案（只是
`projectUuid` 欄位是空字串，見下一節）。檔案整個不存在，代表 Drive 端這個專案的資料夾還沒
同步下來，或被刪掉了；不管重跑幾次都一樣會停下來，不會因為目錄後來被重建就放行。請使用者
確認 Google Drive 同步狀態，或確認 Drive 端那個專案資料夾還在。

**Drive 掛載點解析不出來**（`startup.ps1` / `initialise.ps1` / `migrate-project-identity.ps1`）
自動偵測失敗，本機也沒有記住的設定檔。Google Drive 可能還沒登入或還沒啟動——這不是程式
錯誤，重跑不會自己好。請使用者確認 Google Drive 狀態，或以 `-DriveRoot` 明確指定掛載點。

**Drive 端路徑不存在**（`startup.ps1` / `initialise.ps1` / `migrate-project-identity.ps1`）
掛載點解析出來了，但那個路徑目前不存在——通常是 Google Drive 還沒把它同步下來，不是程式
出錯。等同步完成，或確認 `-DriveRoot` 指的路徑對不對，再重跑。

## 半遷移狀態（exit 0，不阻擋，但要說出來）

`startup.ps1` / `shutdown.ps1` / `proxy-shutdown.ps1` 遇到「本機有 `projectUuid`、Drive 端
`origin.json` 存在但 `projectUuid` 是空字串（或反過來）」時不會擋——這不是矛盾，是遷移還沒
做完，日常指令不會替使用者補（ADR-0003：寫入側不搭便車）。腳本會在輸出裡點名，把「要完成
遷移，請執行 `migrate-project-identity.ps1`」轉述給使用者；先不帶 `-Confirmed` 讓他看過計畫
再決定。

**這裡的關鍵是 `origin.json` 這個檔案本身要存在。** 半遷移跟上一節「`origin.json` 不存在」
是兩種不同的情況：檔案不存在一律 exit 2（不知道是還沒同步還是真的沒有），檔案存在但欄位是
空字串才是半遷移、exit 0 放行。

## 回報的原則

收工結束一定要把結論講清楚：**「可以換裝置」或「尚不可換裝置」**。後者要說卡在哪——腳本
已經列出來了，照著轉述，不要模糊成「大致上好了」。

開工結束把摘要帶到：租約狀態、上次做到哪、接下來 1–3 項。接下來那幾項讀的是
`.hybrid/next.md`；沒有那個檔案時，收工前提醒使用者留幾行給下一次的自己——決定要寫什麼是
判斷，那是你的事，不是腳本的。

## 要改進這套系統的話

**改模板 repo，不要改專案裡的那一份。** `.hybrid/scripts/` 是初始化時複製進來的副本；
在那裡修好的東西不會回到模板，下一個專案還是壞的，而且這個專案下次 `-Force` 時會被蓋掉。

正確順序是：在模板 repo 改 → 跑測試 → commit → 在模板 repo 對需要的專案跑
`scripts\initialise.ps1 -Force -ProjectRoot <該專案路徑>` 把新版腳本推進去。

模板 repo 裡先看 `docs/踩過的坑.md`——PowerShell 5.1、git、junction、Google Drive 各自
有一堆「看起來成功了，其實沒有」的地雷，那份文件是實測記錄，不是推測。

## 心跳是機器層級的，不是專案層級的

一台機器只有**一個**排程項目，它依一份清單處理所有專案。所以：

- **`install-heartbeat.ps1` 要提權，但一台機器只做一次。** 使用者抱怨「每個專案都要提權」
  時，答案是這個，不是叫他再提權一次。
- **`register-heartbeat.ps1` 只是把專案加進清單，不需要提權。** 而且開工會自動做，
  正常情況下使用者根本不必手動跑它。
- 清單裡某個專案的資料夾不見了，派工器**跳過它繼續處理其他專案**——一個專案壞掉不會
  讓整台機器的心跳失效。

排查時看 `%LOCALAPPDATA%\hybrid-workspace\`：`projects.json` 是清單，`last-run.log` 是
上一次跑的結果。判斷排程有沒有跑一律看 `LastRunTime`，不要看 `NumberOfMissedRuns`。

**派工器執行的是機器層級安裝的 runtime（`%LOCALAPPDATA%\hybrid-workspace\runtime\<版本>\`），
不是專案自帶的 `.hybrid\scripts\heartbeat.ps1`。** 改專案裡那份心跳腳本不會改變心跳行為
——那份現在只是前景指令（開工／收工）用的副本，以及還沒升級到新派工器的機器上的保護傘。
要更新這台機器實際執行的心跳，用 `upgrade-runtime.ps1`；要單獨刷新某個專案自帶的那份
（例如它版本太舊擋住了遷移），用 `upgrade-runtime.ps1 -RefreshBundle -ProjectRoot <該專案路徑>`。
想知道這台機器目前的 runtime 版本、每個專案的相容狀態，跑 `runtime-status.ps1`。

## 要刪掉某台裝置上的專案資料夾

**先跑 `leave-device.ps1`，不要直接刪。** `_drive/` 是 junction，檔案總管把資料夾移到
資源回收筒是跨磁碟區的「複製再刪除」，會沿著它走進 Google Drive 開始搬雲端上的素材——
表現出來就是檔案總管卡死。撤離會拆掉 junction、收掉心跳排程，並在動手前檢查有沒有還沒
送出去的東西。它**不會**刪資料夾，撤離完成後由使用者自己刪。

## 一件不能忘的事

`_drive/` 底下是 Google Drive 上的真實資料，只有一份。git 會直接穿透 junction。任何時候都
不要對 `_drive/` 用遞迴刪除，也不要把它加進版控。腳本裡有兩道檢查守著這條，你手動操作時
沒有。
