<#
.SYNOPSIS
    收工：把這次工作階段的成果送出去，釋放租約，並給出明確結論。

.DESCRIPTION
    一次工作階段在歷史上對應一筆紀錄——心跳分支上那些零碎的快照壓成單一 commit
    併進主線。訊息格式固定，之後看歷史時分得出哪些是機器產生的。

    最後一步是 Drive 同步確認。依 CONTEXT.md 的定義，Drive 的完成時點無法由程式
    可靠觀測，所以這裡停下來問人——這是設計而非缺陷。確認過就帶 -DriveSynced 重跑，
    腳本不會替你假設。

.PARAMETER ProjectRoot
    專案在本機的位置。預設為目前目錄。

.PARAMETER DriveRoot
    Drive 端的根目錄。省略時依「本機設定檔 → 自動偵測」的順序解析。

.PARAMETER DriveSynced
    你已經確認 Google Drive 同步完成。給了才可能得到「可以換裝置」的結論。

.PARAMETER Override
    preflight 擋下東西時，一次性放行這一次收工（ADR-0005）。必須搭配 -OverrideReason；
    不寫入任何 allowlist，只留下這一次的稽核紀錄。_drive/ 那一條不受這個參數影響
    ——它從來不是 preflight 政策的一部分，不可 override。

.PARAMETER OverrideReason
    -Override 的理由，必填、不可空白（只有空白字元也不行——包括全形空白）。

.OUTPUTS
    exit 0 = 可以換裝置；1 = 失敗；2 = 尚不可換裝置（卡在需要你處理的事情上）。
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$DriveRoot,
    [string]$ListPath,
    [switch]$DriveSynced,
    [switch]$Override,
    [string]$OverrideReason
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $OutputEncoding

