<#
.SYNOPSIS
    列出這台機器的 runtime 版本，以及清單裡每個專案的相容狀態與最近一次心跳結果。

.DESCRIPTION
    docs/adr/0008-scheduler-runs-installed-runtime-not-repo-scripts.md 的驗收條件
    「可列出所有專案版本與相容狀態」就是這支腳本。純唯讀，不寫入任何東西。

.PARAMETER ListPath
    機器層級的家目錄。預設 `%LOCALAPPDATA%\hybrid-workspace`。測試接縫。

.OUTPUTS
    exit 0 = 已列出（含「這台還沒裝 runtime」這種狀態本身）；1 = 讀取途中出錯。
#>
[CmdletBinding()]
param(
    [string]$ListPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $OutputEncoding

. (Join-Path $PSScriptRoot 'lib\paths.ps1')
. (Join-Path $PSScriptRoot 'lib\registry.ps1')
. (Join-Path $PSScriptRoot 'lib\runtime.ps1')
. (Join-Path $PSScriptRoot 'lib\version.ps1')
. (Join-Path $PSScriptRoot 'lib\health.ps1')

try {
    $current = Read-RuntimeCurrent -ListPath $ListPath
    $runtimeVersion = ''
    $schemaMin = $null
    $schemaMax = $null

    # 裝置身分先講。三裝置試點要拿三台的值互相比對（兩台一樣就代表 device.json 是被
    # 複製過去的，租約的所有權判定會整批失真），而這個檔案是第一次開工時才惰性鑄造的
    # ——裝完 runtime 就來看的人一定看不到它，需要一句話說明那是正常的。
    #
    # 唯讀：不存在也不在這裡鑄一顆。這支腳本的 .DESCRIPTION 承諾「純唯讀」，而且
    # 讓「看一下狀態」變成「改變了狀態」，會讓之後任何一次比對都說不清那顆 id
    # 是開工鑄的還是查看鑄的。
    $devicePath = Get-DeviceIdPath -ListPath $ListPath
    Write-Host "這台機器的裝置身分"
    if (-not (Test-Path -LiteralPath $devicePath)) {
        Write-Host "  deviceId ：還沒產生（第一次開工時才會鑄造）"
        Write-Host "             位置：$devicePath"
    } else {
        # 「讀不到」與「沒有值」要求相反的動作，不能混為一談：說成「還沒產生」會讓人
        # 以為下次開工會鑄一顆新的，但檔案就在那裡，Get-DeviceIdentity 會拋例外而不是
        # 重鑄（registry.ps1 寫明了理由——悄悄換一顆會讓既有租約的所有權判定失真）。
        $deviceId = ''
        $unreadable = $false
        try {
            $parsed = Get-Content -LiteralPath $devicePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $deviceId = Get-PropertyOrDefault -InputObject $parsed -Name 'deviceId' -Default ''
        } catch {
            $unreadable = $true
        }
        if ($unreadable) {
            Write-Host "  deviceId ：讀不動（$devicePath）——檔案存在但無法解析"
            Write-Host "             這不是「還沒產生」。開工不會重鑄一顆，會直接停下來。"
        } elseif (-not $deviceId) {
            Write-Host "  deviceId ：讀不到（$devicePath 沒有 deviceId 欄位）"
        } else {
            Write-Host "  deviceId ：$deviceId"
        }
    }
    Write-Host ""

    Write-Host "這台機器的 runtime"
    if ($null -eq $current) {
        Write-Host "  狀態     ：還沒安裝（$(Get-RuntimeCurrentPath -ListPath $ListPath) 不存在）"
    } elseif (Test-Unreadable $current) {
        Write-Host "  狀態     ：指標檔讀不動（$(Get-RuntimeCurrentPath -ListPath $ListPath)）"
    } else {
        $runtimeVersion = Get-PropertyOrDefault -InputObject $current -Name 'version' -Default ''
        $previousVersion = Get-PropertyOrDefault -InputObject $current -Name 'previous' -Default ''
        Write-Host "  版本     ：$runtimeVersion$(if ($previousVersion) { "（上一版：$previousVersion，仍保留）" } else { '' })"

        $versionInfo = Read-RuntimeVersionInfo -RuntimeVersionDir (Get-RuntimeVersionDir -ListPath $ListPath -Version $runtimeVersion)
        if (($null -ne $versionInfo) -and (-not (Test-Unreadable $versionInfo))) {
            $schemaMinRaw = Get-PropertyOrDefault -InputObject $versionInfo -Name 'schemaMin' -Default ''
            $schemaMaxRaw = Get-PropertyOrDefault -InputObject $versionInfo -Name 'schemaMax' -Default ''
            if ($schemaMinRaw) { $schemaMin = [int]$schemaMinRaw }
            if ($schemaMaxRaw) { $schemaMax = [int]$schemaMaxRaw }
            Write-Host "  schema   ：認得 $schemaMin–$schemaMax"
        } else {
            Write-Host "  schema   ：VERSION.json 讀不到，無法判定這個版本認得哪個區間"
        }
    }
    Write-Host ""

    $entries = @(Read-ProjectList -ListPath $ListPath)
    $state = Read-HeartbeatState -ListPath $ListPath
    Write-Host "登記的專案（共 $($entries.Count) 個）"

    foreach ($entry in $entries) {
        $path = Get-PropertyOrDefault -InputObject $entry -Name 'path' -Default ''
        if (-not $path) { continue }

        Write-Host "  * $path"

        if (-not (Test-Path -LiteralPath $path)) {
            Write-Host "      相容判定 ：資料夾不在（暫時或永久都可能）"
        } else {
            $schemaResult = Get-ProjectSchemaVersion -ProjectRoot $path
            if (Test-Unreadable $schemaResult) {
                Write-Host "      相容判定 ：manifest 讀不動"
            } elseif ($null -eq $schemaResult) {
                Write-Host "      相容判定 ：不是 hybrid workspace 專案（找不到 .hybrid/project.json）"
            } elseif (($null -eq $schemaMin) -or ($null -eq $schemaMax)) {
                Write-Host "      schemaVersion：$schemaResult"
                Write-Host "      相容判定 ：無法判定——這台沒有可用的 runtime schema 資訊"
            } else {
                $compat = Test-SchemaCompatible -Schema $schemaResult -Min $schemaMin -Max $schemaMax
                $label = switch ($compat) {
                    'ok'      { '相容' }
                    'too-old' { "太舊（schema $schemaResult，這台 runtime 認得 $schemaMin 以上——請升級這個專案）" }
                    'too-new' { "太新（schema $schemaResult，這台 runtime 只認得到 $schemaMax——請升級這台的 runtime）" }
                    default   { $compat }
                }
                Write-Host "      schemaVersion：$schemaResult"
                Write-Host "      相容判定 ：$label"
            }
        }

        $projectState = if ($state.ContainsKey($path)) { $state[$path] } else { $null }
        $lastResult = Get-PropertyOrDefault -InputObject $projectState -Name 'lastResult' -Default '（尚未執行過）'
        $consecutiveFailures = Get-PropertyOrDefault -InputObject $projectState -Name 'consecutiveFailures' -Default '0'
        $lastAttempt = Get-PropertyOrDefault -InputObject $projectState -Name 'lastAttempt' -Default '（尚未執行過）'
        Write-Host "      最近一次 ：$lastAttempt，結果 $lastResult，連續未成功 $consecutiveFailures 次"

        # 票 28：把 state.json、preflight-skip-log.jsonl（票 21）、固定格式標記行
        # （票 21/25/26）、這裡（資料夾不在）收成一個健康判定——「最近一次」那一行
        # 已經有原始數字，這裡是判定過後的結論。
        $health = Get-ProjectHealth -Path $path -State $projectState
        if ($health.Severity -eq 'ok') {
            Write-Host "      健康     ：正常"
        } else {
            $label = if ($health.Severity -eq 'critical') { '告警' } else { '警告' }
            Write-Host "      健康     ：$label"
            foreach ($msg in $health.Alerts) { Write-Host "        * $msg" }
        }
    }

    exit $script:ExitOk
}
catch {
    Write-Host "讀取狀態失敗：$($_.Exception.Message)"
    exit $script:ExitFailed
}
