<#
.SYNOPSIS
    撤離：把這個專案從這台裝置上安全移除，之後刪資料夾才不會出事。

.DESCRIPTION
    直接在檔案總管刪掉專案資料夾是危險的。`_drive/` 是 junction，而移到資源回收筒
    是跨磁碟區的「複製再刪除」——它會沿著 junction 走進 Google Drive，開始搬移雲端上
    的真實素材。表現出來就是檔案總管長時間無回應（ADR-0001 的穿透風險，只是發生在
    shell 層而不是我們的腳本裡）。

    這支腳本負責把資料夾變成「可以安全刪除」的狀態：拆掉 junction、收掉心跳排程，
    並在動手前檢查有沒有還沒送出去的東西。

    **它不會刪除專案資料夾本身。** 那是使用者的決定，腳本只負責讓那個決定變安全。

.PARAMETER ProjectRoot
    要撤離的專案。預設為目前目錄。

.PARAMETER Confirmed
    確定要撤離。沒帶就只檢查並顯示會做什麼。

.OUTPUTS
    exit 0 = 已撤離，可以安全刪除；1 = 失敗；2 = 停下來了，需要你決定。
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$ListPath,
    [switch]$Confirmed
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $OutputEncoding

. (Join-Path $PSScriptRoot 'lib\paths.ps1')
. (Join-Path $PSScriptRoot 'lib\junction.ps1')
. (Join-Path $PSScriptRoot 'lib\lease.ps1')
. (Join-Path $PSScriptRoot 'lib\git.ps1')
. (Join-Path $PSScriptRoot 'lib\registry.ps1')

