<#
.SYNOPSIS
    升級、回滾，或刷新專案自帶腳本——中央 runtime 的前景管理工具。**不提權。**

.DESCRIPTION
    docs/adr/0008-scheduler-runs-installed-runtime-not-repo-scripts.md 的實作。

    升級是「新目錄 + 換指標」，不是就地覆寫：複製到 runtime\<版本>.staging\ →
    自我驗證（對一個暫存的空 git repo 跑一次剛複製好的 heartbeat.ps1，斷言 exit 0）
    → Move-Item 到 runtime\<版本>\ → 原子換 current.json。任一步中斷，舊版仍是
    current，心跳照跑。

    **完全不碰工作排程器。**排程項目的動作字串永遠指向固定路徑（run-heartbeats.vbs），
    不含版本號——這正是升級不需要第二次提權的原因（票 11）。

.PARAMETER SourceRoot
    升級的來源：一個目錄，底下要嘛是 scripts\heartbeat.ps1，要嘛直接是
    heartbeat.ps1（模板 repo 根目錄，或開工包的 _bootstrap\，都可以）。
    預設是這支腳本自己所在位置的上一層。

.PARAMETER ListPath
    機器層級的家目錄。預設 `%LOCALAPPDATA%\hybrid-workspace`。測試接縫。

.PARAMETER Rollback
    把 current.json 指回 previous。不需要任何來源——舊版目錄還在，不重新複製。

