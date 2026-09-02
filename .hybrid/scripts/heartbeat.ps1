<#
.SYNOPSIS
    心跳：把未提交的工作區變更送到這台裝置專屬的分支。

.DESCRIPTION
    背景執行。它存在的唯一理由是讓代理收工拿得到這台裝置未提交的進度（ADR-0002）——
    忘記收工就關機時，那些變更不會被困在關掉的機器上。

    它**不會碰使用者的 index、工作區或目前分支**。走的是 git 的 plumbing：用另一份
    暫存 index 產生 tree，再直接 commit-tree 到 wip/<裝置>。使用者這邊沒有任何感覺。

    可以獨立手動執行，不依賴排程器存在（排程註冊是另一張票）。

.PARAMETER ProjectRoot
    專案在本機的位置。預設為目前目錄。

.PARAMETER ListPath
    這台機器的心跳清單／裝置識別所在目錄。省略時是
    `%LOCALAPPDATA%\hybrid-workspace`。測試接縫——跟 startup.ps1 等其他腳本
    共用同一個 `-ListPath` 慣例（不變量 13）。

.OUTPUTS
    exit 0 = 正常結束（不論這次有沒有送出東西，也不論推送是否被 --force-with-lease
    拒絕）；1 = 失敗。
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$ListPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $OutputEncoding

. (Join-Path $PSScriptRoot 'lib\paths.ps1')
. (Join-Path $PSScriptRoot 'lib\git.ps1')
. (Join-Path $PSScriptRoot 'lib\lease.ps1')
. (Join-Path $PSScriptRoot 'lib\preflight.ps1')
. (Join-Path $PSScriptRoot 'lib\version.ps1')