try {
    $ProjectRoot = Resolve-ExistingProjectRoot -ProjectRoot $ProjectRoot
    $manifest = Read-ProjectManifest -ProjectRoot $ProjectRoot
    if (Test-Unreadable $manifest) {
        Write-Host "$(Get-ProjectManifestPath -ProjectRoot $ProjectRoot) 存在但無法解析（讀不動），可能還在同步中、暫時讀不到，也可能是內容損毀。"
        Write-Host "確認檔案內容之後再重跑；如果懷疑是同步問題，等 Drive 同步完成再重跑。"
        exit $script:ExitNeedsYou
    }
    if (-not $manifest) {
        Write-Host "這個目錄不是 hybrid workspace 專案，沒有東西要撤離。"
        exit $script:ExitFailed
    }
    $projectId = [string]$manifest.projectId
    $device = $env:COMPUTERNAME
    # 這台裝置的持久識別（票 26）——跟 startup.ps1／shutdown.ps1 同一個道理。
    $deviceIdentity = Get-DeviceIdentity -ListPath $ListPath
    $linkPath = Join-Path $ProjectRoot $script:DriveLinkName

    # --- 先看有沒有還沒送出去的東西 --------------------------------------
    $risks = @()
    if (Test-GitRepo -ProjectRoot $ProjectRoot) {
        $status = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('status', '--porcelain')
        if ($status.Output) {
            $count = @($status.Output -split "`n").Count
            $risks += "工作區有 $count 項未提交的變更"
        }

        $branch = Get-CurrentBranch -ProjectRoot $ProjectRoot
        if ($branch -and (Test-HasRemote -ProjectRoot $ProjectRoot)) {
            Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('fetch', '--quiet', 'origin') | Out-Null
            $unpushed = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('rev-list', '--count', "origin/$branch..$branch")
            if ($unpushed.ExitCode -eq 0 -and [int]$unpushed.Output -gt 0) {
                $risks += "$branch 有 $($unpushed.Output) 筆 commit 還沒推上去"
            }
        }
    }

    # 軸一分類（ADR-0006）：self 才是這個目錄自己的風險；self-other-workdir 是同一台
    # 裝置的另一個目錄持有，不算這個目錄的風險，但值得說一聲；unreadable 分不出租約
    # 現在是不是還在這台手上，本身就是一種風險。
    $lease = Read-Lease -ProjectRoot $ProjectRoot
    $leaseState = Get-LeaseState -Lease $lease -ProjectRoot $ProjectRoot -Manifest $manifest -Identity $deviceIdentity
    $leaseNote = ''
    switch ($leaseState) {
        'self' { $risks += "租約還在這台手上——別台裝置會以為你還在工作" }
        'self-other-workdir' {
            $holderWorkdir = Get-PropertyOrDefault -InputObject $lease -Name 'holderWorkdir' -Default '（未記錄）'
            $leaseNote = "說明：這個專案的租約目前握在這台裝置的另一個工作目錄（$holderWorkdir）手上，不算這個目錄的風險。"
        }
        'unreadable' { $risks += "租約讀不動，無法確認是不是還握在這台手上" }
    }

    Write-Host "撤離：$projectId"
    Write-Host "  專案     ：$ProjectRoot"
    Write-Host "  裝置     ：$device"
    Write-Host ""
    if ($leaseNote) {
        Write-Host $leaseNote
        Write-Host ""
    }

    if ($risks.Count -gt 0) {
        Write-Host "有東西還沒送出去："
        foreach ($r in $risks) { Write-Host "  * $r" }
        Write-Host ""
        Write-Host "先執行收工把它們送走，再回來撤離。"
        Write-Host "確定要放棄這些東西的話，加上 -Confirmed。"
        if (-not $Confirmed) { exit $script:ExitNeedsYou }
        Write-Host "（你帶了 -Confirmed，繼續。）"
        Write-Host ""
    }

    # --- 會做什麼 ---------------------------------------------------------
    $hasJunction = Test-Path -LiteralPath $linkPath
    Write-Host "會做這些："
    if ($hasJunction) {
        Write-Host "  1. 拆掉 $($script:DriveLinkName)/ 的 junction（只拆連結，Drive 上的素材一個位元組都不動）"
    } else {
        Write-Host "  1. $($script:DriveLinkName)/ 不存在，不用拆"
    }
    Write-Host "  2. 從心跳清單移除這個專案（不需要提權）"
    Write-Host ""
    Write-Host "**不會**刪除專案資料夾本身——撤離完成之後由你自己刪。"

    if (-not $Confirmed) {
        Write-Host ""
        Write-Host "還沒動手。確定的話加上 -Confirmed 重跑。"
        exit $script:ExitNeedsYou
    }

    # --- 動手 -------------------------------------------------------------
    Write-Host ""
    if ($hasJunction) {
        if (-not (Test-IsJunction -Path $linkPath)) {
            Write-Host "停下來了：$linkPath 不是 junction，是實體資料夾。"
            Write-Host "那可能是你的資料，撤離不會碰它。請自己確認之後處理。"
            exit $script:ExitNeedsYou
        }
        $target = Get-JunctionTarget -Path $linkPath
        Remove-Junction -Path $linkPath
        Write-Host "junction 已拆除"
        Write-Host "  原本指向：$target"
        # 這一行要回答「我拆掉連結之後，Drive 上那份東西還在嗎」。內插布林值會印出
        # PowerShell 的型別字面值 True／False，混在中文句子裡看起來像程式壞掉——
        # 而這正是使用者最需要確定的一句話（不變量 3：素材不能被工具動到）。
        if (Test-Path -LiteralPath $target) {
            Write-Host "  Drive 上的目標：還在（沒有被動到）"
        } else {
            Write-Host "  Drive 上的目標：不見了——這不是撤離造成的，撤離只拆連結。"
            Write-Host "                  可能是還沒同步下來，也可能真的被刪了。"
        }
    }

    # 從清單移除就好，不必碰排程器——排程項目是機器層級的，其他專案還要用它。
    # 這一步不需要提權，這正是票 11 的重點。
    if (Remove-ProjectFromList -ListPath $ListPath -ProjectRoot $ProjectRoot) {
        Write-Host "已從心跳清單移除"
    } else {
        Write-Host "本來就不在心跳清單裡"
    }

    Write-Host ""
    Write-Host "撤離完成。現在刪除 $ProjectRoot 是安全的——不會穿透到 Drive。"
    exit $script:ExitOk
}
catch {
    Write-Host "撤離失敗：$($_.Exception.Message)"
    exit $script:ExitFailed
}
