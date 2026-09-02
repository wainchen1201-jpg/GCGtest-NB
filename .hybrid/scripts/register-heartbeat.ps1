<#
.SYNOPSIS
    把這個專案登記到心跳清單。**不需要系統管理員權限。**

.DESCRIPTION
    心跳的排程項目是機器層級的，一台機器只註冊一次（`install-heartbeat.ps1`，那一次
    需要提權）。登記專案只是往清單裡加一筆路徑，所以不需要任何特殊權限。

    這是票 11 的重點：把「需要管理員」的那一次，跟「每個專案都要做」的那件事拆開。

    開工會自動登記，所以正常情況下你不必手動跑這支。

.PARAMETER ProjectRoot
    要登記的專案。預設為目前目錄。

.PARAMETER ListPath
    清單所在的目錄。預設 `%LOCALAPPDATA%\hybrid-workspace`。測試接縫。

.PARAMETER Unregister
    從清單移除這個專案。同樣不需要提權。

.PARAMETER DryRun
    只印出會做什麼，不改清單。

.OUTPUTS
    exit 0 = 完成；1 = 失敗。
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$ListPath,
    [switch]$Unregister,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $OutputEncoding

. (Join-Path $PSScriptRoot 'lib\paths.ps1')
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
        Write-Host "這個目錄還不是 hybrid workspace 專案（找不到 .hybrid/project.json）。"
        exit $script:ExitFailed
    }
    $projectId = [string]$manifest.projectId
    $listFile = Get-ProjectListPath -ListPath $ListPath

    if ($Unregister) {
        if ($DryRun) {
            Write-Host "會從清單移除：$ProjectRoot"
            Write-Host "清單：$listFile"
            exit $script:ExitOk
        }
        $removed = Remove-ProjectFromList -ListPath $ListPath -ProjectRoot $ProjectRoot
        if ($removed) {
            Write-Host "已從心跳清單移除：$projectId"
        } else {
            Write-Host "本來就不在清單裡：$projectId"
        }
        Write-Host "清單：$listFile（剩 $(@(Read-ProjectList -ListPath $ListPath).Count) 個專案）"
        exit $script:ExitOk
    }

    if ($DryRun) {
        Write-Host "會登記到心跳清單"
        Write-Host "  專案 ID  ：$projectId"
        Write-Host "  路徑     ：$ProjectRoot"
        Write-Host "  清單     ：$listFile"
        Write-Host "  提權     ：不需要"
        exit $script:ExitOk
    }

    $added = Add-ProjectToList -ListPath $ListPath -ProjectRoot $ProjectRoot -ProjectId $projectId
    if ($added) {
        Write-Host "已登記到心跳清單：$projectId"
    } else {
        Write-Host "已經在清單裡了：$projectId"
    }
    Write-Host "  路徑：$ProjectRoot"
    Write-Host "  清單：$listFile（共 $(@(Read-ProjectList -ListPath $ListPath).Count) 個專案）"

    # 清單有了但排程沒裝的話，心跳永遠不會被觸發——這種沉默的失效要講出來。
    $installed = $null
    try {
        $installed = Get-ScheduledTask -TaskPath '\hybrid-workspace\' -TaskName 'heartbeat' -ErrorAction SilentlyContinue
    } catch { }
    if (-not $installed) {
        Write-Host ""
        Write-Host "注意：這台機器還沒安裝心跳排程，登記了也不會被觸發。"
        Write-Host "以系統管理員身分執行一次（整台機器只要做這一次）："
        Write-Host "  install-heartbeat.ps1"
    }

    exit $script:ExitOk
}
catch {
    Write-Host "登記失敗：$($_.Exception.Message)"
    exit $script:ExitFailed
}
