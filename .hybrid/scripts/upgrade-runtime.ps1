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
# 必須排在 dot-source 之後——Get-ToolVersionRoot 定義在 version.ps1 裡。
#
# **而且只有真的需要來源的模式才解析。** -Rollback 只讀 current.json 的 previous、
# -RefreshBundle 把工作委給 Invoke-RefreshProjectBundle（只吃 ListPath 與 ProjectRoot），
# 兩者都不碰 $SourceRoot。
#
# 這一點不是潔癖：Get-ToolVersionRoot 找不到版本檔時會 throw，而這一行在 try 之外，
# 配上 $ErrorActionPreference = 'Stop' 就是印堆疊、非零離開。專案自帶的
# .hybrid\scripts\ 底下沒有 VERSION.json、上一層 .hybrid\ 也沒有——於是從那個位置
# 跑 -Rollback 會在「解析一個它不需要的參數」時死掉，**回滾一次都沒發生**。
#
# 而那正是最需要它的情境：install-heartbeat 不會把這支腳本複製到機器層級，
# 所以手上只有專案、runtime 又出了問題的人，會反射性地去 .hybrid\scripts\ 找它。
#
# 舊寫法 Split-Path -Parent 對這兩個模式算出來的是垃圾路徑，但永遠不會 throw，
# 所以那條逃生門本來是通的——是這次改動把它關上的。
if (-not $Rollback -and -not $RefreshBundle -and -not $SourceRoot) {
    $SourceRoot = Get-ToolVersionRoot -ScriptRoot $PSScriptRoot
}

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

        # 【票 30 F8】上面只確認了「`heartbeat.ps1` 這個檔案還在」。**檔案在不等於它能跑。**
        #
        # 實測：把 previous 的一個 lib 刪掉（防毒隔離的典型形狀，而這個專案史上撞過的
        # 0x80070002 就是這樣來的），heartbeat.ps1 仍然在，於是回滾成功、exit 0，
        # 訊息還說「兩個版本目錄都還在」——那句話字面為真，而**目錄在正是它唯一
        # 檢查過的事**，不是使用者想知道的那件事。
        #
        # 回滾發生的時機，本來就是「現在這一版出問題了」。在那個時刻靜靜切到
        # 另一份壞掉的 runtime，是這條線上最不該出現的無聲失敗。
        #
        # 升級早就有自我驗證了（Install-RuntimeFiles 之後跑 Test-SelfVerifyRuntime），
        # 回滾沒有。同一個函式，這裡直接用。
        Write-Host "自我驗證 $previousVersion……"
        $rollbackVerify = Test-SelfVerifyRuntime -RuntimeVersionDir $previousDir
        if (-not $rollbackVerify.Ok) {
            Write-Host "停下來了：$previousVersion 的自我驗證沒過，指標**沒有**被改動（仍然是 $currentVersion）。"
            Write-Host "  exit code：$($rollbackVerify.ExitCode)"
            Write-Host "  輸出     ：$($rollbackVerify.Output)"
            Write-Host "  位置     ：$previousDir"
            Write-Host ""
            Write-Host "檔案還在，但它跑不起來（少了 lib、被防毒隔離、或複製到一半）。"
            Write-Host "回滾到一份壞掉的 runtime 不會讓事情變好——這台機器目前兩版都不可信。"
            Write-Host "往前走比往回走可靠：用 -SourceRoot 指向一份完整的來源重裝一次"
            Write-Host "（開工包的 _bootstrap\，或模板 repo 的 scripts\）。"
            exit $script:ExitFailed
        }
        Write-Host "自我驗證通過。"

        if ($DryRun) {
            Write-Host "會把 current.json 從 $currentVersion 指回 $previousVersion（$previousDir）。"
            Write-Host "dry run，沒有寫入任何東西。"
            exit $script:ExitOk
        }

        Write-RuntimeCurrent -ListPath $ListPath -Version $previousVersion -Previous $currentVersion
        Write-Host "已回滾：current.json 現在指向 $previousVersion（原本是 $currentVersion，而且它通過了自我驗證）。"
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

    # 「已經裝好了」不能只看目錄在不在——那等於相信版本字串代表內容（票 33）。
    # 內容相同才跳過；不同就照常複製與自我驗證。
    $alreadyInstalled = (Test-Path -LiteralPath (Join-Path $finalDir 'heartbeat.ps1')) -and
                        (Test-RuntimeContentMatches -SourceRoot $SourceRoot -RuntimeVersionDir $finalDir)
    if ($alreadyInstalled) {
        # 上一次升級可能在「Move-Item 到最終位置」之後、「換指標」之前被中斷——
        # 那個版本目錄已經是完整、驗證過的（自我驗證在 Move-Item 之前一定跑過），
        # 不需要重新複製或重新驗證，直接跳到換指標（ADR-0008：3 之後、4 之前中斷
        # 是無害的，下一次升到同一版會偵測到並直接跳到換指標）。
        Write-Host "版本 $toolVersion 已經在 $finalDir 且內容與來源相同（可能是重複執行升級，也可能是上一次升級中斷在換指標之前留下的），跳過複製與自我驗證。"
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

        # 目的地已存在時必須先刪掉。Move-Item -Force 對「已存在的目錄」的語義是
        # **移進去**，不是覆蓋——結果會變成 runtime\<版本>\<版本>.staging\，
        # 而外層那個舊版本目錄原封不動。
        #
        # 票 33 之前這條路徑走不到（版本目錄存在就一定跳過），所以這個問題一直被
        # 遮著。現在內容不同時會重裝，它才浮出來。
        #
        # 刪除與移動之間有一個窗口：中斷的話這個版本目錄會不見。可以接受，因為
        # (a) 自我驗證已經通過，staging 是完整的；(b) 派工器對「current 指向的目錄
        # 不見了」已經有處理——退回 previous，退不了就本輪不處理任何專案（不會去跑
        # 專案自帶的那份）；(c) 下一次升級會重新裝好。相對地，不刪就是靜靜地留下
        # 一個舊版本，那才是無聲的錯誤。
        if (Test-Path -LiteralPath $finalDir) {
            Remove-Item -LiteralPath $finalDir -Recurse -Force
        }
        Move-Item -LiteralPath $stagingDir -Destination $finalDir -Force
    }

    $existingCurrent = Read-RuntimeCurrent -ListPath $ListPath
    $currentBefore = ''
    $previousBefore = ''
    if (($null -ne $existingCurrent) -and (-not (Test-Unreadable $existingCurrent))) {
        $currentBefore = Get-PropertyOrDefault -InputObject $existingCurrent -Name 'version' -Default ''
        $previousBefore = Get-PropertyOrDefault -InputObject $existingCurrent -Name 'previous' -Default ''
    }

    # 已經就是目標版本時（重跑同一個指令），這次「換指標」是 no-op——**不要動 previous**。
    #
    # 舊寫法無條件把 previous 設成舊的 current，於是重跑一次就把
    # previous 踩成自己：`{"version":"1.2.1","previous":"1.2.1"}`。目錄都還在，
    # 所以 ADR-0008 的「永不刪 current 與 previous」沒被違反，但 previous 從此
    # 指不到任何不同的東西——回滾的能力在資料上還在，在指標上已經沒了。
    #
    # 真機上是這樣被抓到的：先升到 1.2.1（previous 記 1.0.0），再跑一次同一個指令
    # 驗票 33 的跳過路徑，previous 就變成 1.2.1。而那一次是 exit 0、訊息還說
    # 「（原本是 1.2.1，仍保留）」——字面上為真（1.2.1 確實保留著），
    # 但它讀起來像「你的上一版安全地留著」，實際發生的是「你的上一版被這個值取代了」。
    #
    # 回滾是出事時才會用到的東西，而它壞掉的方式是一次成功的操作。
    $isSameVersion = ($currentBefore -eq $toolVersion) -and $currentBefore
    $previousVersion = if ($isSameVersion) { $previousBefore } else { $currentBefore }

    # no-op 時**完全不寫**，不是「寫回同樣的值」。
    #
    # 先前只保住了 previous，但 Write-RuntimeCurrent 仍然會重寫 switchedAt——
    # 於是那一次的訊息說「指標沒有變動」，而檔案裡的時間戳往前跳了兩秒。
    #
    # switchedAt 的語義是「指標**切換**的時間」。一次沒有切換的執行把它往前推，
    # 等於記錄了一個「這一刻發生過切換」的事實，而那一刻什麼都沒發生。之後要追
    # 「這台機器什麼時候換到 X 的」，它會回答「最後一次有人跑過升級的時間」。
    #
    # 既然訊息已經明確宣稱「沒有變動」，讓它成真比改那句話便宜——而且那句話是對的，
    # 該改的是行為。
    if (-not $isSameVersion) {
        Write-RuntimeCurrent -ListPath $ListPath -Version $toolVersion -Previous $previousVersion
    }

    # @() 包起來：Remove-OldRuntimeVersions 沒有東西要刪時 `return $removed.ToArray()`
    # 送出的是零個管線物件，不包的話 $removedVersions 會被解成 $null，
    # 下面 .Count 在 StrictMode 下直接炸掉（registry.ps1 warned 過同一個坑）。
    $removedVersions = @(Remove-OldRuntimeVersions -ListPath $ListPath -Current $toolVersion -Previous $previousVersion)

    if ($isSameVersion) {
        # 不要說「原本是 X」——那會把一次 no-op 講成一次版本變更。
        Write-Host "current 本來就是 $toolVersion，指標沒有變動$(if ($previousVersion) { "（可回滾到 $previousVersion）" } else { '' })。"
    } else {
        Write-Host "升級完成：current 現在是 $toolVersion$(if ($previousVersion) { "（原本是 $previousVersion，仍保留）" } else { '' })"
    }
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
