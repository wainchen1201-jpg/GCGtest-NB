# 租約：讀寫住在 _drive/ 根目錄的租約檔。
#
# v2（ADR-0006）：租約預設阻擋別台裝置的可寫開工，不再是一塊純粹「誰在做」的看板。
# 這支檔案只提供讀寫與軸一（所有權）分類——軸二（存活判定，需要 fetch 與 git 時間軸）
# 是各呼叫端自己的事，見 ADR-0006「A. 所有權與存活是兩個軸，不要併成一個 switch」。
#
# 它住在 _drive/ 裡面，這件事鎖死了開工的步驟順序：junction 沒建好就讀不到租約。

Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'paths.ps1')
. (Join-Path $PSScriptRoot 'git.ps1')
. (Join-Path $PSScriptRoot 'registry.ps1')

function Get-LeasePath {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    return (Join-Path (Join-Path $ProjectRoot $script:DriveLinkName) 'lease.json')
}

function Get-DeviceIdentity {
    # 持久裝置識別（不受重灌影響，票 26）+ 人看的裝置名。所有寫入租約、比對租約、
    # 算心跳分支名的地方都要經過這個函式，不要在別處直接讀 $env:COMPUTERNAME
    # 寫進租約或另外鑄一顆 id（ADR-0006 欄位表：deviceId／deviceName）。
    #
    # -ListPath：跟 projects.json／runtime 同一個接縫（不變量 13）——測試傳暫存
    # 路徑，絕不能落到這台機器真實的 %LOCALAPPDATA%\hybrid-workspace\device.json。
    param([string]$ListPath)
    return [pscustomobject]@{
        DeviceId   = (Get-OrCreatePersistentDeviceId -ListPath $ListPath)
        DeviceName = $env:COMPUTERNAME
    }
}

function Read-Lease {
    # 三態回傳，跟 Read-DriveOrigin／Read-ProjectManifest 同一個道理：檔案不存在
    # → $null；存在但解析失敗（同步中的殘檔、部分寫入、損毀）→ New-UnreadableMarker；
    # 解析成功 → 物件，**不論 status 是什麼**。分類「這代表什麼」是 Get-LeaseState
    # 的事，這裡不吞任何一種狀態——舊版把「已釋放」跟「沒有租約」混成同一個 $null，
    # 讀取端因此分不出「安全接手」跟「這裡曾經有人」（ADR-0006）。
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $path = Get-LeasePath -ProjectRoot $ProjectRoot
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $lease = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return (New-UnreadableMarker)
    }
    return $lease
}

function Get-LeaseState {
    # 軸一：所有權判定。純粹比對欄位，不碰 git、不看時鐘、不需要網路
    # （ADR-0006「A. 所有權與存活是兩個軸」）。
    #
    # 回傳 unreadable / none / released / foreign-project / self / self-other-workdir / other。
    #
    # 裝置怎麼比：兩邊都有 deviceId 就比 deviceId，任一邊沒有就比 deviceName
    # （v1 租約的欄位叫 device，也走 deviceName 這一支）。
    # 工作目錄怎麼比：兩邊都經 Get-NormalisedPath 正規化，Windows 上不分大小寫。
    #
    # -Manifest 是本機 project.json 解析後的物件（可省略；省略或沒有 projectUuid
    # 時 foreign-project 這一格永遠判不出來，照 ADR-0006 C 段「其中一端沒有
    # projectUuid 就不阻擋」）。
    #
    # -Identity 是呼叫端已經算好的 Get-DeviceIdentity 回傳值（票 26）——這裡不自己
    # 呼叫 Get-DeviceIdentity，因為那需要 -ListPath 才能安全地在測試裡跑（不變量
    # 13），而 Get-LeaseState 的呼叫端太多、太深，硬要每一層都轉發 -ListPath
    # 不如讓呼叫端算好一次身分再傳進來。
    param(
        $Lease,
        [Parameter(Mandatory)][string]$ProjectRoot,
        $Manifest,
        [Parameter(Mandatory)]$Identity
    )

    if (Test-Unreadable $Lease) { return 'unreadable' }
    if (-not $Lease) { return 'none' }

    $status = Get-PropertyOrDefault -InputObject $Lease -Name 'status' -Default 'held'
    if ($status -ne 'held') { return 'released' }

    # C 段：這個檢查排在所有權判定之前——它抓的是「掛錯目錄」，不是「別台持有」，
    # 即使使用者帶了明確覆寫的理由也不能覆寫（那是呼叫端的事，這裡只負責分類）。
    $leaseUuid = Get-PropertyOrDefault -InputObject $Lease -Name 'projectUuid' -Default ''
    $localUuid = Get-PropertyOrDefault -InputObject $Manifest -Name 'projectUuid' -Default ''
    if ($leaseUuid -and $localUuid -and $leaseUuid -ne $localUuid) { return 'foreign-project' }

    $identity = $Identity
    $leaseDeviceId = Get-PropertyOrDefault -InputObject $Lease -Name 'deviceId' -Default ''
    $leaseDeviceNameFallback = Get-PropertyOrDefault -InputObject $Lease -Name 'device' -Default ''
    $leaseDeviceName = Get-PropertyOrDefault -InputObject $Lease -Name 'deviceName' -Default $leaseDeviceNameFallback

    if ($identity.DeviceId -and $leaseDeviceId) {
        $deviceMatches = ($identity.DeviceId -eq $leaseDeviceId)
    } else {
        $deviceMatches = ($identity.DeviceName -eq $leaseDeviceName)
    }
    if (-not $deviceMatches) { return 'other' }

    # v1 租約沒有 holderWorkdir，裝置相符時視為 self（ADR-0006 v1 相容段：分不出
    # 同一台裝置的兩個 clone，但這個盲點只到下一次續用把它升級成 v2 為止）。
    $leaseWorkdir = Get-PropertyOrDefault -InputObject $Lease -Name 'holderWorkdir' -Default ''
    if (-not $leaseWorkdir) { return 'self' }

    $normalisedLeaseWorkdir = Get-NormalisedPath $leaseWorkdir
    $normalisedProjectRoot = Get-NormalisedPath $ProjectRoot
    if ($normalisedLeaseWorkdir -ieq $normalisedProjectRoot) { return 'self' }
    return 'self-other-workdir'
}