try {
    if (-not (Test-Path -LiteralPath $ProjectRoot)) {
        # 專案資料夾被改名或刪掉了。排程項目還指著舊路徑，會每 15 分鐘失敗一次，
        # 而唯一的痕跡在事件檢視器裡——所以這裡把該說的話一次講完。
        Write-Host "專案資料夾不存在：$ProjectRoot"
        Write-Host ""
        Write-Host "這個心跳排程指向的路徑已經不在了（資料夾被改名、搬走或刪掉）。"
        Write-Host "它會一直失敗下去，直到你處理它："
        Write-Host "  * 資料夾還在別的地方 → 在新位置重跑一次 register-heartbeat.ps1（需提權）"
        Write-Host "  * 這台不再做這個專案 → 用 register-heartbeat.ps1 -Unregister 拿掉排程"
        exit $script:ExitFailed
    }
    $ProjectRoot = Resolve-ExistingProjectRoot -ProjectRoot $ProjectRoot

    # --- 相容判定（ADR-0008「相容矩陣」）------------------------------------
    # 心跳沒有人在看，不相容一律拒跑、不降級猜：印固定標記行、exit 0——不 exit 1、
    # 不 exit 2、沒有 override（不變量 7）。放在最前面，比 git 檢查還早：版本不相容
    # 時，這個專案的其餘檢查（git、preflight）該不該跑都還沒有意義。
    $schemaRange = Get-InstalledSchemaRange -RuntimeDir $PSScriptRoot
    $schemaResult = Get-ProjectSchemaVersion -ProjectRoot $ProjectRoot
    if ((Test-Unreadable $schemaResult) -or ($null -eq $schemaResult)) {
        $reason = if (Test-Unreadable $schemaResult) { 'manifest 讀不動' } else { '找不到 .hybrid/project.json' }
        Write-Host "心跳跳過（$reason，無法判定 schema 相容性）：$ProjectRoot"
        # schema=0 是「無法判定」的哨兵值，不是真的第 0 版——schemaVersion 從 1 起算。
        Write-Host "SKIPPED-BY-VERSION schema=0 supported=$($schemaRange.Min)-$($schemaRange.Max)"
        exit $script:ExitOk
    }
    $schemaCompat = Test-SchemaCompatible -Schema $schemaResult -Min $schemaRange.Min -Max $schemaRange.Max
    if ($schemaCompat -ne 'ok') {
        $advice = if ($schemaCompat -eq 'too-old') {
            '這個專案版本比較舊——請跑 migrate-project-identity.ps1 或去模板 repo 對它跑 initialise.ps1 -Force 升級'
        } else {
            '這台機器的 runtime 落後了——請跑 upgrade-runtime.ps1 升級這台的 runtime'
        }
        Write-Host "心跳跳過（schema 不相容）：這個專案是 schema $schemaResult，這個 runtime 認得 $($schemaRange.Min)–$($schemaRange.Max)。"
        Write-Host "  $advice"
        Write-Host "SKIPPED-BY-VERSION schema=$schemaResult supported=$($schemaRange.Min)-$($schemaRange.Max)"
        exit $script:ExitOk
    }

    if (-not (Test-GitRepo -ProjectRoot $ProjectRoot)) {
        Write-Host "不是 git repo，心跳跳過：$ProjectRoot"
        exit $script:ExitOk
    }

    # 撞上使用者正在做的 git 操作就讓開。下一次心跳還會來。
    if (Test-GitOperationInProgress -ProjectRoot $ProjectRoot) {
        Write-Host "偵測到進行中的 git 操作，這次心跳跳過。"
        exit $script:ExitOk
    }

    # --- preflight（ADR-0005）----------------------------------------------
    # 心跳沒有人在看，阻擋對它不是「停下來問」，是「這一次不做」：exit 0（不是
    # exit 1——那會污染工作排程器的 LastTaskResult，把「正確地拒絕」跟真正的失敗
    # 混進同一個訊號），也沒有 override（背景排程不能自我授權，ADR-0007 不變量 7）。
    # 政策檔讀不動或 schemaVersion 不認得時，Read-PreflightPolicy 會 throw（前景呼叫端
    # 如 shutdown.ps1 維持這個行為——人在旁邊，該炸就炸）。心跳沒有人在看，這裡改成
    # 具名跳過：印 SKIPPED-BY-POLICY、exit 0，不落到下面 :126 的泛用 catch 變成 exit 1
    # ——「政策檔太新」跟「git 炸了」是兩件不同的事，混進同一個訊號兩者都會失去意義
    # （ADR-0008）。
    try {
        $preflightPolicy = Read-PreflightPolicy -ProjectRoot $ProjectRoot
    } catch {
        $reason = ($_.Exception.Message -replace '[\r\n]+', ' ')
        Write-Host "心跳跳過（preflight 政策檔讀不動或版本不認得）：$reason"
        Write-Host "SKIPPED-BY-POLICY reason=$reason"
        exit $script:ExitOk
    }
    $preflightScan = Invoke-PreflightScan -ProjectRoot $ProjectRoot -Policy $preflightPolicy
    if ($preflightScan.Blocked) {
        $blockedFiles = @($preflightScan.BlockingFindings | ForEach-Object { $_.File } | Select-Object -Unique)
        Write-Host "心跳跳過（preflight 阻擋）："
        foreach ($finding in $preflightScan.BlockingFindings) {
            Write-Host "  * [$($finding.Rule)] $($finding.File) — $($finding.Message)"
        }
        Write-Host "心跳沒有 override（背景排程不能自我授權），下次收工時處理。"
        # ADR-0005 Consequences：除了機器層級 state.json，還要在專案裡留下使用者看得到
        # 的痕跡——藏起來比沒有這個檢查更糟。
        Add-PreflightSkipTrace -ProjectRoot $ProjectRoot -BlockingFindings $preflightScan.BlockingFindings | Out-Null
        # 派工器（run-heartbeats.ps1）靠這一行的固定格式，把這次跳過算進
        # consecutiveFailures，而不是被 exit 0 誤判成正常完成。
        Write-Host "SKIPPED-BY-PREFLIGHT files=$($blockedFiles -join '|')"
        exit $script:ExitOk
    }
    foreach ($warning in $preflightScan.Warnings) { Write-Host "警告：$warning" }

    $device = $env:COMPUTERNAME
    $deviceIdentity = Get-DeviceIdentity -ListPath $ListPath
    $branch = Get-HeartbeatBranchName -DeviceId $deviceIdentity.DeviceId -ProjectRoot $ProjectRoot
    $ref = "refs/heads/$branch"

    # 心跳分支已經存在就接在它後面；還沒有就從主線目前的位置分出去。
    $parent = Get-RefCommit -ProjectRoot $ProjectRoot -Ref $ref
    if (-not $parent) {
        $parent = Get-RefCommit -ProjectRoot $ProjectRoot -Ref 'HEAD'
    }

    # 暫存 index 從**主線**種起，不從心跳分支種起。
    #
    # 這個差別不明顯但很要緊：gitignore 只管未追蹤的檔案，管不到已經在 index 裡的。
    # 從心跳分支種的話，某個檔案一旦被某次心跳收進去，之後就算補進 .gitignore 也會
    # 被一路帶著走——然後代理收工 merge 心跳分支時，那些垃圾就跟著進主線了。
    # 從主線種起，每次心跳的 tree 就等於「乾淨簽出主線 + 目前的本機改動」。
    $seed = Get-RefCommit -ProjectRoot $ProjectRoot -Ref 'HEAD'
    $tree = New-WorkTreeSnapshot -ProjectRoot $ProjectRoot -SeedRef $seed

    # 沒有變更就什麼都不做——空的心跳紀錄只會讓歷史更難讀。
    if ($parent) {
        $parentTree = Get-TreeOfCommit -ProjectRoot $ProjectRoot -Commit $parent
        if ($parentTree -eq $tree) {
            Write-Host "工作區沒有變更，心跳不動作。"
            exit $script:ExitOk
        }
    }

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    $commit = New-CommitFromTree -ProjectRoot $ProjectRoot -Tree $tree -Parent $parent `
        -Message "chore(心跳): $device $stamp"
    Update-GitRef -ProjectRoot $ProjectRoot -Ref $ref -Commit $commit

    $pushed = '沒有 remote，只留在本機'
    if (Test-HasRemote -ProjectRoot $ProjectRoot) {
        # --force-with-lease，不是裸 --force：這條分支只有這台裝置這個工作目錄會寫
        # 的假設多數時候成立，但裸 --force 完全不檢查遠端現在是什麼——假設不成立的
        # 那一次（有人手動動過這條分支、或極罕見的雙重執行）會靜靜覆蓋掉，代理收工
        # 事後拿到的是一份看起來完整、其實漏了一截的心跳（票 26）。
        #
        # 比對基準是**上一次成功推送之後 git 自動更新的本機 remote-tracking ref**，
        # 不是推送前現查的「現在」——推送前才 fetch 的話，比對基準會被自己重新整理
        # 成跟遠端一致，保護的區間縮小成「這次執行的幾百毫秒」，真正該擋的「上一次
        # 心跳到現在這 15 分鐘內被別人動過」反而測不到。所以這裡完全不在推送前
        # fetch；本機沒有這個 remote-tracking ref（第一次推這條分支）時，
        # --force-with-lease 的隱含比對基準是「必須不存在」，跟事實一致。
        $push = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('push', '--force-with-lease', 'origin', "${branch}:${branch}")
        if ($push.ExitCode -eq 0) {
            $pushed = '已推送'
        } else {
            # 心跳沒有人在看：推送被拒絕不是 exit 1 的失敗，是「這一次沒送出去，
            # 下次再來」——跟 preflight／版本不相容的既有判準一樣（ADR-0005、
            # ADR-0008）：背景這條路上的阻擋只能降級成跳過，不能停下來問人，也
            # 不能假裝失敗把訊號混進真正的 git 錯誤。派工器靠固定格式的標記行把
            # 這次算成非成功，不會被 exit 0 誤判成正常完成。
            #
            # 拒絕之後才 fetch，把本機對這條分支的認知同步到現在——這一步刻意排在
            # 拒絕**之後**：拒絕本身要用「上一次成功推送以來」這個舊基準才有意義
            # （見上）；同步是為了讓下一輪心跳有正確的基準可以比，不然本機的認知
            # 永遠停在被拒絕的那一刻，下一輪還是會被拒，變成卡死。
            Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('fetch', '--quiet', 'origin', $branch) | Out-Null
            $pushed = "推送被拒絕（--force-with-lease）：$($push.Output)"
            Write-Host "心跳推送被拒絕（--force-with-lease）：遠端這條分支已經不是我們認得的那個版本，這一次不覆蓋，下次心跳再試。"
            Write-Host "REJECTED-BY-LEASE branch=$branch"
        }
    }

    Write-Host "心跳：$branch $($commit.Substring(0, 7))（$pushed）"
    exit $script:ExitOk
}
catch {
    Write-Host "心跳失敗：$($_.Exception.Message)"
    exit $script:ExitFailed
}
