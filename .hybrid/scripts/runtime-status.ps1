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

        # 已經裝在這台、但沒有被指標指到的版本。真機試點時兩台機器都停在這個狀態：
        # install-heartbeat 裝好了新版，但因為已經有 current 就不動指標（那是刻意的，
        # 避免安裝器比艦隊舊時造成靜默降級），於是心跳活著卻跑舊碼——而那沒有訊號（票 37）。
        #
        # 只在真的有落差時才印。每次都印一段提醒會訓練人忽略它。
        $runtimeRoot = Get-RuntimeRoot -ListPath $ListPath
        $idleVersions = @()
        if (Test-Path -LiteralPath $runtimeRoot) {
            $idleVersions = @(Get-ChildItem -LiteralPath $runtimeRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike '*.staging' -and $_.Name -ne $runtimeVersion -and $_.Name -ne $previousVersion } |
                Select-Object -ExpandProperty Name)
        }
        if ($idleVersions.Count -gt 0) {
            Write-Host "  也裝好了 ：$($idleVersions -join '、')——但沒有在跑"
            Write-Host "             要切換：upgrade-runtime.ps1（不需要提權，先加 -DryRun 看它會做什麼）"
        }
    }
    Write-Host ""

    $entries = @(Read-ProjectList -ListPath $ListPath)
    # 派工器自己的死活要單獨講，而且要在專案清單**之前**——因為派工器沒跑的話，
    # 底下每個專案顯示的都是凍結在最後一次成功的舊資料，先看到那些會誤導。
    #
    # 去問排程器（它的紀錄由排程器寫，不是派工器寫，所以派工器死了它照樣更新）。
    # 問不到就傳 $null，判斷函式會退化成「查不到，無法判斷」——不猜。
    # 測試接縫：HYBRID_TEST_TASK_LASTRUN / HYBRID_TEST_TASK_RESULT 覆寫這次查詢，
    # 讓「排程器說跑過但紀錄沒更新」這個情境測得到（真的去動排程器才測得到就等於測不到）。
    $taskLastRun = $null
    $taskLastResult = $null
    # 'none' 表示「假裝查不到」——測試需要在一台**真的裝了排程**的機器上重現
    # 「查不到排程器」那條路徑，否則那條路徑只有在沒裝的機器上才測得到。
    if ($env:HYBRID_TEST_TASK_LASTRUN -eq 'none') {
        $taskLastRun = $null
    } elseif ($env:HYBRID_TEST_TASK_LASTRUN) {
        $taskLastRun = [DateTime]::Parse($env:HYBRID_TEST_TASK_LASTRUN)
        if ($env:HYBRID_TEST_TASK_RESULT) { $taskLastResult = [int]$env:HYBRID_TEST_TASK_RESULT }
    } else {
        try {
            $info = Get-ScheduledTaskInfo -TaskPath '\hybrid-workspace\' -TaskName 'heartbeat' -ErrorAction Stop
            if ($info.LastRunTime -and $info.LastRunTime -gt [DateTime]'1900-01-01') { $taskLastRun = $info.LastRunTime }
            $taskLastResult = [int]$info.LastTaskResult
        } catch {
            # 排程沒安裝、或這個環境沒有 ScheduledTasks 模組。兩種都只是「問不到」。
        }
    }

    $dispatcher = Get-DispatcherLiveness -ListPath $ListPath -TaskLastRun $taskLastRun -TaskLastResult $taskLastResult
    Write-Host "派工器"
    Write-Host "  最近一次 ：$($dispatcher.Line)"
    if ($dispatcher.Severity -eq 'critical') {
        Write-Host "  注意     ：底下每個專案的健康是派工器寫的，它沒跑就不會更新——"
        Write-Host "             那些「正常」只代表最後一次跑的時候是好的。"
        Write-Host "  怎麼查   ：事件記錄 Microsoft-Windows-TaskScheduler/Operational 的 Id 201"
        Write-Host "             有原始的結束碼（LastTaskResult 會被正規化成 1，看不出原因）。"
    }
    Write-Host ""

    # 清單一致性（票 38 方案 D）。印在專案清單**之前**——底下每一行都建立在
    # 「這份清單就是心跳用的那份」這個前提上，前提不成立的話先講。
    $agreement = Get-ProjectListAgreement -ListPath $ListPath
    if ($agreement -and -not $agreement.Agrees) {
        foreach ($line in $agreement.Lines) { Write-Host $line }
        Write-Host ""
    }

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