.PARAMETER RefreshBundle
    用這台機器目前的 runtime 當來源，刷新 -ProjectRoot 指定的專案自帶的
    `.hybrid\scripts\lib\`（含 heartbeat.ps1、preflight-policy.default.json）。
    不需要模板 repo，不需要提權。只覆寫這幾項，不動專案自帶的其餘腳本
    （startup.ps1、shutdown.ps1 等不屬於 runtime 的部分）。

.PARAMETER ProjectRoot
    -RefreshBundle 要刷新的專案。

.PARAMETER DryRun
    只印出會做什麼，不寫入任何東西。

.OUTPUTS
    exit 0 = 完成；1 = 失敗。
#>
[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$ListPath,
    [switch]$Rollback,
    [switch]$RefreshBundle,
    [string]$ProjectRoot,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $OutputEncoding

# 預設值不能寫在 param() 區塊裡（`= (Split-Path -Parent $PSScriptRoot)`）——
# 實測 PowerShell 5.1 在某些呼叫路徑下對參數預設值求值時 $PSScriptRoot 還沒填好，
# Split-Path 會撞上空字串直接炸掉。改成在 param 區塊之後、腳本邏輯開始之前解析。
. (Join-Path $PSScriptRoot 'lib\paths.ps1')
. (Join-Path $PSScriptRoot 'lib\runtime.ps1')
. (Join-Path $PSScriptRoot 'lib\version.ps1')

# 預設來源同樣要認得兩種形狀（模板 repo 的上一層、開工包的同一層）。
# 必須排在 dot-source 之後——Get-ToolVersionRoot 定義在 version.ps1 裡。擺在前面時
# 函式還不存在，而且連 -Rollback 這種根本用不到 SourceRoot 的路徑都會一起炸掉。
if (-not $SourceRoot) { $SourceRoot = Get-ToolVersionRoot -ScriptRoot $PSScriptRoot }

function Remove-OldRuntimeVersions {
    # 保留最近三版，超過才刪最舊的，且永不刪 current 與 previous（ADR-0008「回滾」段）。
    param(
        [string]$ListPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Current,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Previous
    )
    $root = Get-RuntimeRoot -ListPath $ListPath
    if (-not (Test-Path -LiteralPath $root)) { return @() }

    $all = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Name.EndsWith('.staging') } |
        Sort-Object LastWriteTime -Descending)

    $keep = New-Object System.Collections.Generic.HashSet[string]
    if ($Current)  { [void]$keep.Add($Current) }
    if ($Previous) { [void]$keep.Add($Previous) }
    foreach ($d in $all) {
        if ($keep.Count -ge 3) { break }
        [void]$keep.Add($d.Name)
    }

    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($d in $all) {
        if (-not $keep.Contains($d.Name)) {
            Remove-Item -LiteralPath $d.FullName -Recurse -Force
            [void]$removed.Add($d.Name)
        }
    }
    return $removed.ToArray()
}

try {
    if ($Rollback -and $RefreshBundle) {
        Write-Host "-Rollback 與 -RefreshBundle 不能一起用——它們是兩件不同的事。"
        exit $script:ExitFailed
    }

    # --- 回滾：不需要任何來源，舊版目錄還在 --------------------------------
    if ($Rollback) {
        $current = Read-RuntimeCurrent -ListPath $ListPath
        if ($null -eq $current) {
            Write-Host "這台機器還沒有 runtime 指標檔（current.json），沒有東西可以回滾。"
            exit $script:ExitFailed
        }
        if (Test-Unreadable $current) {
            Write-Host "runtime 指標檔讀不動（$(Get-RuntimeCurrentPath -ListPath $ListPath)），無法確認回滾的起點。"
            exit $script:ExitFailed
        }
        $currentVersion = Get-PropertyOrDefault -InputObject $current -Name 'version' -Default ''
        $previousVersion = Get-PropertyOrDefault -InputObject $current -Name 'previous' -Default ''
        if (-not $previousVersion) {
            Write-Host "current.json 沒有記錄 previous——這台機器只裝過一版，沒有版本可以回滾到。"
            exit $script:ExitFailed
        }
        $previousDir = Get-RuntimeVersionDir -ListPath $ListPath -Version $previousVersion
        if (-not (Test-Path -LiteralPath (Join-Path $previousDir 'heartbeat.ps1'))) {
            Write-Host "previous 記錄的版本（$previousVersion）目錄不在了，無法回滾：$previousDir"
            exit $script:ExitFailed
        }

        if ($DryRun) {
            Write-Host "會把 current.json 從 $currentVersion 指回 $previousVersion（$previousDir）。"
            Write-Host "dry run，沒有寫入任何東西。"
            exit $script:ExitOk
        }

        Write-RuntimeCurrent -ListPath $ListPath -Version $previousVersion -Previous $currentVersion
        Write-Host "已回滾：current.json 現在指向 $previousVersion（原本是 $currentVersion，兩個版本目錄都還在）。"
        exit $script:ExitOk
    }

    # --- 刷新專案自帶腳本：runtime 目錄當來源，不需要模板 repo ---------------
    if ($RefreshBundle) {
        if (-not $ProjectRoot) {
            Write-Host "-RefreshBundle 要搭配 -ProjectRoot 指定要刷新哪個專案。"
            exit $script:ExitFailed
        }
        if (-not (Test-Path -LiteralPath $ProjectRoot)) {
            Write-Host "專案目錄不存在：$ProjectRoot"
            exit $script:ExitFailed
        }

        if ($DryRun) {
            $current = Read-RuntimeCurrent -ListPath $ListPath
            if (($null -eq $current) -or (Test-Unreadable $current)) {
                Write-Host "這台機器還沒有可用的 runtime，沒有東西可以拿來刷新（先安裝或升級 runtime）。"
                exit $script:ExitFailed
            }
            $runtimeVersion = Get-PropertyOrDefault -InputObject $current -Name 'version' -Default ''
            $runtimeDir = Get-RuntimeVersionDir -ListPath $ListPath -Version $runtimeVersion
            if (-not (Test-Path -LiteralPath (Join-Path $runtimeDir 'heartbeat.ps1'))) {
                Write-Host "runtime 指標指向的版本（$runtimeVersion）目錄不在了：$runtimeDir"
                exit $script:ExitFailed
            }
            $targetScripts = Join-Path (Join-Path $ProjectRoot $script:HybridDirName) 'scripts'
            Write-Host "會用 runtime $runtimeVersion（$runtimeDir）刷新：$targetScripts"
            Write-Host "  * heartbeat.ps1"
            Write-Host "  * lib\ 底下的全部檔案"
            Write-Host "  * preflight-policy.default.json"
            Write-Host "不動這個專案自帶的其餘腳本（startup.ps1、shutdown.ps1 等）。"
            Write-Host "dry run，沒有寫入任何東西。"
            exit $script:ExitOk
        }

        $refresh = Invoke-RefreshProjectBundle -ListPath $ListPath -ProjectRoot $ProjectRoot
        if (-not $refresh.Ok) {
            Write-Host $refresh.Reason
            exit $script:ExitFailed
        }

        $targetScripts = Join-Path (Join-Path $ProjectRoot $script:HybridDirName) 'scripts'
        Write-Host "已用 runtime $($refresh.RuntimeVersion) 刷新：$targetScripts"
        Write-Host "  heartbeat.ps1、lib\、preflight-policy.default.json 已更新。"
        Write-Host "  其餘自帶腳本（startup.ps1、shutdown.ps1 等）沒有被動到。"
        exit $script:ExitOk
    }

    # --- 升級：新目錄 + 換指標 ----------------------------------------------
    $toolVersion = Get-ToolVersion -Root $SourceRoot
    $finalDir = Get-RuntimeVersionDir -ListPath $ListPath -Version $toolVersion
    $stagingDir = Join-Path (Get-RuntimeRoot -ListPath $ListPath) "$toolVersion.staging"

    if ($DryRun) {
        Write-Host "會升級到版本：$toolVersion"
        Write-Host "  來源     ：$SourceRoot"
        Write-Host "  staging  ：$stagingDir"
        Write-Host "  最終位置 ：$finalDir"
        Write-Host "  流程     ：複製到 staging → 自我驗證 → 換到最終位置 → 換指標"
        Write-Host "dry run，沒有寫入任何東西。"
        exit $script:ExitOk
    }

    $alreadyInstalled = Test-Path -LiteralPath (Join-Path $finalDir 'heartbeat.ps1')
    if ($alreadyInstalled) {
        # 上一次升級可能在「Move-Item 到最終位置」之後、「換指標」之前被中斷——
        # 那個版本目錄已經是完整、驗證過的（自我驗證在 Move-Item 之前一定跑過），
        # 不需要重新複製或重新驗證，直接跳到換指標（ADR-0008：3 之後、4 之前中斷
        # 是無害的，下一次升到同一版會偵測到並直接跳到換指標）。
        Write-Host "版本 $toolVersion 已經在 $finalDir（可能是上一次升級中斷在換指標之前留下的），跳過複製與自我驗證。"
    } else {
        # 開頭無條件刪除同名 staging（Install-RuntimeFiles 內部已經做這件事，
        # 比照 git.ps1:175 對暫存 index 的處理）——重跑一次升級不需要先手動清理。
        Install-RuntimeFiles -SourceRoot $SourceRoot -DestinationDir $stagingDir -ToolVersion $toolVersion | Out-Null

        Write-Host "自我驗證中……"
        $verify = Test-SelfVerifyRuntime -RuntimeVersionDir $stagingDir
        if (-not $verify.Ok) {
            Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "自我驗證失敗，升級中止，staging 已清除，current 沒有被動到。"
            Write-Host "  exit code：$($verify.ExitCode)"
            Write-Host "  輸出     ：$($verify.Output)"
            exit $script:ExitFailed
        }
        Write-Host "自我驗證通過。"

        Move-Item -LiteralPath $stagingDir -Destination $finalDir -Force
    }

    $existingCurrent = Read-RuntimeCurrent -ListPath $ListPath
    $previousVersion = ''
    if (($null -ne $existingCurrent) -and (-not (Test-Unreadable $existingCurrent))) {
        $previousVersion = Get-PropertyOrDefault -InputObject $existingCurrent -Name 'version' -Default ''
    }
    Write-RuntimeCurrent -ListPath $ListPath -Version $toolVersion -Previous $previousVersion

    # @() 包起來：Remove-OldRuntimeVersions 沒有東西要刪時 `return $removed.ToArray()`
    # 送出的是零個管線物件，不包的話 $removedVersions 會被解成 $null，
    # 下面 .Count 在 StrictMode 下直接炸掉（registry.ps1 warned 過同一個坑）。
    $removedVersions = @(Remove-OldRuntimeVersions -ListPath $ListPath -Current $toolVersion -Previous $previousVersion)

    Write-Host "升級完成：current 現在是 $toolVersion$(if ($previousVersion) { "（原本是 $previousVersion，仍保留）" } else { '' })"
    if ($removedVersions.Count -gt 0) {
        Write-Host "已清掉超過保留上限的舊版本：$($removedVersions -join '、')"
    }
    exit $script:ExitOk
}
catch {
    Write-Host "升級工具失敗：$($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    exit $script:ExitFailed
}