function Write-LeaseAtomic {
    # 模組內部用：暫存檔 lease.json.writing → Move-Item -Force。比照 Write-DriveOrigin
    # （paths.ps1:167-178）。這是這支檔案裡唯一一處呼叫 Write-Utf8NoBom 寫進 Drive
    # 端路徑——其餘所有寫入（New-Lease／Undo-LeaseAcquisition／Set-LeaseReleased）
    # 都必須經過這裡，才滿足 ADR-0007 不變量 6。
    #
    # 回傳是否接手了上一次留下的半成品（.writing 殘檔）——不變量 5(b) 要求這件事
    # 被說出來，由呼叫端負責印出來。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$Record
    )
    $finalPath = Get-LeasePath -ProjectRoot $ProjectRoot
    $temp = "$finalPath.writing"
    $resumedStalePartial = Test-Path -LiteralPath $temp
    if ($resumedStalePartial) { Remove-Item -LiteralPath $temp -Force }
    Write-Utf8NoBom -Path $temp -Content (ConvertTo-Json $Record -Depth 6)
    Move-Item -LiteralPath $temp -Destination $finalPath -Force
    return $resumedStalePartial
}

function Set-LeaseProperty {
    # 只支援 PSCustomObject（Read-Lease 回傳的型別）。有這個屬性就直接賦值，沒有
    # 就 Add-Member——用在「保留原記錄全部欄位，疊加幾個新欄位」的場景
    # （Set-LeaseReleased、Undo-LeaseAcquisition），不逐欄位手寫一份新物件。
    param(
        [Parameter(Mandatory)]$Lease,
        [Parameter(Mandatory)][string]$Name,
        $Value
    )
    if ($Lease.PSObject.Properties[$Name]) {
        $Lease.$Name = $Value
    } else {
        $Lease | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function New-Lease {
    # 寫 v2 全欄位（ADR-0006「租約 v2 的欄位」表）。firstAcquiredAt 只有在呼叫端明確
    #帶 -Reuse（軸一判定為 self，也就是「續用」）時才沿用舊值；其餘情況（none／
    # released／明確覆寫）一律以這次的 acquiredAt 為起點——「續用就是重新取得」
    # 只在真的是續用的時候才成立（B 段），覆寫是搶別人的東西，不是延續自己的持有
    # （唯讀審查第 4 條：舊寫法無條件從「任何讀得動的既有租約」繼承，讓覆寫之後的
    # 租約謊稱自己從被覆寫那台裝置取得的那一刻起連續持有至今）。其餘欄位全部重新
    # 產生：心跳分支的判活基準要跟著這一次的主線位置走，不變量 10 也要求每次狀態
    # 轉換都要有新的時間戳。只寫，不覆核；覆核是 Confirm-LeaseHeld 的事。
    #
    # -Overridden* 四個參數只在明確覆寫時由呼叫端傳入，寫進 ADR-0006 欄位表列的
    # overriddenAt／overriddenBy／overriddenReason／overriddenLease（唯讀審查第 9
    # 條）。不覆寫時四者都省略，租約上不會出現這四個欄位。
    #
    # -Identity 是呼叫端已經算好的 Get-DeviceIdentity 回傳值（票 26；理由同
    # Get-LeaseState 的 -Identity 參數註解）。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Identity,
        [switch]$Reuse,
        [string]$OverriddenAt,
        [string]$OverriddenBy,
        [string]$OverriddenReason,
        $OverriddenLease
    )

    $manifest = Read-ProjectManifest -ProjectRoot $ProjectRoot
    $projectUuid = Get-PropertyOrDefault -InputObject $manifest -Name 'projectUuid' -Default ''
    $identity = $Identity

    $existing = Read-Lease -ProjectRoot $ProjectRoot
    $now = Get-Date
    $acquiredAt = $now.ToString('yyyy-MM-ddTHH:mm:sszzz')
    $firstAcquiredAt = $acquiredAt
    if ($Reuse -and $existing -and -not (Test-Unreadable $existing)) {
        $existingFirst = Get-PropertyOrDefault -InputObject $existing -Name 'firstAcquiredAt' -Default ''
        if ($existingFirst) {
            $firstAcquiredAt = $existingFirst
        } else {
            $existingAcquired = Get-PropertyOrDefault -InputObject $existing -Name 'acquiredAt' -Default ''
            if ($existingAcquired) { $firstAcquiredAt = $existingAcquired }
        }
    }

    # 主線目前在哪：時鐘偏差檢測的錨點（ADR-0006 F 段）。還沒有 commit 的全新專案
    # 兩者都留空字串，不當成錯誤。
    $mainlineSha = Get-RefCommit -ProjectRoot $ProjectRoot -Ref 'HEAD'
    if (-not $mainlineSha) { $mainlineSha = '' }
    $mainlineDate = ''
    if ($mainlineSha) {
        $dateResult = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('log', '-1', '--format=%cI', 'HEAD')
        if ($dateResult.ExitCode -eq 0) { $mainlineDate = $dateResult.Output }
    }

    # 心跳分支名走票 26 的新規則：wip/<deviceId>-<工作目錄雜湊前 8 碼>，扁平、
    # 每個工作目錄各一條。取得租約當下 refs/remotes/origin/<分支> 的 sha——呼叫端
    # 要先 fetch 過，這裡只讀，不 fetch（ADR-0006「heartbeatRef／heartbeatCommit」
    # 欄位說明）。沒有的話留空字串，讀取端對空字串的規則是「判還活著」，不是這裡
    # 的責任。
    $heartbeatRef = Get-HeartbeatBranchName -DeviceId $identity.DeviceId -ProjectRoot $ProjectRoot
    $heartbeatCommit = Get-RefCommit -ProjectRoot $ProjectRoot -Ref "refs/remotes/origin/$heartbeatRef"
    if (-not $heartbeatCommit) { $heartbeatCommit = '' }

    # [pscustomobject]，不是 [ordered] hashtable：呼叫端（startup.ps1 的續用摘要）
    # 用 Get-PropertyOrDefault 讀這個回傳值的欄位，而它走的是 .PSObject.Properties——
    # 對 hashtable 抓不到鍵，續用的摘要會永遠印預設值（唯讀審查第 5 條）。
    $lease = [pscustomobject][ordered]@{
        schemaVersion            = 2
        projectUuid              = $projectUuid
        deviceId                 = $identity.DeviceId
        deviceName               = $identity.DeviceName
        holderWorkdir            = (Get-NormalisedPath $ProjectRoot)
        sessionId                = $SessionId
        firstAcquiredAt          = $firstAcquiredAt
        acquiredAt               = $acquiredAt
        acquiredAtMainlineCommit = [ordered]@{ sha = $mainlineSha; committerDate = $mainlineDate }
        heartbeatRef             = $heartbeatRef
        heartbeatCommit          = $heartbeatCommit
        expiresAt                = $now.AddHours(24).ToString('yyyy-MM-ddTHH:mm:sszzz')
        status                   = 'held'
    }
    if ($OverriddenAt) {
        $lease | Add-Member -NotePropertyName 'overriddenAt' -NotePropertyValue $OverriddenAt
        $lease | Add-Member -NotePropertyName 'overriddenBy' -NotePropertyValue $OverriddenBy
        $lease | Add-Member -NotePropertyName 'overriddenReason' -NotePropertyValue $OverriddenReason
        $lease | Add-Member -NotePropertyName 'overriddenLease' -NotePropertyValue $OverriddenLease
    }
    Write-LeaseAtomic -ProjectRoot $ProjectRoot -Record $lease | Out-Null
    return $lease
}

function Confirm-LeaseHeld {
    # 取得租約之後的寫後覆核（ADR-0006「Drive 同步延遲，以及租約能保證什麼」段；
    # 不變量 11b）。回傳 confirmed / conflict / unreadable / missing。
    #
    # 測試接縫：設定 HYBRID_TEST_PAUSE_BEFORE_CONFIRM_MS 時，在重讀之前先停一下，
    # 讓測試有一個確定性的窗口可以把租約換成另一台的。抄
    # migrate-project-identity.ps1 的 Confirm-DriveOriginWrite 同一個手法——沒有
    # 這個接縫的話只能靠緊迴圈搶微秒級的時序，在忙碌機器上會偶發紅（票 16）。
    # 正式執行時這個變數不存在，成本為零。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$SessionId
    )
    if ($env:HYBRID_TEST_PAUSE_BEFORE_CONFIRM_MS) {
        Start-Sleep -Milliseconds ([int]$env:HYBRID_TEST_PAUSE_BEFORE_CONFIRM_MS)
    }
    $reread = Read-Lease -ProjectRoot $ProjectRoot
    if (Test-Unreadable $reread) { return 'unreadable' }
    if (-not $reread) { return 'missing' }
    $rereadSessionId = Get-PropertyOrDefault -InputObject $reread -Name 'sessionId' -Default ''
    if ($rereadSessionId -eq $SessionId) { return 'confirmed' }
    return 'conflict'
}