. (Join-Path $PSScriptRoot 'lib\paths.ps1')
. (Join-Path $PSScriptRoot 'lib\junction.ps1')
. (Join-Path $PSScriptRoot 'lib\lease.ps1')
. (Join-Path $PSScriptRoot 'lib\git.ps1')
. (Join-Path $PSScriptRoot 'lib\preflight.ps1')
. (Join-Path $PSScriptRoot 'lib\health.ps1')

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
    # 在任何破壞性動作之前把 projectId 取出來——manifest 讀不動的情況已經在上面擋掉，
    # 這裡只是不讓 $manifest 的存取散落在 commit／push／釋放租約之後（唯讀審查第 1 條）。
    $projectId = [string]$manifest.projectId

    $device = $env:COMPUTERNAME
    # 這台裝置的持久識別（票 26）。跟 startup.ps1 同一個道理：算一次全程共用，
    # 不要在每個呼叫點各自重新呼叫 Get-DeviceIdentity。
    $deviceIdentity = Get-DeviceIdentity -ListPath $ListPath
    # 只用來標記「這一次收工」，讓 override 的稽核紀錄分得出是哪一次執行留下的
    # ——這個 repo 目前沒有其他地方需要跨行程共享的 session 概念（那是票 22 的範圍）。
    $sessionId = [guid]::NewGuid().ToString()
    $linkPath = Join-Path $ProjectRoot $script:DriveLinkName
    # 斷掉的 junction（目標消失、Drive 沒掛載、磁碟機代號變了）在 Test-Path 底下
    # 仍然回 True，必須連目標一起驗證才算「掛載著」（唯讀審查第三輪第 1 條）。
    $driveMounted = Test-DriveLinkMounted -Path $linkPath
    $blockers = @()

    # --- 身分一致性（ADR-0007 不變量 9）------------------------------------
    # 在 commit／push／釋放租約之前檢查。沒有掛載就沒有 Drive 端可比對——那種情況
    # 下面的 $blockers 機制本來就會擋掉 Write-DriveOrigin 與釋放租約，不需要在這裡
    # 猜一個掛載點出來比對。
    if ($driveMounted) {
        $identity = Confirm-IdentityConsistency -ProjectRoot $ProjectRoot -Manifest $manifest -ProjectDrivePath $linkPath
        foreach ($line in $identity.Messages) { Write-Host $line }
        if ($identity.Blocked) { exit $identity.ExitCode }
    }

    Assert-DriveLinkIgnored -ProjectRoot $ProjectRoot

    # --- 壓縮並併進主線 ---------------------------------------------------
    $mainline = Get-CurrentBranch -ProjectRoot $ProjectRoot

    # 遠端動過的話，在**動手之前**就停。
    #
    # 不擋的話會發生這串：commit 疊在舊的主線上 → 推送被 git 以 non-fast-forward
    # 拒絕（東西一樣沒送出去）→ 但本機主線從此分岔 → 連下一次開工的 pull --ff-only
    # 都失敗。使用者什麼也沒得到，卻多了一個要手工解的結。
    #
    # 收工本身不拉取——那是開工的職責，而且拉下來的東西使用者還沒看過就被收工
    # 一起送出去並不合適。所以這裡只停下來，請他去跑開工。
    if (Test-HasRemote -ProjectRoot $ProjectRoot) {
        Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('fetch', '--quiet', 'origin') | Out-Null
        $behind = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('rev-list', '--count', "$mainline..origin/$mainline")
        if ($behind.ExitCode -eq 0 -and [int]$behind.Output -gt 0) {
            Write-Host "停下來了：遠端的 $mainline 有 $($behind.Output) 筆是這台還沒有的。"
            Write-Host ""
            Write-Host "別台裝置在你這次工作期間推了東西上去。現在收工的話推不上去，"
            Write-Host "而且會讓這台的主線分岔，之後連開工都拉不動。"
            Write-Host ""
            Write-Host "先執行開工把那些拉下來，再收工一次。你的工作區不會被動到——"
            Write-Host "開工只拉取，不碰你還沒提交的東西。"
            exit $script:ExitNeedsYou
        }
    }
    $branch = Get-HeartbeatBranchName -DeviceId $deviceIdentity.DeviceId -ProjectRoot $ProjectRoot
    $wipRef = "refs/heads/$branch"
    $wipCommit = Get-RefCommit -ProjectRoot $ProjectRoot -Ref $wipRef

    $wipAhead = 0
    if ($wipCommit -and (Test-HasCommits -ProjectRoot $ProjectRoot)) {
        $count = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('rev-list', '--count', "$mainline..$wipRef")
        if ($count.ExitCode -eq 0) { $wipAhead = [int]$count.Output }
    }

    $status = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('status', '--porcelain')
    $isDirty = [bool]$status.Output

    $commitState = 'nothing'
    if ($isDirty) {
        # --- preflight（ADR-0005）------------------------------------------
        # 前景執行，人就在旁邊：阻擋 = 停下來、印出問題檔案、exit 2。工作區在這裡
        # 完全沒被動到——preflight 本身唯讀，下面的 git add -A 還沒跑到。
        $preflightPolicy = Read-PreflightPolicy -ProjectRoot $ProjectRoot
        $preflightScan = Invoke-PreflightScan -ProjectRoot $ProjectRoot -Policy $preflightPolicy
        if ($preflightScan.Blocked -and -not $Override) {
            Write-Host "停下來了：preflight 擋下了下面這些檔案。"
            Write-Host ""
            foreach ($finding in $preflightScan.BlockingFindings) {
                Write-Host "  * [$($finding.Rule)] $($finding.File)"
                Write-Host "    $($finding.Message)"
            }
            Write-Host ""
            Write-Host "工作區沒有被動到。處理掉這些檔案後重跑；如果確定要放行，"
            Write-Host "帶 -Override 與 -OverrideReason『理由』重跑（一次性，會留下稽核紀錄）。"
            exit $script:ExitNeedsYou
        }
        # 用 IsNullOrWhiteSpace，不是 `-not $OverrideReason`。PowerShell 裡 "   " 是
        # truthy，所以舊寫法讓三個空格穿過去——真機演練時實際發生過，而那三個空格
        # 被永久寫進了稽核紀錄。
        #
        # 這不是龜毛的參數驗證：這個參數存在的唯一理由，是強迫放行的人說出他為什麼
        # 認為這樣可以，而那句話是留給未來讀稽核紀錄的人看的。空白滿足語法、產生一筆
        # 合法紀錄、通過所有檢查，**而且它是最省力的路徑**——趕時間的人不會編理由，
        # 他會找最短的能過的字串。要求在最容易走的那條路上等於不存在。
        if ($preflightScan.Blocked -and $Override -and [string]::IsNullOrWhiteSpace($OverrideReason)) {
            Write-Host "停下來了：-Override 要搭配 -OverrideReason 說明理由，不能空白。"
            exit $script:ExitNeedsYou
        }
        $overriddenFiles = @()
        if ($preflightScan.Blocked -and $Override) {
            $overriddenFiles = @($preflightScan.BlockingFindings | ForEach-Object { $_.File } | Select-Object -Unique)
            Write-Host "警告：以下阻擋被 -Override 放行（理由：$OverrideReason）："
            foreach ($finding in $preflightScan.BlockingFindings) { Write-Host "  * [$($finding.Rule)] $($finding.File)" }
        }
        foreach ($warning in $preflightScan.Warnings) { Write-Host "警告：$warning" }

        # 收工以工作區為準：心跳分支上那些快照本來就是同一個工作區的中間狀態，
        # 最終要留在歷史上的是使用者收手時的樣子。
        $stage = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('add', '-A')
        if ($stage.ExitCode -ne 0) { throw "stage 失敗：$($stage.Output)" }

        $message = "chore(收工): $device $((Get-Date).ToString('yyyy-MM-dd'))"
        $commit = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('commit', '-m', $message)
        if ($commit.ExitCode -ne 0) { throw "commit 失敗：$($commit.Output)" }
        $commitState = 'committed'

        if ($overriddenFiles.Count -gt 0) {
            # 稽核紀錄要能填 commitSha（ADR-0005：連結果都要留痕），所以只能在上面那筆
            # commit 產生之後才寫。紀錄本身另外併一筆小 commit——「紀錄要進版控」
            # （票 20 決策表）沒辦法讓紀錄自己包含自己的雜湊，這是唯一不循環的做法。
            $workCommitSha = Get-RefCommit -ProjectRoot $ProjectRoot -Ref 'HEAD'
            Add-PreflightOverrideRecord -ProjectRoot $ProjectRoot -Flow 'shutdown' -SessionId $sessionId `
                -Files $overriddenFiles -Reason $OverrideReason -CommitSha $workCommitSha | Out-Null
            $auditStage = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('add', '--', '.hybrid/preflight-override-log.jsonl')
            if ($auditStage.ExitCode -ne 0) { throw "稽核紀錄 stage 失敗：$($auditStage.Output)" }
            $auditMessage = "chore(preflight-override 稽核): $device $((Get-Date).ToString('yyyy-MM-dd'))"
            $auditCommit = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('commit', '-m', $auditMessage)
            if ($auditCommit.ExitCode -ne 0) { throw "稽核紀錄 commit 失敗：$($auditCommit.Output)" }
        }
    }

    # --- 推送主線 ---------------------------------------------------------
    $pushState = 'no-remote'
    if (Test-HasRemote -ProjectRoot $ProjectRoot) {
        if (-not (Test-HasCommits -ProjectRoot $ProjectRoot)) {
            $pushState = 'no-commits'
        } else {
            $push = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('push', 'origin', "${mainline}:${mainline}")
            if ($push.ExitCode -eq 0) {
                $pushState = 'pushed'
            } else {
                $pushState = 'failed'
                $blockers += "主線沒有推上去：$($push.Output)"
            }
        }
    }

    # --- 收掉心跳分支 -----------------------------------------------------
    # 留著的話，下一台裝置開工會看到一條其實已經收完的心跳分支，誤判成有未完成的工作。
    if ($wipCommit -and $pushState -ne 'failed') {
        Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('update-ref', '-d', $wipRef) | Out-Null
        if (Test-HasRemote -ProjectRoot $ProjectRoot) {
            Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('push', 'origin', "--delete", $branch) | Out-Null
        }
    }

    # --- 釋放租約 ---------------------------------------------------------
    # 租約住在 _drive/ 裡，沒掛載就寫不到。這種情況下 git 那邊已經收好了，
    # 但狀態沒回到乾淨，所以要算成一個卡點。
    #
    # 釋放前先判所有權（ADR-0006 段落 E；不變量 11c）：self 才釋放；其餘（別台持有、
    # 同一台裝置的另一個工作目錄持有、讀不動、掛錯目錄）一律不釋放，列為 blocker
    # 並指名現在的持有者是誰——這是整套系統裡唯一能發現「開工之後租約被別台覆蓋」
    # 的位置。git 那邊（commit、push、收心跳分支）已經照常完成，租約的問題只影響
    # 「可以換裝置」這個結論，不影響上面已經做完的事。
    $leaseState = 'skipped'
    $leaseHolderLabel = ''
    if ($driveMounted) {
        $lease = Read-Lease -ProjectRoot $ProjectRoot
        $axis1 = Get-LeaseState -Lease $lease -ProjectRoot $ProjectRoot -Manifest $manifest -Identity $deviceIdentity
        if ($axis1 -eq 'none' -or $axis1 -eq 'released') {
            $leaseState = 'none'
        } elseif ($axis1 -eq 'self') {
            # 票 34：**沒確認同步就不放**。
            #
            # 租約保護的不是 git（git 會 merge），是 _drive/ 底下那個唯一的、不可 merge
            # 的實體。而 -DriveSynced 存在的唯一理由，就是「同步完成」只有人看得到。
            # 在人確認之前釋放租約，等於在唯一能判斷安全的訊號到達之前開放那個資源。
            #
            # 舊順序（先放、後檢查）留下的中間狀態不留痕跡：git 已推、工作區乾淨、
            # 租約 released——跟一個完整跑完兩段的收工在檔案上完全相同，沒有任何欄位
            # 記錄「同步尚未確認」。使用者看到 exit 2 以為失敗而放棄，下一台看到的是
            # 一個乾淨、可以接手的專案，而 Drive 可能正在傳一半（ADR-0006 開頭第 2 點：
            # 那個狀態不會產生任何錯誤訊息）。
            #
            # 代價是忘記跑第二段的人會讓租約留著、別台被擋。那個「被擋」有三層機制
            # 接住（代理收工、expiresAt 到期、判活降級時的阻擋訊息）而且會發出聲音；
            # 提前釋放造成的靜默中間狀態一層都沒有。兩種失敗的代價不對稱。
            if ($DriveSynced) {
                Set-LeaseReleased -ProjectRoot $ProjectRoot -Lease $lease -SessionId $sessionId -Identity $deviceIdentity | Out-Null
                $leaseState = 'released'
            } else {
                # 標記「正在收工」——git 已經推上去了，只差人確認 Drive 同步。
                # 這讓接手的一方分得出「對方正在收工」與「對方忘記收工」：
                # 前者的 git 那半是安全的，代理收工不必警告「拿不回未提交的變更」。
                Set-LeaseReleasing -ProjectRoot $ProjectRoot -Lease $lease | Out-Null
                $leaseState = 'held-pending-sync'
            }
        } else {
            $leaseState = $axis1
            $leaseHolderLabel = switch ($axis1) {
                'unreadable'          { '租約讀不動，看不出是誰' }
                'self-other-workdir'  { "這台裝置的另一個工作目錄（$(Get-PropertyOrDefault -InputObject $lease -Name 'holderWorkdir' -Default '未記錄')）" }
                'foreign-project'     { '租約屬於別的專案（projectUuid 不同）' }
                default               { Get-PropertyOrDefault -InputObject $lease -Name 'deviceName' -Default (Get-PropertyOrDefault -InputObject $lease -Name 'device' -Default '（未記錄）') }
            }
            $blockers += "租約沒有釋放——現在持有的是：$leaseHolderLabel。你開工之後它可能被覆蓋了，這段期間兩台可能都寫過 $($script:DriveLinkName)/，Drive 那一層沒有版本可以回溯，請自己確認一次。"
        }
    } else {
        $blockers += "$($script:DriveLinkName)/ 沒有掛載，租約沒有釋放。先執行開工，再收工一次。"
    }

    # 更新 Drive 端的指標檔。remote 通常是收工這一刻才第一次存在的，所以這裡補比
    # 初始化時補更有機會補到。走 junction 寫，實體就落在 Drive 上那個專案資料夾。
    #
    # 回傳值是「這次寫入前是不是接手了一個上次斷電留下的 .writing 暫存檔」——
    # 不變量 5(b) 要求把接手的半成品說出來，不能悶掉（D3；同 startup.ps1 的手法）。
    $resumedOriginPartial = $false
    if ($driveMounted) {
        $remoteNow = ''
        if (Test-HasRemote -ProjectRoot $ProjectRoot) {
            $probe = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('remote', 'get-url', 'origin')
            if ($probe.ExitCode -eq 0) { $remoteNow = $probe.Output }
        }
        # 把這一次推送的結果一起記下來（票 39）。'pushed' 是成功、'failed' 是失敗；
        # 'no-remote' / 'no-commits' 是「根本沒有推送這件事」，那不該記成失敗。
        $pushOkForOrigin = $null
        if ($pushState -eq 'pushed') { $pushOkForOrigin = $true }
        elseif ($pushState -eq 'failed') { $pushOkForOrigin = $false }
        $resumedOriginPartial = Write-DriveOrigin -ProjectDrivePath $linkPath -ProjectId $projectId `
            -LastPushOk $pushOkForOrigin `
            -Remote $remoteNow -MainBranch $mainline -DisplayName (Split-Path -Leaf $ProjectRoot)
    }

    # --- Drive 同步確認 ---------------------------------------------------
    # 依 CONTEXT.md：Drive 的完成時點無法由程式可靠觀測。所以不猜，問人。
    if (-not $DriveSynced) {
        $blockers += "還沒確認 Google Drive 同步完成。確認後加上 -DriveSynced 重跑（那時已經沒有東西要提交，很快）。"
    }

    # --- 回報 -------------------------------------------------------------
    $commitLabel = switch ($commitState) {
        'committed' { "已壓成一筆併入 $mainline" }
        'nothing'   { '工作區乾淨，沒有東西需要提交' }
        default     { $commitState }
    }
    $pushLabel = switch ($pushState) {
        'pushed'     { '已推送' }
        'no-remote'  { '沒有 remote，略過' }
        'no-commits' { '還沒有任何 commit，略過' }
        'failed'     { '推送失敗' }
        default      { $pushState }
    }
    # D2：租約那一行要說出持有者是誰，不能只說「已釋放」。
    $leaseLabel = switch ($leaseState) {
        'released'          { '已釋放' }
        # 這一行要講清楚「還握著」以及「在等什麼」。說「已釋放」會讓人以為可以換裝置了；
        # 只說「沒有釋放」又會讓人以為出錯了——它既沒出錯，也還沒完成。
        'held-pending-sync' { '仍持有（等你確認 Drive 同步完成後才釋放）' }
        'none'              { '本來就沒有人持有' }
        'skipped'           { '沒有掛載，無法釋放' }
        default             { "沒有釋放——持有的是：$leaseHolderLabel" }
    }

    Write-Host "收工"
    Write-Host "  裝置       ：$device"
    Write-Host "  本次變更   ：$commitLabel"
    if ($wipCommit) {
        Write-Host "  心跳分支   ：$branch 有 $wipAhead 筆，已收掉"
    } else {
        Write-Host "  心跳分支   ：不存在（沒有背景排程也能收工）"
    }
    Write-Host "  主線       ：$mainline（$pushLabel）"
    Write-Host "  租約       ：$leaseLabel"
    # 票 28（驗收條件第三條）：不需要事件檢視器就知道心跳有沒有停擺。健康時只印
    # 一行，出事才多印——跟 startup.ps1 共用同一份 Get-ProjectHealthSummaryLines，
    # 不是各自兜一份格式化邏輯（這個 repo 已經被兩份 SKILL.md 走岔咬過一次）。
    try {
        $healthLines = @(Get-ProjectHealthSummaryLines -ProjectRoot $ProjectRoot -ListPath $ListPath)
        Write-Host "  心跳健康   ：$($healthLines[0])"
        for ($i = 1; $i -lt $healthLines.Count; $i++) { Write-Host "               $($healthLines[$i])" }
    } catch {
        Write-Host "  心跳健康   ：讀取失敗（$($_.Exception.Message)）"
    }
    if ($resumedOriginPartial) {
        Write-Host "  注意       ：origin.json 有上次寫到一半就中斷的暫存檔（可能是斷電或行程被砍），"
        Write-Host "               已接手並重新完整寫入（ADR-0007 不變量 5）。"
    }

    if ((-not $isDirty) -and $wipAhead -gt 0) {
        Write-Host ""
        Write-Host "提醒：工作區沒有未提交的變更，但心跳分支上有 $wipAhead 筆。"
        Write-Host "收工以工作區為準——如果你 stash 或還原過什麼，那些內容不會進主線。"
    }

    Write-Host ""
    if ($blockers.Count -eq 0) {
        Write-Host "結論：可以換裝置。"
        exit $script:ExitOk
    }

    Write-Host "結論：尚不可換裝置。卡在："
    foreach ($blocker in $blockers) { Write-Host "  * $blocker" }
    exit $script:ExitNeedsYou
}
catch {
    Write-Host "收工失敗：$($_.Exception.Message)"
    exit $script:ExitFailed
}
