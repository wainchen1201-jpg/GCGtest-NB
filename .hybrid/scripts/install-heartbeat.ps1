<#
.SYNOPSIS
    在這台機器上安裝心跳排程。**一台機器做一次**，需要系統管理員權限。

.DESCRIPTION
    註冊**單一**工作排程器項目，它會定期呼叫派工器；派工器再依清單處理每個專案。

    之後新增或移除專案都只是改清單（`register-heartbeat.ps1`），**不需要提權**。
    這是這個設計存在的唯一理由：把「需要管理員」的那一次跟「每個專案都要做」的那件事
    拆開（票 11）。

    安裝會把派工器複製到 `%LOCALAPPDATA%\hybrid-workspace\`。它不能住在專案裡——
    專案資料夾會被刪掉，而排程項目不該跟著死。

.PARAMETER ListPath
    機器層級的家目錄。預設 `%LOCALAPPDATA%\hybrid-workspace`。測試接縫。

.PARAMETER IntervalMinutes
    多久跑一次。預設 15 分鐘。

.PARAMETER Uninstall
    移除排程項目。清單與各專案都不動。

.PARAMETER DryRun
    只印出會做什麼，不碰排程器也不複製檔案。

.OUTPUTS
    exit 0 = 完成；1 = 失敗（含權限不足）。
#>
[CmdletBinding()]
param(
    [string]$ListPath,
    [int]$IntervalMinutes = 15,
    [switch]$Uninstall,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $OutputEncoding

. (Join-Path $PSScriptRoot 'lib\paths.ps1')
. (Join-Path $PSScriptRoot 'lib\registry.ps1')
. (Join-Path $PSScriptRoot 'lib\runtime.ps1')
. (Join-Path $PSScriptRoot 'lib\version.ps1')

$TaskFolder = '\hybrid-workspace\'
$TaskName = 'heartbeat'

try {
    $homeDir = Get-HeartbeatHome -ListPath $ListPath

    if ($Uninstall) {
        if ($DryRun) {
            Write-Host "會移除排程項目：$TaskFolder$TaskName"
            exit $script:ExitOk
        }
        $existing = Get-ScheduledTask -TaskPath $TaskFolder -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $existing) {
            Write-Host "這台機器上沒有心跳排程，不用移除。"
            exit $script:ExitOk
        }
        Unregister-ScheduledTask -TaskPath $TaskFolder -TaskName $TaskName -Confirm:$false
        Write-Host "心跳排程已移除。清單與各專案都沒有動。"
        Write-Host "清單還在：$(Get-ProjectListPath -ListPath $ListPath)"
        exit $script:ExitOk
    }

    $runnerSource = @(
        (Join-Path $PSScriptRoot 'run-heartbeats.ps1'),
        (Join-Path $PSScriptRoot 'run-heartbeats.vbs')
    )
    # 整個 lib\ 複製過去，不列舉檔名。
    #
    # 列舉過的那一版寫了 paths + registry 兩個，但派工器 dot-source 三個
    # （多一個 runtime.ps1），而 runtime.ps1 自己又 dot-source version.ps1——
    # 少了兩個。dot-source 在腳本頂層、任何 try/catch 之前，配上
    # $ErrorActionPreference = 'Stop'，派工器在寫任何 log 之前就死，
    # 排程器拿到 0x80070002，而 state.json 與 last-run.log 凍結在最後一次成功，
    # 於是健康檢查永遠顯示「正常」。三裝置試點時兩台機器同時處於這個狀態好幾小時。
    #
    # Install-RuntimeFiles 早就寫了同樣的理由（「列舉容易漏」），runner 這一半沒照做。
    # 多帶幾支目前用不到的 lib 沒有安全代價——ADR-0008 守的是 $ProjectRoot 底下的
    # 內容不能被執行，不是機器層級的 lib\ 要多精簡。
    $libSourceDir = Join-Path $PSScriptRoot 'lib'
    $shim = Join-Path $homeDir 'run-heartbeats.vbs'
    $argumentList = ('"{0}"' -f $shim)

    # 來源就是這支腳本自己所在的那一層——模板 repo 的 scripts\ 或開工包的
    # _bootstrap\，兩種形狀 Resolve-RuntimeSourceDir 都認得。版本檔則可能在
    # 同一層（開工包）或上一層（模板 repo），交給 Get-ToolVersionRoot 判斷。
    $sourceRoot = $PSScriptRoot
    $toolVersion = Get-ToolVersion -Root (Get-ToolVersionRoot -ScriptRoot $PSScriptRoot)
    $runtimeVersionDir = Get-RuntimeVersionDir -ListPath $ListPath -Version $toolVersion

    if ($DryRun) {
        Write-Host "會安裝的排程項目"
        Write-Host "  名稱     ：$TaskFolder$TaskName"
        Write-Host "  執行     ：wscript.exe $argumentList"
        Write-Host "  家目錄   ：$homeDir"
        Write-Host "  清單     ：$(Get-ProjectListPath -ListPath $ListPath)"
        Write-Host "  頻率     ：每 $IntervalMinutes 分鐘，登入時也會跑一次"
        Write-Host "  身分     ：$env:USERNAME（執行時不提權——要讀得到 Google Drive 的虛擬磁碟）"
        Write-Host ""
        Write-Host "會安裝的 runtime（ADR-0008：跟派工器同一個動作，不能分開）"
        Write-Host "  版本     ：$toolVersion"
        Write-Host "  位置     ：$runtimeVersionDir"
        Write-Host ""
        Write-Host "dry run，沒有動排程器，也沒有複製檔案。"
        exit $script:ExitOk
    }

    # --- 把派工器放到機器層級 ---------------------------------------------
    New-Item -ItemType Directory -Path (Join-Path $homeDir 'lib') -Force | Out-Null
    foreach ($f in $runnerSource) { Copy-Item -LiteralPath $f -Destination $homeDir -Force }
    Copy-Item -Path (Join-Path $libSourceDir '*') -Destination (Join-Path $homeDir 'lib') -Recurse -Force

    # --- 中央 runtime：第一版 -----------------------------------------------
    # ADR-0008：安裝派工器與安裝第一版 runtime 是同一個動作，不能分開——否則
    # 「派工器是新的但沒有 runtime」會在正常路徑上出現，那正是這份設計要消滅的洞。
    Install-RuntimeFiles -SourceRoot $sourceRoot -DestinationDir $runtimeVersionDir -ToolVersion $toolVersion | Out-Null

    # 只在這台機器還沒有 current.json（或它讀不動）時才把指標寫過去——避免這支
    # 安裝器如果版本比艦隊目前已經升級到的版本舊，反而造成一次靜默降級。升級是
    # upgrade-runtime.ps1 明確前景指令的職責，不是這裡。
    $existingCurrent = Read-RuntimeCurrent -ListPath $ListPath
    $runtimeAlreadyCurrent = ($null -ne $existingCurrent) -and (-not (Test-Unreadable $existingCurrent))
    if (-not $runtimeAlreadyCurrent) {
        Write-RuntimeCurrent -ListPath $ListPath -Version $toolVersion -Previous ''
    }

    # --- 舊制的殘留：一個專案一個排程項目 ---------------------------------
    $legacy = @(Get-ScheduledTask -TaskPath $TaskFolder -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -ne $TaskName })
    foreach ($old in $legacy) {
        Unregister-ScheduledTask -TaskPath $TaskFolder -TaskName $old.TaskName -Confirm:$false
        Write-Host "移除舊制的排程項目：$($old.TaskName)"
    }

    # --- 註冊 -------------------------------------------------------------
    # 不設 -WorkingDirectory：派工器不依賴工作目錄，而綁了之後那個目錄一旦不見，
    # 排程器會在啟動動作那一步就失敗（事件 203 / 0x8007010B），腳本連跑都沒跑到。
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $argumentList

    $logon = New-ScheduledTaskTrigger -AtLogOn
    $repeating = New-ScheduledTaskTrigger -Daily -At '00:00'
    $repeating.Repetition = (New-ScheduledTaskTrigger -Once -At '00:00' `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
        -RepetitionDuration (New-TimeSpan -Days 1)).Repetition

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 14)

    Register-ScheduledTask -TaskPath $TaskFolder -TaskName $TaskName `
        -Action $action -Trigger @($logon, $repeating) -Settings $settings `
        -Description 'hybrid workspace 心跳派工器：依清單處理這台機器上的所有專案' -Force | Out-Null

    $count = @(Read-ProjectList -ListPath $ListPath).Count
    Write-Host "心跳已安裝在這台機器上"
    Write-Host "  名稱     ：$TaskFolder$TaskName"
    Write-Host "  家目錄   ：$homeDir"
    Write-Host "  清單     ：$(Get-ProjectListPath -ListPath $ListPath)（目前 $count 個專案）"
    Write-Host "  頻率     ：每 $IntervalMinutes 分鐘，登入時也會跑一次"
    Write-Host "  視窗     ：不會出現（wscript 沒有 console）"
    Write-Host "  runtime  ：$toolVersion（$runtimeVersionDir）$(if ($runtimeAlreadyCurrent) { '——這台機器已經在跑別的版本，指標沒有被改動' } else { '' })"
    Write-Host ""
    Write-Host "這是這台機器唯一需要提權的一次。之後新增專案只要開工，"
    Write-Host "它會自動把專案加進清單——不需要管理員權限。"
    exit $script:ExitOk
}
catch {
    Write-Host "安裝失敗：$($_.Exception.Message)"
    if ("$($_.Exception.Message)" -match 'Access is denied|存取被拒') {
        Write-Host ""
        Write-Host "寫入工作排程器需要系統管理員權限。以系統管理員身分開一個 PowerShell，"
        Write-Host "用**絕對路徑**再跑一次（提權視窗的起始目錄是 C:\Windows\system32）。"
    }
    exit $script:ExitFailed
}