function Undo-LeaseAcquisition {
    # 撤回不是刪檔（ADR-0006「D. 取得租約的撤回語義」；不變量 11a）。租約住在
    # Drive 上，別台的租約可能在這幾百毫秒之內同步進來——無條件刪檔會刪掉別台的
    # 東西。讀回確認 sessionId 是自己這次寫的那一顆才動，而且動作是改寫成
    # released（保留原記錄全部欄位），不是刪除。
    #
    # 回傳 undone / not-mine / unreadable / missing。not-mine／unreadable／檔案
    # 讀不動的情況一律「一個位元組都不動」。
    #
    # -Identity 是呼叫端已經算好的 Get-DeviceIdentity 回傳值（票 26；理由同
    # Get-LeaseState 的 -Identity 參數註解）。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Identity
    )
    $current = Read-Lease -ProjectRoot $ProjectRoot
    if (Test-Unreadable $current) { return 'unreadable' }
    if (-not $current) { return 'missing' }

    $currentSessionId = Get-PropertyOrDefault -InputObject $current -Name 'sessionId' -Default ''
    if ($currentSessionId -ne $SessionId) { return 'not-mine' }

    $identity = $Identity
    Set-LeaseProperty -Lease $current -Name 'status' -Value 'released'
    Set-LeaseProperty -Lease $current -Name 'releasedAt' -Value ((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'))
    Set-LeaseProperty -Lease $current -Name 'releasedBy' -Value $SessionId
    Set-LeaseProperty -Lease $current -Name 'releasedByDevice' -Value $identity.DeviceName
    Set-LeaseProperty -Lease $current -Name 'releaseReason' -Value 'startup-rollback'

    Write-LeaseAtomic -ProjectRoot $ProjectRoot -Record $current | Out-Null
    return 'undone'
}

function Set-LeaseReleased {
    # 釋放不是刪檔，是把狀態改掉並留下痕跡：releasedBy 跟持有者的 sessionId 不一樣
    # 時，一眼就看得出那一筆是代理收工替別台裝置收的（票 06 靠這個，ADR-0006 沿用）。
    #
    # 保留原記錄全部欄位再疊加釋放欄位——deviceId／deviceName／holderWorkdir／
    # heartbeatRef 這些持有者留下的資訊，釋放之後仍然要讀得到（L8）。releasedBy
    # 記的是釋放者的 sessionId，不再把 device 預設成 $env:COMPUTERNAME——那個
    # fallback 屬於取得端，不屬於釋放端。
    # -Identity 是呼叫端已經算好的 Get-DeviceIdentity 回傳值（票 26；理由同
    # Get-LeaseState 的 -Identity 參數註解）。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$Lease,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Identity
    )
    $identity = $Identity
    Set-LeaseProperty -Lease $Lease -Name 'status' -Value 'released'
    Set-LeaseProperty -Lease $Lease -Name 'releasedAt' -Value ((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'))
    Set-LeaseProperty -Lease $Lease -Name 'releasedBy' -Value $SessionId
    Set-LeaseProperty -Lease $Lease -Name 'releasedByDevice' -Value $identity.DeviceName

    Write-LeaseAtomic -ProjectRoot $ProjectRoot -Record $Lease | Out-Null
    return $Lease
}
