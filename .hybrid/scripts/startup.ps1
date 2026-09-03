<#
.SYNOPSIS
    開工：在這台裝置上重建專案的工作環境。

.DESCRIPTION
    解析這台裝置的 Drive 掛載點，把 _drive/ 掛到專案 ID 對應的實體資料夾上。
    junction 用絕對路徑、進不了版控，所以每台裝置都得自己重建一次。

    步驟順序是「解析路徑 → 建 junction」，這個順序由租約的存放位置鎖死：租約住在
    _drive/ 裡面，junction 沒建好就讀不到它。

.PARAMETER ProjectRoot
    專案在本機的位置。預設為目前目錄。

.PARAMETER DriveRoot
    Drive 端的根目錄。省略時依「本機設定檔 → 自動偵測」的順序解析；顯式指定會被
    這台裝置記住。

.PARAMETER ReadOnly
    只是要看看或規劃時用。環境照樣重建、主線照樣拉取，但不取得租約——不留下之後
    需要清理的狀態。租約是什麼狀態都不阻擋這條路（ADR-0006「四條路」）。

.PARAMETER TakeOverLease
    租約被別台裝置持有或讀不動時，明確覆寫它。必須搭配 -TakeOverReason。
    不適用於 self-other-workdir（同一台裝置的另一個目錄，覆寫解決不了那邊還在寫
    _drive/ 的問題）與 foreign-project（掛錯目錄，不是所有權之爭）——這兩種狀態
    仍然一律 exit 2（ADR-0006 段落 C、四條路表）。

.PARAMETER TakeOverReason
    -TakeOverLease 的理由，必填、不可空白。會連同被覆寫的舊租約整筆寫進
    .hybrid\lease-overrides.jsonl 並單獨 commit（ADR-0006 Consequences）。

.OUTPUTS
    exit 0 = 完成；1 = 失敗；2 = 停下來了，需要使用者判斷。
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$DriveRoot,
    [string]$ListPath,
    [switch]$ReadOnly,
    [switch]$TakeOverLease,
    [string]$TakeOverReason
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
. (Join-Path $PSScriptRoot 'lib\preflight.ps1')
. (Join-Path $PSScriptRoot 'lib\health.ps1')

function Get-LeaseLiveness {
    # 軸二：存活判定（ADR-0006 段落 A／「過期判斷不能只看本機時鐘」／段落 F）。
    # 只在軸一是 other 時計算——不碰時鐘就下不了結論的東西，這裡才需要。
    #
    # 回傳 State（active/stale/unknown）與 Detail（給訊息用的說明）。
    #
    # 讀取端一律用租約記的 heartbeatRef，不由裝置名重算（ADR-0006：命名規則會變，
    # 持有者寫下的名字是唯一權威）。v1 租約沒有 heartbeatCommit，第二個判定來源
    # 不存在，一律 unknown。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$Lease
    )
    $schemaVersion = Get-PropertyOrDefault -InputObject $Lease -Name 'schemaVersion' -Default ''
    if (-not $schemaVersion) {
        return [pscustomobject]@{ State = 'unknown'; Detail = 'v1 租約沒有心跳 commit 紀錄，判不出來' }
    }

    $acquiredAtRaw = Get-PropertyOrDefault -InputObject $Lease -Name 'acquiredAt' -Default ''
    $now = Get-Date

    # F 段第 3 條：持有者的時間在讀取者的未來超過 1 小時，直接判不可信。
    if ($acquiredAtRaw) {
        try {
            $acquiredAtParsed = [datetimeoffset]::Parse($acquiredAtRaw)
            if ($acquiredAtParsed -gt ([datetimeoffset]$now).AddHours(1)) {
                return [pscustomobject]@{ State = 'unknown'; Detail = '租約的取得時間在這台裝置的未來超過一小時，時鐘不可信' }
            }
        } catch {
            # 空 catch 會把型別錯誤靜靜降級成「還活著」（唯讀審查第二輪第 2 條）。
            # acquiredAt 格式本身無法解析，代表這份租約的時間資訊已經不可信，落到
            # 具名的 unknown，不要吞掉繼續往下判。
            return [pscustomobject]@{ State = 'unknown'; Detail = "租約的 acquiredAt 格式無法解析：$($_.Exception.Message)" }
        }
    }

    # Get-PropertyOrDefault 的契約是回字串（`[string]$InputObject.$Name`）——對巢狀
    # 物件呼叫它，拿到的是 .ToString() 之後的 "@{sha=...; committerDate=...}"，不是
    # 物件本身，F-1 因此讀不到 committerDate、這個分支永遠進不去（唯讀審查第 7 條）。
    # 巢狀物件改成直接檢查 .PSObject.Properties。
    $mainlineAtAcquire = $null
    if ($Lease -and $Lease.PSObject.Properties['acquiredAtMainlineCommit'] -and $Lease.acquiredAtMainlineCommit) {
        $mainlineAtAcquire = $Lease.acquiredAtMainlineCommit
    }
    if ($mainlineAtAcquire -and $acquiredAtRaw) {
        $mainlineDate = ''
        if ($mainlineAtAcquire.PSObject.Properties['committerDate'] -and $mainlineAtAcquire.committerDate) {
            $mainlineDate = [string]$mainlineAtAcquire.committerDate
        }
        if ($mainlineDate) {
            try {
                # F 段第 1 條：租約宣稱自己早於它自己記下的那筆 commit——矛盾。
                if (([datetimeoffset]::Parse($acquiredAtRaw)) -lt ([datetimeoffset]::Parse($mainlineDate))) {
                    return [pscustomobject]@{ State = 'unknown'; Detail = '租約的取得時間早於它自己記下的主線 commit，時間資訊互相矛盾' }
                }
            } catch {
                # 同上：時間格式解析失敗不是「沒有矛盾」，是「判不出來」，落到 unknown。
                return [pscustomobject]@{ State = 'unknown'; Detail = "F-1 時間比對失敗，時間格式無法解析：$($_.Exception.Message)" }
            }
        }
    }

    $heartbeatRefName = Get-PropertyOrDefault -InputObject $Lease -Name 'heartbeatRef' -Default ''
    if (-not $heartbeatRefName) {
        return [pscustomobject]@{ State = 'unknown'; Detail = '租約沒有記錄心跳分支名' }
    }
    $remoteRef = "refs/remotes/origin/$heartbeatRefName"
    $remoteSha = Get-RefCommit -ProjectRoot $ProjectRoot -Ref $remoteRef
    if (-not $remoteSha) {
        return [pscustomobject]@{ State = 'unknown'; Detail = "心跳分支 $heartbeatRefName 不存在，心跳從沒推上來過" }
    }

    $recordedSha = Get-PropertyOrDefault -InputObject $Lease -Name 'heartbeatCommit' -Default ''

    # F 段第 2 條：心跳分支上有 commit 早於 acquiredAt，矛盾。只在還沒判定為
    # active（sha 有動）的情況下才需要看，sha 沒動代表沒有新 commit 可以矛盾。
    #
    # $recordedSha 必須先確認在本機解析得到，才能拿去組 range 查詢：別台的心跳還沒
    # fetch 到（或已經被刪）時，$recordedSha 在本機不是一個有效物件，"$recordedSha..$remoteRef"
    # 是一個無效的 range，git log 會把 fatal: Invalid revision range 直接噴到使用者
    # 的終端機（Invoke-Git 刻意不攔 stderr）——output-hygiene.test.mjs 守的正是這類
    # 外洩，這條路之前沒被納入（唯讀審查第 11 項）。
    #
    # 這裡不能用 Get-RefCommit（`rev-parse --verify --quiet <sha>`）：對一個語法合法
    # 但物件不存在的 40 碼十六進位字串，rev-parse 只做格式轉換，不驗證物件庫裡真的
    # 有這個物件，會原樣回傳、exit 0（實測過，不是猜的）。改用 `cat-file -e`，它才是
    # 真的檢查物件存在，--quiet 一樣不產生 stderr。
    $recordedShaExistsLocally = $false
    if ($recordedSha) {
        $recordedShaExistsLocally = (Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('cat-file', '-e', $recordedSha)).ExitCode -eq 0
    }
    if ($recordedSha -and ($recordedSha -ne $remoteSha) -and $acquiredAtRaw -and $recordedShaExistsLocally) {
        $range = "$recordedSha..$remoteRef"
        $dates = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('log', '--format=%cI', $range)
        if ($dates.ExitCode -eq 0 -and $dates.Output) {
            try {
                $acquiredAtParsed2 = [datetimeoffset]::Parse($acquiredAtRaw)
                foreach ($d in ($dates.Output -split "`n")) {
                    if ($d -and ([datetimeoffset]::Parse($d.Trim())) -lt $acquiredAtParsed2) {
                        return [pscustomobject]@{ State = 'unknown'; Detail = '心跳分支上有 commit 早於租約的取得時間，時間資訊互相矛盾' }
                    }
                }
            } catch {
                return [pscustomobject]@{ State = 'unknown'; Detail = "F-2 時間比對失敗，時間格式無法解析：$($_.Exception.Message)" }
            }
        }
    }

    if ($remoteSha -ne $recordedSha) {
        return [pscustomobject]@{ State = 'active'; Detail = "心跳分支 $heartbeatRefName 的 sha 比租約記錄的新" }
    }

    # sha 沒動：看 committer date 是否超過 24 小時，且 expiresAt 也已過期，兩者
    # 都成立才是 stale；否則保守判 active（誤判為活著的代價比誤判為過期低）。
    $committerDateResult = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('log', '-1', '--format=%cI', $remoteRef)
    $committerDate = if ($committerDateResult.ExitCode -eq 0) { $committerDateResult.Output } else { '' }
    $expiresAtRaw = Get-PropertyOrDefault -InputObject $Lease -Name 'expiresAt' -Default ''

    # New-TimeSpan -Start 的參數型別是 [DateTime]，餵 [datetimeoffset] 必定拋例外
    # （DateTimeOffset → DateTime 沒有隱式轉換）——這正是「stale 永遠判不到」的根因
    # （唯讀審查第二輪第 2 條）。兩端統一成 [datetimeoffset] 直接相減，不借 New-TimeSpan。
    $staleByCommit = $false
    if ($committerDate) {
        try {
            $staleByCommit = ((([datetimeoffset]$now) - ([datetimeoffset]::Parse($committerDate))).TotalHours -gt 24)
        } catch {
            return [pscustomobject]@{ State = 'unknown'; Detail = "心跳分支的 committer date 無法解析：$($_.Exception.Message)" }
        }
    }
    $staleByExpiry = $false
    if ($expiresAtRaw) {
        try {
            $staleByExpiry = (([datetimeoffset]::Parse($expiresAtRaw)) -lt ([datetimeoffset]$now))
        } catch {
            return [pscustomobject]@{ State = 'unknown'; Detail = "租約的 expiresAt 無法解析：$($_.Exception.Message)" }
        }
    }

    if ($staleByCommit -and $staleByExpiry) {
        return [pscustomobject]@{ State = 'stale'; Detail = "心跳分支 $heartbeatRefName 的 sha 超過 24 小時沒有動過，且租約已過期" }
    }
    return [pscustomobject]@{ State = 'active'; Detail = "心跳分支 $heartbeatRefName 的 sha 沒有動過，但還不到判定 stale 的門檻" }
}

