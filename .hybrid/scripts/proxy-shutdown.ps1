<#
.SYNOPSIS
    代理收工：在這台裝置上，替忘記收工的另一台裝置把事做完。

.DESCRIPTION
    這是 ADR-0002 定義的逃生門。ADR-0002 當初的判斷——租約不阻擋任何裝置開工——已經被
    ADR-0006 推翻：租約 v2 預設會阻擋別台裝置的可寫開工，代理收工正是被擋住之後的其中
    一條出路，不再是唯一動機。

    它與強制接管的差別在意圖：不是搶，是替它完成。所以預設只顯示對方留下了什麼，
    要動手必須明確帶 -Confirmed。

    對方的心跳從沒跑過或已經停擺時，代理收工會退化成「只能釋放租約」——那些沒提交
    的變更還困在那台機器上，拿不回來。這是可接受的降級，但一定會講清楚。

.PARAMETER ProjectRoot
    專案在本機的位置。預設為目前目錄。

.PARAMETER DriveRoot
    Drive 端的根目錄。省略時依「本機設定檔 → 自動偵測」的順序解析。

.PARAMETER Confirmed
    你已經看過對方留下了什麼，確定要替它收工。沒帶就只顯示，不動手。

.OUTPUTS
    exit 0 = 代理收工完成；1 = 失敗；2 = 停下來了，需要你決定或處理。
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$DriveRoot,
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

    $device = $env:COMPUTERNAME
    # 這台裝置的持久識別（票 26）。跟 startup.ps1／shutdown.ps1 同一個道理。
    $deviceIdentity = Get-DeviceIdentity -ListPath $ListPath
    # 只用來標記「這一次代理收工」，讓稽核紀錄（releasedBy）分得出是哪一次執行留下的
    # ——跟 shutdown.ps1 同一個模式。
    $sessionId = [guid]::NewGuid().ToString()
    $linkPath = Join-Path $ProjectRoot $script:DriveLinkName
    # 斷掉的 junction（目標消失、Drive 沒掛載、磁碟機代號變了）在 Test-Path 底下
    # 仍然回 True，必須連目標一起驗證才算「掛載著」（唯讀審查第三輪第 1 條）。
    if (-not (Test-DriveLinkMounted -Path $linkPath)) {
        Write-Host "$($script:DriveLinkName)/ 沒有掛載，讀不到租約。先執行開工。"
        exit $script:ExitNeedsYou
    }

    # --- 身分一致性（ADR-0007 不變量 9）------------------------------------
    # 在讀租約、併入對方進度、釋放租約之前檢查。
    $identity = Confirm-IdentityConsistency -ProjectRoot $ProjectRoot -Manifest $manifest -ProjectDrivePath $linkPath
    foreach ($line in $identity.Messages) { Write-Host $line }
    if ($identity.Blocked) { exit $identity.ExitCode }

    # --- 誰的租約（P1：依軸一分類分流，ADR-0006）----------------------------
    $lease = Read-Lease -ProjectRoot $ProjectRoot
    $leaseState = Get-LeaseState -Lease $lease -ProjectRoot $ProjectRoot -Manifest $manifest -Identity $deviceIdentity

    if ($leaseState -eq 'none' -or $leaseState -eq 'released') {
        Write-Host "現在沒有人持有租約，沒有誰需要被代理收工。"
        exit $script:ExitOk
    }
    if ($leaseState -eq 'unreadable') {
        Write-Host "停下來了：租約檔存在但無法解析（讀不動），可能還在同步中、暫時讀不到，也可能是內容損毀。"
        Write-Host "讀不動的租約分不出持有者是誰，不提供代理收工——它的第一步是釋放，會銷毀唯一一份證據。"
        Write-Host "唯一的路是開工的明確覆寫：帶 -TakeOverLease 與 -TakeOverReason『理由』重跑開工。"
        exit $script:ExitNeedsYou
    }
    if ($leaseState -eq 'self') {
        Write-Host "這是你自己這台裝置（$device）的租約。"
        Write-Host "自己的工作用收工，不用代理收工。"
        exit $script:ExitNeedsYou
    }
    if ($leaseState -eq 'self-other-workdir') {
        $holderWorkdir = Get-PropertyOrDefault -InputObject $lease -Name 'holderWorkdir' -Default '（未記錄）'
        Write-Host "停下來了：這個專案的租約目前握在這台裝置的另一個工作目錄手上。"
        Write-Host "  另一個工作目錄：$holderWorkdir"
        Write-Host ""
        Write-Host "到那個目錄去執行收工。這裡不提供代理收工——那些未提交的變更就在同一顆硬碟上，"
        Write-Host "繞遠路從心跳分支撈只會拿到快照。"
        exit $script:ExitNeedsYou
    }
    if ($leaseState -eq 'foreign-project') {
        Write-Host "停下來了：租約的 projectUuid 與本機 manifest 不同——這個 Drive 目錄可能被另一個專案誤用了。"
        Write-Host "這不是所有權之爭，任何情況下都不代理收工。請確認 junction 指向的目標是不是對的。"
        exit $script:ExitNeedsYou
    }

    # 剩下的只有 'other'。
    $holder = Get-PropertyOrDefault -InputObject $lease -Name 'deviceName' -Default (Get-PropertyOrDefault -InputObject $lease -Name 'device' -Default '（未記錄）')
    $acquiredAt = Get-PropertyOrDefault -InputObject $lease -Name 'acquiredAt' -Default '未記錄'
    $mainline = Get-CurrentBranch -ProjectRoot $ProjectRoot

    # P2：心跳分支一律用租約記的 heartbeatRef，不由裝置名重算——命名規則會變
    # （票 26），持有者寫下的名字是唯一權威。租約沒有這個欄位（v1）才退回重算。
    $leaseHeartbeatRef = Get-PropertyOrDefault -InputObject $lease -Name 'heartbeatRef' -Default ''
    $heartbeatBranchName = if ($leaseHeartbeatRef) { $leaseHeartbeatRef } else { Get-LegacyHeartbeatBranchName -Device $holder }

    # 對方的心跳是推到遠端的，先抓下來才看得到。
    if (Test-HasRemote -ProjectRoot $ProjectRoot) {
        Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('fetch', '--quiet', 'origin') | Out-Null
    }

    $heartbeat = Get-HeartbeatBranchInfo -ProjectRoot $ProjectRoot -Device $holder -Ref $leaseHeartbeatRef

    # --- 先讓使用者看見對方留下了什麼 -------------------------------------
    Write-Host "代理收工：$holder"
    Write-Host "  租約取得於 ：$acquiredAt"
    if ($heartbeat.Found) {
        Write-Host "  心跳分支   ：$($heartbeat.Ref)"
        Write-Host "  最後一筆   ：$($heartbeat.LastCommit)"
        Write-Host "  比主線多   ：$($heartbeat.AheadCount) 筆"
        $stat = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('diff', '--stat', "$mainline...$($heartbeat.Ref)")
        if ($stat.ExitCode -eq 0 -and $stat.Output) {
            Write-Host ""
            Write-Host "  它動過的東西："
            foreach ($line in ($stat.Output -split "`n")) { Write-Host "    $($line.Trim())" }
        }
    } else {
        Write-Host "  心跳分支   ：$($heartbeat.Ref) 不存在"
        Write-Host ""
        Write-Host "  它的心跳從沒跑過，或已經停擺。這代表代理收工**只能釋放租約**——"
        Write-Host "  那台機器上沒提交的變更還困在那裡，這裡拿不回來。"
        Write-Host "  等它自己開機收工，才拿得到那些東西。"
    }

    if (-not $Confirmed) {
        Write-Host ""
        Write-Host "還沒有動手。確定要替 $holder 收工，加上 -Confirmed 重跑。"
        exit $script:ExitNeedsYou
    }

    # --- 動手 -------------------------------------------------------------
    $status = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('status', '--porcelain')
    if ($status.Output) {
        Write-Host ""
        Write-Host "停下來了：你自己的工作區還有未提交的變更。"
        Write-Host "代理收工要把對方的進度併進主線，需要乾淨的工作區才安全。"
        Write-Host "先把自己的東西提交掉（或執行收工），再回來。"
        exit $script:ExitNeedsYou
    }

    $mergeState = 'no-heartbeat'
    if ($heartbeat.Found) {
        # --squash：把對方的進度收成一筆，而不是把心跳的零碎快照全部搬進主線歷史。
        $merge = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('merge', '--squash', $heartbeat.Ref)
        if ($merge.ExitCode -ne 0) {
            Write-Host ""
            Write-Host "停下來了：併入時發生衝突，代理收工不會替你決定怎麼解。"
            Write-Host "解完之後自己 commit，租約再跑一次代理收工釋放。"
            exit $script:ExitNeedsYou
        }

        $message = "chore(代理收工): $holder ← $device $((Get-Date).ToString('yyyy-MM-dd'))"
        $commit = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('commit', '-m', $message)
        $mergeState = if ($commit.ExitCode -eq 0) { 'merged' } else { 'already-in-mainline' }
    }

    $pushState = 'no-remote'
    if (Test-HasRemote -ProjectRoot $ProjectRoot) {
        $push = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('push', 'origin', "${mainline}:${mainline}")
        $pushState = if ($push.ExitCode -eq 0) { 'pushed' } else { "failed" }
    }

    # 收掉對方的心跳分支——它已經被收進主線了，留著會讓下一次開工誤判成還有未完成的工作。
    # P2：刪的也是租約記的那條，跟上面找到它用的是同一個來源。
    if ($heartbeat.Found -and $pushState -ne 'failed') {
        $localRef = "refs/heads/$heartbeatBranchName"
        if (Get-RefCommit -ProjectRoot $ProjectRoot -Ref $localRef) {
            Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('update-ref', '-d', $localRef) | Out-Null
        }
        if (Test-HasRemote -ProjectRoot $ProjectRoot) {
            Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('push', 'origin', '--delete', $heartbeatBranchName) | Out-Null
        }
    }

    # 釋放前重讀一次並重判軸一（唯讀審查第 8 條）：$lease 是行程一開始讀的那一份，
    # 中間隔著 fetch／merge --squash／commit／push 三個網路與磁碟動作，秒到分鐘等級
    # ——這段時間裡持有者可能自己回來收工並釋放、另一台隨即取得。用那份陳舊物件
    # 直接覆寫，等於把新持有者的 held 租約整份換成舊持有者的內容加 released，
    # 一個位元組都不屬於現在的持有者（比照 D 段撤回語義的 compare-then-act，
    # 不是「讀到什麼就寫什麼」）。
    #
    # 測試接縫：HYBRID_TEST_PAUSE_BEFORE_PROXY_RELEASE_MS，在重讀之前先停一下，
    # 跟 Confirm-LeaseHeld 的 HYBRID_TEST_PAUSE_BEFORE_CONFIRM_MS 同一個手法。
    if ($env:HYBRID_TEST_PAUSE_BEFORE_PROXY_RELEASE_MS) {
        Start-Sleep -Milliseconds ([int]$env:HYBRID_TEST_PAUSE_BEFORE_PROXY_RELEASE_MS)
    }
    $recheckLease = Read-Lease -ProjectRoot $ProjectRoot
    $recheckState = Get-LeaseState -Lease $recheckLease -ProjectRoot $ProjectRoot -Manifest $manifest -Identity $deviceIdentity
    $originalSessionId = Get-PropertyOrDefault -InputObject $lease -Name 'sessionId' -Default ''
    $sameHolder = $false
    if ($recheckState -eq 'other') {
        $recheckSessionId = Get-PropertyOrDefault -InputObject $recheckLease -Name 'sessionId' -Default ''
        if ($originalSessionId -and $recheckSessionId) {
            $sameHolder = ($originalSessionId -eq $recheckSessionId)
        } else {
            # v1 租約沒有 sessionId，退回比裝置名——跟 Get-LeaseState 判 self 用的
            # 同一種退化。
            $recheckHolder = Get-PropertyOrDefault -InputObject $recheckLease -Name 'deviceName' -Default (Get-PropertyOrDefault -InputObject $recheckLease -Name 'device' -Default '')
            $sameHolder = ($holder -and $recheckHolder -and ($holder -eq $recheckHolder))
        }
    }

    if (-not $sameHolder) {
        $mergeDoneLabel = switch ($mergeState) {
            'merged'              { "已壓成一筆併入 $mainline" }
            'already-in-mainline' { '它的進度早就在主線上了' }
            'no-heartbeat'        { '沒有心跳分支可以取回' }
            default               { $mergeState }
        }
        Write-Host ""
        Write-Host "停下來了：代理收工期間租約換人了。"
        Write-Host "  原本要釋放的持有者：$holder"
        Write-Host "  現在的租約狀態    ：$recheckState"
        Write-Host ""
        Write-Host "$holder 的進度已經併進主線，git 那邊的動作（$mergeDoneLabel）已經完成，不會回滾。"
        Write-Host "但租約沒有被這次代理收工釋放——現在 Drive 上的租約可能已經是別台重新取得的那一份，不能覆蓋它。"
        exit $script:ExitNeedsYou
    }

    # 釋放對方的租約。用重讀到的這一份寫，不是行程一開始讀的那份——保留期間可能
    # 疊加上去的其他欄位。releasedByDevice 記的是這台裝置，所以事後看得出是誰替誰收的。
    Set-LeaseReleased -ProjectRoot $ProjectRoot -Lease $recheckLease -SessionId $sessionId -Identity $deviceIdentity | Out-Null

    # --- 回報 -------------------------------------------------------------
    $mergeLabel = switch ($mergeState) {
        'merged'              { "已壓成一筆併入 $mainline" }
        'already-in-mainline' { '它的進度早就在主線上了，沒有新東西' }
        'no-heartbeat'        { '沒有心跳分支可以取回——只釋放了租約' }
        default               { $mergeState }
    }
    $pushLabel = switch ($pushState) {
        'pushed'    { '已推送' }
        'no-remote' { '沒有 remote，略過' }
        'failed'    { '推送失敗' }
        default     { $pushState }
    }

    Write-Host ""
    Write-Host "代理收工完成"
    Write-Host "  替       ：$holder 收的"
    Write-Host "  它的進度 ：$mergeLabel"
    Write-Host "  主線     ：$mainline（$pushLabel）"
    Write-Host "  租約     ：已釋放（紀錄裡留著 releasedByDevice = $device）"

    if (-not $heartbeat.Found) {
        Write-Host ""
        Write-Host "再說一次：$holder 上沒提交的變更沒有被取回，它們還在那台機器上。"
    }
    if ($pushState -eq 'failed') {
        Write-Host ""
        Write-Host "主線沒有推上去，別台裝置還拿不到。處理完推送再說。"
        exit $script:ExitNeedsYou
    }

    exit $script:ExitOk
}
catch {
    Write-Host "代理收工失敗：$($_.Exception.Message)"
    exit $script:ExitFailed
}