try {
    $ProjectRoot = Resolve-ExistingProjectRoot -ProjectRoot $ProjectRoot

    # 這台裝置的持久識別（票 26）。跟專案狀態無關，算一次全程共用——所有比對租約、
    # 寫租約、算心跳分支名的地方都吃這一份，不要各自重新呼叫 Get-DeviceIdentity
    # （唯一入口，ADR-0006 欄位表）。-ListPath 是既有的測試接縫（不變量 13）。
    $deviceIdentity = Get-DeviceIdentity -ListPath $ListPath

    # --- 零、還不是專案的話，先把它變成專案 -------------------------------
    # 打包檔的用法：把資料夾改名成想同步的專案名稱，然後執行開工。這裡用資料夾名
    # 去 Drive 端找對應的專案，讀它的指標檔拿到 repo 位址，再把 repo 取下來。
    #
    # 配對不唯一時**一律停下來**列出候選，不猜、也不自動建新專案——猜錯的後果是
    # 使用者以為同步好了，其實在對一個空專案工作。
    $manifest = Read-ProjectManifest -ProjectRoot $ProjectRoot
    if (Test-Unreadable $manifest) {
        Write-Host "$(Get-ProjectManifestPath -ProjectRoot $ProjectRoot) 存在但無法解析（讀不動），可能還在同步中、暫時讀不到，也可能是內容損毀。"
        Write-Host "確認檔案內容之後再重跑；如果懷疑是同步問題，等 Drive 同步完成再重跑。"
        exit $script:ExitNeedsYou
    }
    if (-not $manifest) {
        $folderName = Split-Path -Leaf $ProjectRoot
        $bootDrive = Resolve-DriveRoot -ProjectRoot $ProjectRoot -DriveRoot $DriveRoot
        if (Test-Unreadable $bootDrive) {
            Write-Host "$(Get-LocalConfigPath -ProjectRoot $ProjectRoot) 存在但無法解析（讀不動），可能還在同步中、暫時讀不到，也可能是內容損毀。"
            Write-Host "這台裝置記住的 Drive 掛載點讀不到，不會落到自動偵測——那可能解析到不同的位置。"
            Write-Host "確認檔案內容之後再重跑，或以 -DriveRoot 明確指定要用哪個掛載點。"
            exit $script:ExitNeedsYou
        }
        if (-not $bootDrive) {
            Write-Host "這個目錄還不是專案，而且找不到 Google Drive 掛載點，無法查詢有哪些專案。"
            Write-Host "請以 -DriveRoot 指定，或確認 Google Drive 已經在這台裝置上登入。"
            exit $script:ExitNeedsYou
        }

        $found = Find-DriveProject -DriveRoot $bootDrive.Path -FolderName $folderName
        if ($found.Matches.Count -ne 1) {
            if ($found.Matches.Count -eq 0) {
                Write-Host "在 Drive 上找不到叫「$folderName」的專案。"
            } else {
                Write-Host "「$folderName」對應到不只一個專案，不替你猜是哪一個："
                foreach ($m in $found.Matches) { Write-Host "  * $m" }
            }
            Write-Host ""
            if ($found.Available.Count -eq 0) {
                Write-Host "Drive 上目前一個專案都沒有（$($bootDrive.Path)\$script:DriveNamespace）。"
                Write-Host "要開新專案請執行初始化，開工只負責接手既有的專案。"
            } else {
                Write-Host "Drive 上現有的專案："
                foreach ($a in $found.Available) { Write-Host "  * $a" }
                Write-Host ""
                Write-Host "把資料夾改成上面其中一個名字，再執行一次開工。"
            }
            exit $script:ExitNeedsYou
        }

        $projectDrivePath = Get-ProjectDrivePath -DriveRoot $bootDrive.Path -ProjectId $found.Matches[0]
        $origin = Read-DriveOrigin -ProjectDrivePath $projectDrivePath
        $remote = Get-PropertyOrDefault -InputObject $origin -Name 'remote' -Default ''
        if (-not $remote) {
            Write-Host "找到專案 $($found.Matches[0])，但它的指標檔沒有記錄 repo 位址。"
            Write-Host "在已經有這個專案的裝置上跑一次收工，指標檔就會補上。"
            exit $script:ExitNeedsYou
        }
        $bootBranch = Get-PropertyOrDefault -InputObject $origin -Name 'mainBranch' -Default $script:MainBranchName

        Write-Host "取得專案 $($found.Matches[0])"
        Write-Host "  來源：$remote"
        & git -C $ProjectRoot init --quiet
        Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('remote', 'add', 'origin', $remote) | Out-Null
        $fetch = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('fetch', '--quiet', 'origin')
        if ($fetch.ExitCode -ne 0) {
            Write-Host ""
            Write-Host "取不到 repo。私有 repo 需要這台裝置先通過 GitHub 認證："
            Write-Host "  gh auth login"
            Write-Host "（每台機器做一次就好，不是每個專案。）"
            exit $script:ExitNeedsYou
        }
        $checkout = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('checkout', '-q', $bootBranch)
        if ($checkout.ExitCode -ne 0) {
            Write-Host "簽出 $bootBranch 失敗：$($checkout.Output)"
            exit $script:ExitFailed
        }

        $manifest = Read-ProjectManifest -ProjectRoot $ProjectRoot
        if (Test-Unreadable $manifest) {
            Write-Host "$(Get-ProjectManifestPath -ProjectRoot $ProjectRoot) 存在但無法解析（讀不動），可能還在同步中、暫時讀不到，也可能是內容損毀。"
            Write-Host "確認檔案內容之後再重跑；如果懷疑是同步問題，等 Drive 同步完成再重跑。"
            exit $script:ExitNeedsYou
        }
        if (-not $manifest) {
            Write-Host "取下來的 repo 裡沒有 .hybrid/project.json，它不是 hybrid workspace 專案。"
            exit $script:ExitFailed
        }
        # bootstrap 腳本用完就沒有存在的必要了，專案自帶的那一份接手。
        $bootstrapDir = Join-Path $ProjectRoot '_bootstrap'
        if (Test-Path -LiteralPath $bootstrapDir) { Remove-Item -LiteralPath $bootstrapDir -Recurse -Force }
        Write-Host "  已取得，接著重建工作環境。"
        Write-Host ""
    }
    $projectId = [string]$manifest.projectId
    $assetsDir  = Get-PropertyOrDefault -InputObject $manifest -Name 'assetsDir'  -Default $script:AssetsDirName
    $derivedDir = Get-PropertyOrDefault -InputObject $manifest -Name 'derivedDir' -Default $script:DerivedDirName

    # --- 一、解析路徑 -----------------------------------------------------
    $resolved = Resolve-DriveRoot -ProjectRoot $ProjectRoot -DriveRoot $DriveRoot
    if (Test-Unreadable $resolved) {
        Write-Host "$(Get-LocalConfigPath -ProjectRoot $ProjectRoot) 存在但無法解析（讀不動），可能還在同步中、暫時讀不到，也可能是內容損毀。"
        Write-Host "這台裝置記住的 Drive 掛載點讀不到，不會落到自動偵測——那可能解析到不同的位置。"
        Write-Host "確認檔案內容之後再重跑，或以 -DriveRoot 明確指定要用哪個掛載點。"
        exit $script:ExitNeedsYou
    }
    if (-not $resolved) {
        Write-Host "找不到 Google Drive 的掛載點，無法決定 _drive/ 要掛到哪裡。"
        Write-Host "請重跑一次並以 -DriveRoot 指定，指定過的路徑這台裝置會記住。"
        exit $script:ExitNeedsYou
    }
    if (-not (Test-Path -LiteralPath $resolved.Path -PathType Container)) {
        Write-Host "Drive 端路徑不存在：$($resolved.Path)（來源：$($resolved.Source)）"
        Write-Host "請確認 Google Drive 已掛載，或以 -DriveRoot 指定正確的路徑。"
        exit $script:ExitNeedsYou
    }

    $overrideSaved = $false
    if ($resolved.Source -eq 'parameter') {
        $overrideSaved = Save-DriveRootOverride -ProjectRoot $ProjectRoot -DriveRoot $resolved.Path
    }

    $projectDrivePath = Get-ProjectDrivePath -DriveRoot $resolved.Path -ProjectId $projectId
    $linkPath = Join-Path $ProjectRoot $script:DriveLinkName

    # --- 二、建 junction --------------------------------------------------
    # 先分類再動作。分類的目的是讓「不能碰使用者資料」這件事有地方停下來。
    $mount = Get-MountState -Path $linkPath -ExpectedTarget $projectDrivePath

    if ($mount.State -eq 'plain-directory' -or $mount.State -eq 'plain-file') {
        $what = if ($mount.State -eq 'plain-directory') { '一般資料夾' } else { '一個檔案' }
        Write-Host "停下來了：$linkPath 是$what，不是 junction。"
        Write-Host ""
        Write-Host "開工不會刪除它——那可能是你的資料。請自己確認之後擇一處理："
        Write-Host "  * 內容還需要 → 搬到別的地方，或搬進 $projectDrivePath"
        Write-Host "  * 內容不需要 → 自己刪掉它，再重跑一次開工"
        exit $script:ExitNeedsYou
    }

    # Drive 端資料夾不見時，補建與停手的分界（ADR-0004「掛載」段第二條限制）。
    #
    # 本機 manifest 有 projectUuid，代表這個專案確實在 Drive 上存在過。那麼「目錄不見了」
    # 只可能是還沒同步下來或被刪掉——兩種都**不該補建**。補出來的空殼會往上同步到雲端、
    # 再散到另外兩台裝置，而空殼看起來就像「這個專案在 Drive 上是空的」。
    #
    # 只有在本機也沒有 UUID 證據時（第一次開工、或還沒遷移的 v1 專案）才補建。
    $driveRestored = -not (Test-Path -LiteralPath $projectDrivePath -PathType Container)
    $localUuidForMount = Get-PropertyOrDefault -InputObject $manifest -Name 'projectUuid' -Default ''
    if ($driveRestored -and $localUuidForMount) {
        Write-Host "停下來了：Drive 端找不到這個專案的資料夾。"
        Write-Host "  專案 ID    ：$projectId"
        Write-Host "  該在的位置 ：$projectDrivePath"
        Write-Host ""
        Write-Host "這個專案在 Drive 上存在過（本機記著它的 projectUuid），所以資料夾不見了"
        Write-Host "通常是 Google Drive 還沒同步下來，也可能是被刪掉了。"
        Write-Host "開工不會替你補一個空的出來——空殼會同步上雲端再散到另外兩台裝置，"
        Write-Host "看起來就像這個專案在 Drive 上本來就是空的（ADR-0004）。"
        Write-Host ""
        Write-Host "等 Google Drive 同步完成再重跑；確定是被刪掉的話，先從別台裝置或"
        Write-Host "Drive 的垃圾桶把它救回來。"
        exit $script:ExitNeedsYou
    }
    foreach ($dir in @($projectDrivePath, (Join-Path $projectDrivePath $assetsDir), (Join-Path $projectDrivePath $derivedDir))) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    $action = switch ($mount.State) {
        'missing' {
            New-Junction -Path $linkPath -Target $projectDrivePath
            'created'
        }
        'correct' {
            'unchanged'
        }
        'broken' {
            # junction 指的地方是對的，只是目標不見了。上面已經把它補回來，
            # 連結本身不用動——reparse point 存的是路徑，會在存取時才解析。
            'repaired'
        }
        'wrong-target' {
            Remove-Junction -Path $linkPath
            New-Junction -Path $linkPath -Target $projectDrivePath
            'redirected'
        }
        default {
            throw "未預期的掛載狀態：$($mount.State)"
        }
    }

    # --- 驗證：身分一致性（ADR-0007 不變量 9）------------------------------
    # 落在掛載之後、宣告之前（ADR-0004）：junction 是環境重建、可回滾，不算宣告；
    # 接下來的 Write-DriveOrigin／Add-ProjectToList／New-Lease 才是宣告。矛盾就在
    # 這裡停手——三個宣告都還沒發生，但在它之前 local.json、Drive 端目錄、junction
    # 本身已經可能被動過（都是冪等的環境重建，不是宣告；唯讀審查第三輪第 6 條）。
    #
    # $driveRestored 只用於下面回報訊息——判斷是否阻擋不再靠這個旗標（第四輪第 1
    # 條）：它只在算出它的這次行程內為真，上面的迴圈已經把 Drive 端目錄補出來，
    # 下一次呼叫目錄就已存在、旗標必然是 false，會把「還沒同步」誤判成「半遷移」。
    # Confirm-IdentityConsistency 現在自己判斷 origin.json 讀不讀得到，不吃這個旗標。
    $identity = Confirm-IdentityConsistency -ProjectRoot $ProjectRoot -Manifest $manifest -ProjectDrivePath $projectDrivePath
    foreach ($line in $identity.Messages) { Write-Host $line }
    if ($identity.Blocked) { exit $identity.ExitCode }

    # --- 驗證：遠端身分核對（票 26）------------------------------------------
    # Drive 的 origin.json 決定別的裝置 bootstrap 時要 clone 哪個 repo（ADR-0003）。
    # 這裡核對「這台已經 clone 的 repo」跟「Drive 記錄的 remote」是不是同一個
    # owner/repo——不符就停手，不猜、不覆蓋（票面明寫）。只有兩邊都能解析出
    # host/owner/repo 時才比較；本機路徑、bare repo（這個 repo 的測試套件大量
    # 使用這種 origin）解析不出來，視為「無法比對」，不阻擋。
    $remoteForIdentityCheck = ''
    if (Test-HasRemote -ProjectRoot $ProjectRoot) {
        $remoteProbeForIdentityCheck = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('remote', 'get-url', 'origin')
        if ($remoteProbeForIdentityCheck.ExitCode -eq 0) { $remoteForIdentityCheck = $remoteProbeForIdentityCheck.Output }
    }
    $driveOriginForRemoteCheck = Read-DriveOrigin -ProjectDrivePath $projectDrivePath
    if (-not (Test-Unreadable $driveOriginForRemoteCheck)) {
        $driveRemoteForCheck = Get-PropertyOrDefault -InputObject $driveOriginForRemoteCheck -Name 'remote' -Default ''
        if (Test-RemoteIdentityMismatch -RemoteA $remoteForIdentityCheck -RemoteB $driveRemoteForCheck) {
            Write-Host "停下來了：這台裝置的 git remote 跟 Drive 記錄的 origin.json 不是同一個 repo。"
            Write-Host "  這台的 remote        ：$remoteForIdentityCheck"
            Write-Host "  origin.json 的 remote：$driveRemoteForCheck"
            Write-Host ""
            # 被擋的那台什麼都沒做錯，它需要的是「為什麼會這樣」。Drive 那份如果是在
            # 一次推送失敗的收工寫進去的，那很可能就是原因——那次收工推不到它（票 39）。
            $driveLastPushOk = $null
            if ($driveOriginForRemoteCheck -and $driveOriginForRemoteCheck.PSObject.Properties['lastPushOk']) {
                $driveLastPushOk = [bool]$driveOriginForRemoteCheck.lastPushOk
            }
            if ($null -ne $driveLastPushOk -and -not $driveLastPushOk) {
                Write-Host "線索：Drive 上那個位址是在一次**推送沒有成功**的收工寫進去的。"
                Write-Host "      那次收工推不到它，所以它比較可能是錯的那一個。"
                Write-Host ""
            }
            Write-Host "不猜、不覆蓋——請確認哪一個才是對的，必要時手動修正 origin.json 或這台的 git remote。"
            exit $script:ExitNeedsYou
        }
    }

    # --- 驗證：主線可 fast-forward（ADR-0004）------------------------------
    # 拉取移到宣告之前。diverged／failed 是驗證階段的失敗，不是宣告失敗：停在這裡
    # 就不取得租約——在分岔狀態下取得租約，等於宣告「我在這條分岔上工作」，那正是
    # 製造第二條無法 merge 的分岔的起點。認證失敗、網路不通、repo 不存在三者現況
    # 分不出來（git.ps1 刻意不攔 stderr），所以底下不猜原因，只並列可能性。
    $branch = Get-CurrentBranch -ProjectRoot $ProjectRoot
    $pull = Invoke-MainlinePull -ProjectRoot $ProjectRoot

    if ($pull.State -eq 'diverged' -or $pull.State -eq 'failed') {
        if ($pull.State -eq 'diverged') {
            Write-Host "停下來了：本機主線跟遠端分岔了（$($pull.Detail)）。"
            Write-Host ""
            Write-Host "本機有遠端沒有的 commit，遠端也有本機沒有的——這通常是"
            Write-Host "「上次收工推送失敗、但 commit 已經留在本機」造成的。"
            Write-Host "處理方式：git pull --rebase，或找出那筆本機 commit 決定要不要留。"
        } else {
            Write-Host "停下來了：拉取主線失敗（$($pull.Detail)）。"
            Write-Host ""
            Write-Host "認證失敗、網路不通、repo 不存在，這裡分不出來，需要你確認："
            Write-Host "  * 認證：這台裝置是否已通過 git 遠端的認證"
            Write-Host "  * 網路：網路連線是否正常"
            Write-Host "  * repo：remote 位址是否還存在"
        }
        Write-Host ""
        Write-Host "驗證階段失敗，不會取得租約、不會寫入 Drive 端、不會登記心跳（ADR-0004）。"
        exit $script:ExitNeedsYou
    }

    # --- 驗證：租約（ADR-0006；不變量 11a）----------------------------------
    # 軸一（所有權）分類排在宣告之前，是驗證階段的一部分：阻擋的四種
    # （unreadable／self-other-workdir／foreign-project／other）在這裡 exit 2，
    # 完全不進入宣告階段——不寫 origin.json、不登記心跳清單。-ReadOnly 完全跳過
    # 這一段：唯讀查看不論租約是什麼狀態都不阻擋（ADR-0006「四條路」）。
    $sessionId = [guid]::NewGuid().ToString()
    $leaseOverrideNeeded = $false
    $overriddenLeaseForRecord = $null
    $overriddenLeaseRawBytes = $null
    if (-not $ReadOnly) {
        $leaseForValidation = Read-Lease -ProjectRoot $ProjectRoot
        $leaseAxis1 = Get-LeaseState -Lease $leaseForValidation -ProjectRoot $ProjectRoot -Manifest $manifest -Identity $deviceIdentity
        # 續用的是不是一份 v1 租約：New-Lease 會把它升級成 v2，這個資訊之後就讀不到了，
        # 要在覆寫之前存下來——續用摘要要說出 v1 的工作目錄盲點（唯讀審查第 10 條；
        # ADR-0006「v1 租約的相容」段）。
        $leaseWasV1 = ($leaseAxis1 -eq 'self') -and
            (-not (Get-PropertyOrDefault -InputObject $leaseForValidation -Name 'schemaVersion' -Default ''))
        # 分類為 unreadable 的這一刻就把原始位元組抓進記憶體——不要留到覆寫時才重讀
        # 一次。中間隔著整個驗證階段的窗口，Drive 若在此期間把一份合法租約同步進來，
        # 稍後重讀抓到的就是另一份東西，而真正讀不動的那一份消失得無聲無息
        # （唯讀審查第 9 條的 TOCTOU）。
        if ($leaseAxis1 -eq 'unreadable') {
            $unreadableLeasePath = Get-LeasePath -ProjectRoot $ProjectRoot
            if (Test-Path -LiteralPath $unreadableLeasePath) {
                $overriddenLeaseRawBytes = [System.IO.File]::ReadAllBytes($unreadableLeasePath)
            }
        }
        $blockingStates = @('unreadable', 'self-other-workdir', 'foreign-project', 'other')
        if ($blockingStates -contains $leaseAxis1) {
            # TakeOverLease 只適用於 other（別台持有）與 unreadable（讀不動）——
            # self-other-workdir 覆寫解決不了另一個目錄還在寫 _drive/ 的問題，
            # foreign-project 是掛錯目錄，不是所有權之爭，兩者一律不提供覆寫
            # （ADR-0006 段落 C、四條路表）。
            $overridable = ($leaseAxis1 -eq 'other' -or $leaseAxis1 -eq 'unreadable')
            if ($overridable -and $TakeOverLease) {
                if (-not $TakeOverReason) {
                    Write-Host "停下來了：-TakeOverLease 要搭配 -TakeOverReason 說明理由，不能空白。"
                    exit $script:ExitNeedsYou
                }
                $leaseOverrideNeeded = $true
                $overriddenLeaseForRecord = $leaseForValidation
            } else {
                switch ($leaseAxis1) {
                    'unreadable' {
                        Write-Host "停下來了：租約檔存在但無法解析（讀不動），可能還在同步中、暫時讀不到，也可能是內容損毀。"
                        Write-Host "讀不動的租約分不出持有者是誰，不提供代理收工——它的第一步是釋放，會銷毀唯一一份證據。"
                        Write-Host "唯一的路是明確覆寫：帶 -TakeOverLease 與 -TakeOverReason『理由』重跑。"
                    }
                    'self-other-workdir' {
                        $holderWorkdir = Get-PropertyOrDefault -InputObject $leaseForValidation -Name 'holderWorkdir' -Default '（未記錄）'
                        Write-Host "停下來了：這個專案的租約目前握在這台裝置的另一個工作目錄手上。"
                        Write-Host "  另一個工作目錄：$holderWorkdir"
                        Write-Host ""
                        Write-Host "到那個目錄去執行收工，或用 -ReadOnly 只看不動。這裡不提供代理收工——"
                        Write-Host "那些未提交的變更就在同一顆硬碟上，繞遠路從心跳分支撈只會拿到快照。"
                        Write-Host "也不建議明確覆寫：覆寫不會讓另一個目錄停止寫 $($script:DriveLinkName)/。"
                        Write-Host ""
                        Write-Host "在票 26 修好命名規則之前，這兩個工作目錄的心跳都會推到同一條 wip/$($env:COMPUTERNAME)，"
                        Write-Host "並以 push --force 互相覆蓋——其中一個目錄的未提交變更沒有被保護。"
                    }
                    'foreign-project' {
                        Write-Host "停下來了：租約的 projectUuid 與本機 manifest 不同——這個 Drive 目錄可能被另一個專案誤用了。"
                        Write-Host "  租約 projectUuid：$(Get-PropertyOrDefault -InputObject $leaseForValidation -Name 'projectUuid' -Default '（無）')"
                        Write-Host "  本機 projectUuid ：$(Get-PropertyOrDefault -InputObject $manifest -Name 'projectUuid' -Default '（無）')"
                        Write-Host ""
                        Write-Host "這不是所有權之爭，任何情況下都不覆寫、不代理收工、不釋放。請確認 junction 指向的目標是不是對的。"
                    }
                    'other' {
                        $liveness = Get-LeaseLiveness -ProjectRoot $ProjectRoot -Lease $leaseForValidation
                        $holderName = Get-PropertyOrDefault -InputObject $leaseForValidation -Name 'deviceName' -Default (Get-PropertyOrDefault -InputObject $leaseForValidation -Name 'device' -Default '（未記錄）')
                        $releasingSince = Get-PropertyOrDefault -InputObject $leaseForValidation -Name 'releasingSince' -Default ''
                        Write-Host "停下來了：$holderName 持有這個專案的租約。"
                        if ($releasingSince) {
                            # 「正在收工」跟「忘記收工」的下一步不同，訊息不能混（票 36）。
                            Write-Host "  狀態：對方正在收工（自 $releasingSince），還沒確認 Drive 同步完成。"
                            Write-Host "        它的變更**已經推上主線了**，不會遺失——缺的只是那一句人工確認。"
                        }
                        Write-Host "  判定：$($liveness.State)（$($liveness.Detail)）"
                        Write-Host ""
                        switch ($liveness.State) {
                            'active'  { Write-Host "看起來還在工作。可以唯讀查看、代理收工，或帶 -TakeOverLease 與 -TakeOverReason 明確覆寫。" }
                            'stale'   { Write-Host "心跳沒動且已過期，多半是忘記收工了——風險比 active 低，但代理收工能拿回的東西上限是心跳分支上那一筆，可能不是最新進度。也可以唯讀查看，或明確覆寫。" }
                            'unknown' { Write-Host "判不出來是不是還活著（見上面的判定原因）。只能明確覆寫（帶理由），或代理收工（會退化成只釋放租約）。" }
                        }
                    }
                }
                exit $script:ExitNeedsYou
            }
        }
    }

    # --- 宣告：拉取主線 → 寫 origin.json → 登記心跳清單 → 取得租約（ADR-0004）----
    #
    # $declared 一律在動作**成功之後**才記，不要順手搬到動作之前——回滾會因此撤回一個
    # 其實沒完成的東西。這個時機成立的前提是三個宣告在實務上都是「全有或全無」，
    # 唯讀審查逐一驗證過：
    #   Write-DriveOrigin  暫存檔寫失敗 → origin.json 沒被動；Move-Item 失敗 → 同上，
    #                      只是留下一個 .writing（下一次執行會接手並說出來）
    #   Add-ProjectToList  所有失敗點都在 Write-ProjectList 的 Move-Item 之前，
    #                      清單沒被動，$listed 保持 $false
    #   New-Lease          內部走 Write-LeaseAtomic（暫存檔 + Move-Item），是原子寫入；
    #                      $declared.Add('lease') 記在 Move-Item 成功之後、寫後覆核
    #                      之前——這是 ADR-0006 段落 D 的規定時機，理由見下面取得
    #                      租約那一段的行內註解（這段舊註解曾經寫「New-Lease 目前
    #                      不是原子寫入」，那是票 22 之前的舊行為，已經不成立）。
    # 拉取本身已經在上面完成（fast-forward 進來的主線是遠端已經存在的事實，回滾它
    # 反而製造分岔，所以拉取不在下面的回滾清單裡）。剩下三個才是嚴格意義上「宣告」
    # ——任一個失敗，已完成的宣告要逆序撤回，exit 1（不是需要你判斷的 exit 2）。
    $declared = New-Object System.Collections.ArrayList
    $listed = $false
    $lease = $null
    $leaseState = 'none'
    $resumedStalePartial = $false
    try {
        # 明確覆寫先記一筆稽核紀錄再動手（ADR-0006 Consequences）：覆寫是「我知道我在
        # 搶別人的東西」的那一刻，紀錄必須比覆寫動作先落地——先覆寫再記錄的話，行程
        # 中間被砍掉就留下一次沒有紀錄的搶奪。這一步刻意**不**進 $declared：它是一筆
        # 已經進入本機歷史的稽核紀錄，撤回它就是銷毀證據（跟拉取同一類，不撤回）。
        # 只 git add 這一個檔案，不 git add -A；推送失敗不讓覆寫失敗（盡力而為）。
        if ($leaseOverrideNeeded) {
            # device 一律經 Get-DeviceIdentity（lease.ps1）這個單一入口，不要在這裡
            # 另外直接讀 $env:COMPUTERNAME（L2；ADR-0006 欄位表 deviceId／deviceName）。
            # 用行程一開始就算好的那一份，不重新呼叫。
            $overrideIdentity = $deviceIdentity
            $overrideRecord = [ordered]@{
                overriddenAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
                device       = $overrideIdentity.DeviceName
                sessionId    = $sessionId
                reason       = $TakeOverReason
            }
            if (Test-Unreadable $overriddenLeaseForRecord) {
                # 原始位元組已經在分類的那一刻抓進 $overriddenLeaseRawBytes（見上）。
                # 用 [System.IO.File]::ReadAllBytes 讀、轉 base64 存成純字串：不經過
                # Get-Content -Raw，就不會出現掛著 PSPath／PSProvider／PSDrive
                # NoteProperty 的裝飾字串——那正是 46 MB 灌進 git 歷史的成因
                # （ConvertTo-Json -Depth 6 把整個 Provider → Assembly 物件圖序列化
                # 下去）。base64 同時保留原始位元組，不像 -Encoding UTF8 會把非
                # UTF-8 的位元組解成 U+FFFD 替換字元（ADR-0006「原始位元組原封不動」）。
                $overrideRecord.overriddenLeaseRaw = if ($overriddenLeaseRawBytes) {
                    [Convert]::ToBase64String($overriddenLeaseRawBytes)
                } else { '' }
            } else {
                $overrideRecord.overriddenLease = $overriddenLeaseForRecord
            }
            $overridesPath = Join-Path (Join-Path $ProjectRoot $script:HybridDirName) 'lease-overrides.jsonl'
            Add-JsonlRecord -Path $overridesPath -Record $overrideRecord
            $overridesRelative = '.hybrid/lease-overrides.jsonl'
            $overrideStage = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('add', '--', $overridesRelative)
            if ($overrideStage.ExitCode -ne 0) { throw "覆寫紀錄 stage 失敗：$($overrideStage.Output)" }
            $overrideMessage = "chore(租約覆寫): $($overrideIdentity.DeviceName) $((Get-Date).ToString('yyyy-MM-dd'))"
            # commit 限定路徑（-- $overridesRelative）：git commit 沒帶路徑會提交整個
            # index，把使用者自己已經 stage 的東西一起以「chore(租約覆寫)」的名義送出去
            # 並推送（唯讀審查第 3 條實測）。路徑限定的 commit 不動 index 裡其餘的項目。
            $overrideCommit = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('commit', '-m', $overrideMessage, '--', $overridesRelative)
            if ($overrideCommit.ExitCode -ne 0) { throw "覆寫紀錄 commit 失敗：$($overrideCommit.Output)" }
            if (Test-HasRemote -ProjectRoot $ProjectRoot) {
                Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('push', 'origin', "${branch}:${branch}") | Out-Null
            }
        }

        # -ReadOnly 要真的唯讀（ADR-0006）：origin.json 不寫、心跳清單不登記——登記
        # 進清單之後心跳就會開始對這個 repo 做 push --force，那不是唯讀。
        if (-not $ReadOnly) {
            # 指標檔跟著更新：remote 是後來才接上去的話，這裡會把它補進去。
            $remoteNow = ''
            if (Test-HasRemote -ProjectRoot $ProjectRoot) {
                $remoteProbe = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('remote', 'get-url', 'origin')
                if ($remoteProbe.ExitCode -eq 0) { $remoteNow = $remoteProbe.Output }
            }
            $originFilePath = Get-DriveOriginPath -ProjectDrivePath $projectDrivePath
            # 「檔案存在但內容是空的」與「檔案根本不存在」要分開記：PS 5.1 對零長度檔案的
            # Get-Content -Raw 回 $null，只看 $originBeforeRaw 的話回滾會把一個本來存在的
            # 空檔刪掉，而不是還原成空檔（唯讀審查第 9 條）。
            $originExistedBefore = Test-Path -LiteralPath $originFilePath
            $originBeforeRaw = if ($originExistedBefore) {
                Get-Content -LiteralPath $originFilePath -Raw -Encoding UTF8
            } else {
                $null
            }

            # 回傳值是「這次寫入前是不是接手了一個上次斷電留下的 .writing 暫存檔」——
            # 不變量 5(b) 要求把接手的半成品說出來，不能像過去那樣用 Out-Null 悶掉
            # （踩過的坑：這個回傳值曾經因為沒接住而以裸露的 False 印在使用者臉上，
            # 當時的修法是加 Out-Null 讓它不再外洩，但代價是這個信號從此沒人看見）。
            $resumedStalePartial = Write-DriveOrigin -ProjectDrivePath $projectDrivePath -ProjectId $projectId `
                -Remote $remoteNow -MainBranch $branch `
                -DisplayName (Split-Path -Leaf $ProjectRoot)
            [void]$declared.Add('origin')

            # 登記到心跳清單。加清單不需要提權，所以沒有理由讓使用者手動做——
            # 提權只該發生一次，在這台機器安裝排程的時候（票 11）。
            $listed = Add-ProjectToList -ListPath $ListPath -ProjectRoot $ProjectRoot -ProjectId $projectId
            [void]$declared.Add('heartbeat')
        }

        # 取得（或續用、或覆寫後取得）租約：這一步不能提到 junction 前面，租約住在
        # _drive/ 裡，掛載沒建好就讀不到。走到這裡代表軸一判定已經允許正常開工
        # （none／released／self），或使用者已經明確覆寫過（ADR-0006）。
        #
        # $declared.Add('lease') 記在 Move-Item 成功之後、寫後覆核之前（New-Lease
        # 內部走 Write-LeaseAtomic，回傳時已經是「Drive 上的租約檔現在說是我的」這個
        # 狀態成立的瞬間）——需要被撤回的暴露就是這件事，覆核是它之後的獨立步驟，
        # 覆核失敗必須走撤回，所以 Add 不能等覆核結果出來才做（ADR-0006 段落 D）。
        if (-not $ReadOnly) {
            # -Reuse 只在軸一判定為 self 時給——只有真正的續用才繼承 firstAcquiredAt，
            # 覆寫（搶別台的東西）與 none／released（新的持有）一律以這次為起點
            # （唯讀審查第 4 條）。明確覆寫時把稽核欄位一併傳進去，寫進 lease.json
            # 本身的 overridden*（唯讀審查第 9 條；ADR-0006 欄位表與 Consequences）。
            $newLeaseArgs = @{
                ProjectRoot = $ProjectRoot
                SessionId   = $sessionId
                Identity    = $deviceIdentity
                Reuse       = ($leaseAxis1 -eq 'self')
            }
            if ($leaseOverrideNeeded) {
                $newLeaseArgs.OverriddenAt     = $overrideRecord.overriddenAt
                $newLeaseArgs.OverriddenBy     = $overrideRecord.device
                $newLeaseArgs.OverriddenReason = $TakeOverReason
                if (-not (Test-Unreadable $overriddenLeaseForRecord)) {
                    $newLeaseArgs.OverriddenLease = $overriddenLeaseForRecord
                }
            }
            $lease = New-Lease @newLeaseArgs
            [void]$declared.Add('lease')
            $confirmResult = Confirm-LeaseHeld -ProjectRoot $ProjectRoot -SessionId $sessionId
            if ($confirmResult -ne 'confirmed') {
                throw "LEASE_CONFLICT:$confirmResult"
            }
            $leaseState = 'acquired'
            $leaseAcquireKind = if ($leaseOverrideNeeded) { 'overridden' } elseif ($leaseAxis1 -eq 'self') { 'self' } else { 'fresh' }
        } else {
            $lease = Read-Lease -ProjectRoot $ProjectRoot
            $leaseState = Get-LeaseState -Lease $lease -ProjectRoot $ProjectRoot -Manifest $manifest -Identity $deviceIdentity
        }
    }
    catch {
        # 原始失敗原因先存起來。回滾自己也可能丟例外，如果不先存，使用者拿到的會是
        # 撤回的內部細節而不是真正的原因（唯讀審查第 3 條實測過這件事）。
        $originalReason = $_.Exception.Message

        # 逆序撤回已完成的宣告（拉取除外——它從一開始就不在 $declared 裡）。
        # 每一項各自保護：一項撤不回來不能讓其餘的跟著放棄，也不能蓋掉原始原因。
        # 這不是假想情境——Remove-ProjectFromList 會在清單存在但讀不動時刻意丟例外
        # （registry.ps1，註解寫明是設計），而 Write-ProjectList 走暫存檔加 Move-Item，
        # Drive 同步或防毒鎖檔都會讓它炸。逆序之下 origin 排在最後，最容易被放棄的
        # 剛好就是那一項。
        $undone = New-Object System.Collections.ArrayList
        $leftBehind = New-Object System.Collections.ArrayList
        for ($i = $declared.Count - 1; $i -ge 0; $i--) {
            $item = $declared[$i]
            try {
                switch ($item) {
                    'lease' {
                        # 撤回不是刪檔（ADR-0006 段落 D）：租約住在 Drive 上，別台的
                        # 租約可能在這幾百毫秒內同步進來，無條件刪檔會刪掉別台的東西。
                        # Undo-LeaseAcquisition 自己做 compare-then-act：讀回確認
                        # sessionId 是這次寫的那一顆才動，改寫成 released（不是刪除），
                        # 不符或讀不動就一個位元組都不碰。
                        $undoResult = Undo-LeaseAcquisition -ProjectRoot $ProjectRoot -SessionId $sessionId -Identity $deviceIdentity
                        if ($undoResult -eq 'undone' -or $undoResult -eq 'missing') {
                            [void]$undone.Add('租約')
                        } else {
                            [void]$leftBehind.Add("租約（$undoResult，沒有撤回：現在 Drive 上的租約已經不是這次寫的那一份，一個位元組都不動）")
                        }
                    }
                    'heartbeat' {
                        if ($listed) { Remove-ProjectFromList -ListPath $ListPath -ProjectRoot $ProjectRoot | Out-Null }
                        [void]$undone.Add('心跳清單登記')
                    }
                    'origin' {
                        if ($null -eq $originBeforeRaw) {
                            # 事前沒有這個檔案（或它是零長度——PS 5.1 對零長度檔案的
                            # Get-Content -Raw 回 $null）。兩種都還原成「沒有內容」，
                            # 差別只在前者不該留下檔案、後者該留一個空檔。
                            if ($originExistedBefore) {
                                Write-Utf8NoBom -Path $originFilePath -Content ''
                            } elseif (Test-Path -LiteralPath $originFilePath) {
                                Remove-Item -LiteralPath $originFilePath -Force
                            }
                        } else {
                            # 撤回也要走原子寫入（ADR-0007 不變量 6），跟 Write-DriveOrigin
                            # 同一個手法：先寫暫存檔再 Move-Item。後綴刻意不用 .writing——
                            # 那是 Write-DriveOrigin 的半成品哨兵，同名會讓下一次執行把
                            # 回滾的暫存檔誤認成「上次寫到一半的殘檔」。
                            $temp = "$originFilePath.rollback"
                            Write-Utf8NoBom -Path $temp -Content $originBeforeRaw
                            Move-Item -LiteralPath $temp -Destination $originFilePath -Force
                        }
                        [void]$undone.Add('Drive 端指標檔')
                    }
                }
            }
            catch {
                [void]$leftBehind.Add("$item（撤回時又失敗：$($_.Exception.Message)）")
            }
        }

        # 租約寫後覆核沒通過（ADR-0006「Drive 同步延遲」段；不變量 11b）不是一般的宣告
        # 失敗——這是併發被觀測到之後的正常停手，不是壞掉，所以標題與 exit code 都不同
        # （exit 2，需要你判斷：重跑一次；不是 exit 1 的「開工失敗」）。
        $isLeaseConflict = $originalReason.StartsWith('LEASE_CONFLICT:')
        if ($isLeaseConflict) {
            $confirmState = $originalReason.Substring('LEASE_CONFLICT:'.Length)
            Write-Host "停下來了：取得租約之後的寫後覆核沒有通過（$confirmState）。"
            Write-Host "可能是另一台幾乎同時也在開工，也可能是 Drive 把別台稍早的租約同步了下來——"
            Write-Host "兩種處置一樣：重跑一次開工，讓它讀到現在的狀態重新判定。"
        } else {
            Write-Host "開工失敗：宣告階段中途失敗。"
            Write-Host "  原因       ：$originalReason"
        }
        if ($undone.Count -gt 0) {
            Write-Host "  已撤回     ：$($undone -join '、')"
        }
        if ($leftBehind.Count -gt 0) {
            Write-Host "  沒撤回     ：$($leftBehind -join '；')"
            Write-Host ""
            Write-Host "上面沒撤回的東西留在原地。重跑開工會重新走一次驗證與宣告，"
            Write-Host "三個宣告都是冪等的，所以通常重跑就會收斂——若重跑仍失敗，"
            Write-Host "照著上面的原因處理之後再試。"
        }
        if ($undone.Count -eq 0 -and $leftBehind.Count -eq 0) {
            Write-Host "  已撤回     ：沒有需要撤回的——失敗發生在第一個宣告之前。"
        }
        if ($leaseOverrideNeeded) {
            Write-Host ""
            Write-Host "覆寫紀錄已經留在本機歷史上（.hybrid\lease-overrides.jsonl，可能還沒推送）——"
            Write-Host "它不撤回，一筆已經進入本機歷史的稽核紀錄，撤回就是銷毀證據。"
        }

        if ($isLeaseConflict) { exit $script:ExitNeedsYou }
        exit $script:ExitFailed
    }

    # --- 回報階段（ADR-0004：宣告已完成，狀態是有效的）------------------------
    # 這一段只是把已經成立的狀態講給人聽：讀心跳分支、讀 next.md、算摘要。
    # 它失敗**不撤回宣告**——租約、心跳登記、指標檔都已經寫好而且是對的，撤回它們
    # 只會製造新的半成品。但也不能說「開工失敗」：唯讀審查第 2 條實測過，摘要爆掉時
    # 使用者被告知失敗，實際上這台握著租約、專案已進心跳清單，別台看到的是「有人在做」
    # 而做的人以為自己沒開工。所以照實說：已經開工了，只是摘要產不出來。
    try {
    # 別台裝置留下了什麼——拉取之後才問，才看得到它推上來的心跳分支。
    # 心跳分支一律用租約記的 heartbeatRef，不由裝置名重算（ADR-0006 段落 A／S2）：
    # 命名規則會變（票 26），持有者寫下的名字是唯一權威；v1 租約沒有這個欄位才
    # 退回用裝置名重算。
    $heartbeat = $null
    $holder = ''
    if ($leaseState -eq 'other') {
        $holder = Get-PropertyOrDefault -InputObject $lease -Name 'deviceName' -Default (Get-PropertyOrDefault -InputObject $lease -Name 'device' -Default '（未記錄）')
        $leaseHeartbeatRef = Get-PropertyOrDefault -InputObject $lease -Name 'heartbeatRef' -Default ''
        $heartbeat = Get-HeartbeatBranchInfo -ProjectRoot $ProjectRoot -Device $holder -Ref $leaseHeartbeatRef
    }

    $nextPath = Join-Path (Join-Path $ProjectRoot $script:HybridDirName) 'next.md'
    $nextItems = @()
    if (Test-Path -LiteralPath $nextPath) {
        $nextItems = @(Get-Content -LiteralPath $nextPath -Encoding UTF8 |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') } |
            Select-Object -First 3)
    }

    # --- 回報 -------------------------------------------------------------
    $sourceLabel = switch ($resolved.Source) {
        'parameter' { if ($overrideSaved) { '呼叫參數（已記住）' } else { '呼叫參數（與自動偵測一致）' } }
        'config'    { '本機設定檔' }
        'detected'  { '自動偵測' }
        default     { $resolved.Source }
    }
    $actionLabel = switch ($action) {
        'created'    { '已建立' }
        'unchanged'  { '已存在且正確，跳過' }
        'repaired'   { "Drive 端資料夾原本不見了，已重建（連結本身沒動）" }
        'redirected' { "原本指向 $($mount.Target)，已改指向正確的目標" }
        default      { $action }
    }

    # 「續用」與「新取得」要分開講（S6；ADR-0006 段落 B）：續用不再說「沿用這台裝置
    # 上次留下的租約」——那句話在「同時」的情況下會說謊（票 18 第 8 條實測過）。
    $leaseLabel = if ($ReadOnly) {
        switch ($leaseState) {
            'none'               { '無人持有；-ReadOnly，沒有取得' }
            'released'           { '無人持有（已釋放）；-ReadOnly，沒有取得' }
            'self'               { '這台裝置持有中；-ReadOnly，沒有動它' }
            'self-other-workdir' { "這台裝置的另一個工作目錄持有中（$(Get-PropertyOrDefault -InputObject $lease -Name 'holderWorkdir' -Default '未記錄')）；-ReadOnly，沒有動它" }
            'other'              { "$holder 持有；-ReadOnly，沒有動它" }
            'unreadable'         { '讀不動；-ReadOnly，沒有動它' }
            'foreign-project'    { '屬於別的專案（projectUuid 不同）；-ReadOnly，沒有動它' }
            default              { $leaseState }
        }
    } else {
        switch ($leaseAcquireKind) {
            'overridden' { "已覆寫並取得（$env:COMPUTERNAME，理由：$TakeOverReason）" }
            'self'       { "續用這個目錄從 $(Get-PropertyOrDefault -InputObject $lease -Name 'firstAcquiredAt' -Default '未記錄') 起持有的租約" }
            'fresh'      { "已取得（$env:COMPUTERNAME）" }
            default      { $leaseState }
        }
    }
    # -ReadOnly 之下 Add-ProjectToList 根本沒跑，$listed 永遠是 $false——舊寫法把它
    # 跟「已在清單裡」共用同一句話，唯讀開工會被印成「已在清單裡」，說了一次不存在
    # 的既有登記（唯讀審查第 6 條 (a)）。三態分開講。
    $heartbeatLabel = if ($ReadOnly) {
        '未登記（-ReadOnly，沒有登記進心跳清單）'
    } elseif ($listed) {
        '已登記到清單'
    } else {
        '已在清單裡'
    }
    $pullLabel = switch ($pull.State) {
        'pulled'      { "已拉取（$($pull.Detail)）" }
        'up-to-date'  { '已經是最新的' }
        'no-remote'   { '沒有 remote，略過拉取' }
        'no-commits'  { '還沒有任何 commit，略過拉取' }
        'no-upstream' { "遠端還沒有這條分支（$($pull.Detail)）" }
        default       { $pull.State }
    }
    $lastCommit = Get-LastCommitSummary -ProjectRoot $ProjectRoot

    Write-Host "開工完成"
    Write-Host "  裝置       ：$env:COMPUTERNAME"
    Write-Host "  專案 ID    ：$projectId"
    Write-Host "  掛載點來源 ：$sourceLabel"
    Write-Host "  _drive/    ：$actionLabel"
    Write-Host "               → $projectDrivePath"
    if ($driveRestored -and $action -ne 'repaired') {
        Write-Host "  注意       ：Drive 端資料夾原本不存在，已重新建立。"
        Write-Host "               如果那裡本來有素材，可能只是 Google Drive 還沒同步下來。"
    }
    if ($resumedStalePartial) {
        Write-Host "  注意       ：origin.json 有上次寫到一半就中斷的暫存檔（可能是斷電或行程被砍），"
        Write-Host "               已接手並重新完整寫入（ADR-0007 不變量 5）。"
    }
    Write-Host "  心跳       ：$heartbeatLabel"
    Write-Host "  租約       ：$leaseLabel"
    if ((-not $ReadOnly) -and $leaseAcquireKind -eq 'self' -and $leaseWasV1) {
        # ADR-0006「v1 租約的相容」段、C1(d)：已知的失效不能藏起來（ADR-0005 在租約層
        # 的應用）——這是唯一一個 self-other-workdir 偵測不到的情境，續用時必須主動
        # 說出來，不能等使用者自己踩到（唯讀審查第 10 條）。
        Write-Host "               這是 v1 租約，沒有工作目錄的紀錄——如果這台機器上有這個專案的第二個 clone 正在工作，這裡分辨不出來。"
    }
    Write-Host "  主線       ：$branch（$pullLabel）"
    Write-Host "  上次進度   ：$(if ($lastCommit) { $lastCommit } else { '尚無 commit' })"

    # 票 28（驗收條件第三條）：不需要事件檢視器就知道心跳有沒有停擺。健康時只印
    # 一行，出事才多印——這個 repo 已經被「摘要變成一大片」咬過（唯讀審查系列）。
    try {
        $healthLines = @(Get-ProjectHealthSummaryLines -ProjectRoot $ProjectRoot -ListPath $ListPath)
        Write-Host "  心跳健康   ：$($healthLines[0])"
        for ($i = 1; $i -lt $healthLines.Count; $i++) { Write-Host "               $($healthLines[$i])" }
    } catch {
        Write-Host "  心跳健康   ：讀取失敗（$($_.Exception.Message)）"
    }

    if ($nextItems.Count -gt 0) {
        Write-Host "  接下來"
        for ($i = 0; $i -lt $nextItems.Count; $i++) {
            Write-Host "    $($i + 1). $($nextItems[$i])"
        }
    } else {
        Write-Host "  接下來     ：沒有 .hybrid/next.md。收工前在那裡留 1–3 行給下一次的自己。"
    }

    if ($leaseState -eq 'other') {
        Write-Host ""
        Write-Host "$holder 手上還有沒收完的工作——但它沒有擋你，上面的環境已經就緒。"
        if ($heartbeat.Found) {
            Write-Host "  它的心跳分支：$($heartbeat.Ref)"
            Write-Host "  最後一筆    ：$($heartbeat.LastCommit)"
            Write-Host "  比主線多    ：$($heartbeat.AheadCount) 筆"
            Write-Host "  要替它收工的話，執行代理收工——那會把這些變更併進主線並釋放它的租約。"
        } else {
            Write-Host "  它的心跳分支 $($heartbeat.Ref) 不存在：心跳沒跑過，或還沒推上來。"
            Write-Host "  這代表代理收工只能釋放租約，拿不回那台機器上未提交的變更。"
        }
    }

    exit $script:ExitOk
    }
    catch {
        # 宣告都完成了，工作階段是可用的——所以是 exit 0，不是失敗。
        # 不變量 4 要求「只有 exit 0 代表可以開始工作」，而這裡確實可以開始工作。
        #
        # 這兩行以前無條件印死字串「已取得」「已登記到清單」——-ReadOnly 之下兩者都沒
        # 發生過，exit 0、宣稱持有租約，但一份租約都沒有，直接踩到不變量 4 的反向
        # 斷言（唯讀審查第 6 條 (b)）。改成照 $ReadOnly 與這次declare階段實際發生的
        # 事分岔，不猜。
        Write-Host "已開工，但摘要產不出來。"
        Write-Host "  裝置       ：$env:COMPUTERNAME"
        Write-Host "  專案 ID    ：$projectId"
        $catchLeaseLabel = if ($ReadOnly) {
            "-ReadOnly，沒有取得（目前狀態：$leaseState）"
        } else {
            '已取得（這台裝置持有）'
        }
        Write-Host "  租約       ：$catchLeaseLabel"
        $catchHeartbeatLabel = if ($ReadOnly) {
            '未登記（-ReadOnly，沒有登記進心跳清單）'
        } elseif ($listed) {
            '已登記到清單'
        } else {
            '已在清單裡'
        }
        Write-Host "  心跳       ：$catchHeartbeatLabel"
        Write-Host ""
        Write-Host "摘要失敗的原因：$($_.Exception.Message)"
        Write-Host "工作階段本身是好的，可以開始工作；上面那個原因值得順手修掉"
        Write-Host "（多半是 .hybrid\next.md 讀不動）。"
        exit $script:ExitOk
    }
}
catch {
    Write-Host "開工失敗：$($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    exit $script:ExitFailed
}
