<#
.SYNOPSIS
    遷移：替沒有 projectUuid 的既有(v1)專案補上身分。

.DESCRIPTION
    只補值，不搬動 Drive 端目錄，不改變 projectId（ADR-0003：舊專案的相容邊界）。
    UUID 先寫 Drive 端、後寫 git 端；續跑時看到哪一端已經有值就採用它，不重新產生。
    兩端都有值但不一致時停手（exit 2），不猜、不改動任一端——那是人工裁決的事。

    預設是「只看不動手」：印出偵測到的狀態與會做的事，不寫入任何一端。確定要動手時
    加上 -Confirmed 重跑。選 -Confirmed 而不是 -WhatIf／-DryRun，是因為這兩個名字在
    PowerShell 的慣例裡預設「會動手」、傳了才轉唯讀，跟這裡要求的「預設不動手」剛好
    相反；-Confirmed 沿用 leave-device.ps1 已經在用的同一個慣例（同樣是「先給計畫，
    使用者確認才動手」的工具），兩支腳本的心智模型一致。

.PARAMETER ProjectRoot
    要遷移的專案。預設為目前目錄。

.PARAMETER DriveRoot
    Drive 端的根目錄。省略時依「本機設定檔 → 自動偵測」的順序解析。

.PARAMETER Confirmed
    真的動手寫入。沒帶就只顯示偵測到的狀態與遷移計畫。

.PARAMETER ListPath
    機器層級的家目錄，預設 `%LOCALAPPDATA%\hybrid-workspace`。'unsupported' 分支會用它
    找這台機器目前的 runtime 來刷新自帶腳本（`Invoke-RefreshProjectBundle`）。測試接縫。

.OUTPUTS
    exit 0 = 完成（含「本來就已經是 v2，沒有東西要做」）。
    exit 1 = 環境或程式錯誤，重跑有機會成功（例如目錄不存在）。
    exit 2 = 停下來了，需要你判斷：未帶 -Confirmed、身分矛盾、Drive 掛載點或路徑
             解析不出來、Drive 端讀不到或讀不動、本專案自帶的腳本太舊、或寫完之後
             回讀不到自己剛寫的值（ADR-0004）。
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$DriveRoot,
    [switch]$Confirmed,
    [string]$ListPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $OutputEncoding

. (Join-Path $PSScriptRoot 'lib\paths.ps1')
. (Join-Path $PSScriptRoot 'lib\git.ps1')
. (Join-Path $PSScriptRoot 'lib\runtime.ps1')

function Get-ParamBlockText {
    # 手動配對括號找出 param(...) 的完整範圍。正則做不到這件事——函式參數常見
    # [Parameter(Mandatory)]、[AllowEmptyString()] 這類巢狀括號的屬性標記，非貪婪的
    # `\(...\)` 會在第一個內層右括號就提前收尾，切不到真正的參數區塊結尾。
    param([Parameter(Mandatory)][AllowEmptyString()][string]$FunctionText)
    $start = $FunctionText.IndexOf('param')
    if ($start -lt 0) { return $null }
    $openIndex = $FunctionText.IndexOf('(', $start)
    if ($openIndex -lt 0) { return $null }
    $depth = 0
    for ($i = $openIndex; $i -lt $FunctionText.Length; $i++) {
        if ($FunctionText[$i] -eq '(') { $depth++ }
        elseif ($FunctionText[$i] -eq ')') {
            $depth--
            if ($depth -eq 0) { return $FunctionText.Substring($openIndex, $i - $openIndex + 1) }
        }
    }
    return $null
}

function Test-BundleSupportsProjectUuid {
    # 傳回 'supported' / 'unsupported' / 'unreadable'。
    #
    # 這個專案自帶的 .hybrid/scripts/lib/paths.ps1（Copy-TemplateBundle 在初始化時
    # 凍結進版控的那一份，見 initialise.ps1）可能還是票 15 之前的版本——那一份的
    # Write-DriveOrigin 沒有 ProjectUuid 參數，四個欄位全量覆寫。有 UUID 的專案配上
    # 這樣的寫入端，下一次用這份腳本開工就會把剛遷移好的 projectUuid 與 remote
    # 清空（唯讀審查第 1 條）。
    #
    # 「看不懂」跟「太舊」一樣危險，不能誤判成「支援」（唯讀審查第 9 條）：讀不到
    # 檔案內容、找不到 Write-DriveOrigin 的完整定義、找不到它的 param(...) 區塊，
    # 都代表這支工具沒辦法確認寫入端安不安全，一律回 'unreadable'，呼叫端要停手。
    # 判準也收斂到 param(...) 區塊裡有沒有 -ProjectUuid 參數，不是整個函式本體裡有
    # 沒有出現這個字串——一句提到它的註解不該讓一個全量覆寫的實作被判成支援。
    #
    # 專案沒有自帶腳本（例如遷移工具就在模板 repo 裡跑）不構成風險，視為支援。
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $bundledPaths = Join-Path $ProjectRoot '.hybrid\scripts\lib\paths.ps1'
    if (-not (Test-Path -LiteralPath $bundledPaths)) { return 'supported' }

    try {
        $content = Get-Content -LiteralPath $bundledPaths -Raw -Encoding UTF8
    } catch {
        return 'unreadable'
    }

    $writeDriveOrigin = [regex]::Match($content, 'function\s+Write-DriveOrigin\b[\s\S]*?(?=\r?\nfunction\s|\z)')
    if (-not $writeDriveOrigin.Success) { return 'unreadable' }

    $paramBlock = Get-ParamBlockText -FunctionText $writeDriveOrigin.Value
    if (-not $paramBlock) { return 'unreadable' }

    if ($paramBlock -match '\$ProjectUuid\b') { return 'supported' }
    return 'unsupported'
}

function Confirm-DriveOriginWrite {
    # 測試接縫：設定 HYBRID_TEST_PAUSE_BEFORE_CONFIRM_MS 時，在重讀之前先停一下，
    # 讓測試有一個**確定性**的窗口可以把 Drive 端改成另一顆 UUID。沒有這個接縫的話
    # 只能靠緊迴圈去搶微秒級的時序，而那條測試在忙碌的機器上會偶發紅（唯讀審查
    # 第三輪第 12 條），跟它自己取代掉的那條 race 測試是同一個毛病。
    # 跟 HYBRID_TEST_NO_GOOGLE_DRIVE 同一個模式：正式執行時這個變數不存在，成本為零。
    # 寫完 Drive 端之後重讀，確認裡面是自己剛寫的那一顆 UUID（ADR-0003：
    # 「Drive 端是仲裁點」的前提是讀得到、讀得新——「寫完要回讀確認」）。
    # 不是的話，代表另一台裝置幾乎同時也在遷移這個專案，兩邊都寫了 Drive 端。
    # 這不是真正的比較並交換（Google Drive 沒有這個原語），但足以把「兩台都以為
    # 自己成功」壓成「後到的那台停手」：本機這一半不寫，下一次遷移會看到 Drive
    # 端目前的值並採用它，不會再產生第三個。
    param(
        [Parameter(Mandatory)][string]$ProjectDrivePath,
        [Parameter(Mandatory)][string]$ExpectedUuid
    )
    if ($env:HYBRID_TEST_PAUSE_BEFORE_CONFIRM_MS) {
        Start-Sleep -Milliseconds ([int]$env:HYBRID_TEST_PAUSE_BEFORE_CONFIRM_MS)
    }
    $reread = Read-DriveOrigin -ProjectDrivePath $ProjectDrivePath
    if (Test-Unreadable $reread) {
        Write-Host "停下來了：剛寫入的 origin.json 現在讀不到（檔案存在但無法解析）。"
        Write-Host "無法確認寫入是否成功，需要你確認 Drive 端目前的內容之後再決定下一步。"
        exit $script:ExitNeedsYou
    }
    $rereadUuid = Get-PropertyOrDefault -InputObject $reread -Name 'projectUuid' -Default ''
    if ($rereadUuid -ne $ExpectedUuid) {
        Write-Host "停下來了：寫入 Drive 端之後重讀，projectUuid 不是剛剛寫的那一顆。"
        Write-Host "  剛寫入的：$ExpectedUuid"
        Write-Host "  現在讀到：$(if ($rereadUuid) { $rereadUuid } else { '（無）' })"
        Write-Host ""
        Write-Host "另一台裝置可能幾乎同時也在遷移這個專案——這不是真正的比較並交換，只能"
        Write-Host "停手讓你確認。本機這一半先不寫；下一次遷移會採用 Drive 端目前的值。"
        exit $script:ExitNeedsYou
    }
}

function Write-LocalIdentity {
    # 補 projectUuid／displayName 進本機 manifest，其餘欄位原封不動保留。
    #
    # 原子寫入：先寫暫存檔再 Move-Item。ADR-0007 不變量 6 只明講 Drive 端的 JSON，
    # 但本機這一步正好落在「兩端寫入之間可被斷電打斷的縫」裡（ADR-0003），順手用
    # 同一個手法沒有額外成本，卻讓「中途被砍掉」的窗口更小。
    #
    # 回傳是否接手了上一次留下的半成品（.writing 殘檔）——不變量 5(b) 要求這件事
    # 被說出來，呼叫端負責印出來。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$ProjectUuid,
        [Parameter(Mandatory)][AllowEmptyString()][string]$DisplayName
    )
    if ($Manifest.PSObject.Properties['projectUuid']) {
        $Manifest.projectUuid = $ProjectUuid
    } else {
        $Manifest | Add-Member -NotePropertyName 'projectUuid' -NotePropertyValue $ProjectUuid
    }
    if ($Manifest.PSObject.Properties['displayName']) {
        $Manifest.displayName = $DisplayName
    } else {
        $Manifest | Add-Member -NotePropertyName 'displayName' -NotePropertyValue $DisplayName
    }
    # 補完身分的同一刻一併寫 schemaVersion（ADR-0008）：這個專案從這一刻起是已初始化(v2)，
    # 不靠讀取側的推導規則（projectUuid 存在 → 2）反推——欄位存在就直接是權威。
    if ($Manifest.PSObject.Properties['schemaVersion']) {
        $Manifest.schemaVersion = 2
    } else {
        $Manifest | Add-Member -NotePropertyName 'schemaVersion' -NotePropertyValue 2
    }

    $finalPath = Get-ProjectManifestPath -ProjectRoot $ProjectRoot
    $temp = "$finalPath.writing"
    $resumedStalePartial = Test-Path -LiteralPath $temp
    if ($resumedStalePartial) { Remove-Item -LiteralPath $temp -Force }
    Write-Utf8NoBom -Path $temp -Content (ConvertTo-Json $Manifest)
    Move-Item -LiteralPath $temp -Destination $finalPath -Force
    return $resumedStalePartial
}

function Show-FleetBundlePremise {
    # 唯讀審查第二輪第 2 條：Test-BundleSupportsProjectUuid 只看得到跑遷移的這一台。
    # 「三台裝置的 .hybrid\scripts 都已經更新」是這支工具能安全動手的前提，但工具本身
    # 沒有辦法驗證——票 25（工具版本與升級機制）之前，這只能靠使用者自己確認並被
    # 明確告知，不能靜靜假設。v1 的 startup.ps1 在拉主線之前就先寫 origin.json
    # （`git show 8d7dc7c:scripts/startup.ps1` 可核對），所以「先開工、之後再 pull」
    # 這個順序來不及自己補救——這件事必須在動手之前說清楚，不能等抹掉才發現。
    Write-Host ""
    Write-Host "重要（票 25 落地前的已知限制，這支工具擋不住）："
    Write-Host "  這台裝置遷移完成之後，另外兩台裝置手上的 .hybrid\scripts 如果還是遷移前的版本，"
    Write-Host "  它們下一次用自己那份開工，可能會把剛遷移好的 projectUuid 與 remote 清空——"
    Write-Host "  前置檢查只保護得到跑遷移的這一台，保護不到另外兩台。"
    Write-Host ""
    Write-Host "  動手之前請確定，依序："
    Write-Host "    1. 這個專案自帶的 .hybrid\scripts 已經更新到支援 projectUuid 的版本"
    Write-Host "       （版本不夠新的話，去模板 repo 對這個專案執行："
    Write-Host "       scripts\initialise.ps1 -Force -ProjectRoot <這個專案的路徑>"
    Write-Host "       用模板目前的版本重刷 .hybrid\scripts；projectId／projectUuid 沿用既有值，"
    Write-Host "       不會被改動。注意：對這個專案自己的 .hybrid\scripts\initialise.ps1 -Force"
    Write-Host "       沒有用——它的來源與目標是同一份，不會複製任何東西，也不會報錯）"
    Write-Host "    2. 更新完的那份 .hybrid\scripts 已經 commit 並 push 上去"
    Write-Host "    3. 另外兩台裝置在下一次開工之前，先手動 pull 一次拿到新版本——不需要在"
    Write-Host "       那兩台上各自重刷，.hybrid\scripts 進版控，pull 就會帶到。v1 版的開工在"
    Write-Host "       拉主線之前就會先寫 origin.json，順序上是先開工再 pull 就來不及了"
}

try {
    $ProjectRoot = Resolve-ExistingProjectRoot -ProjectRoot $ProjectRoot

    # --- 讀本機 manifest：三態，讀不動不可以當成「不是專案」------------------
    $manifest = Read-ProjectManifest -ProjectRoot $ProjectRoot
    if (Test-Unreadable $manifest) {
        Write-Host ".hybrid/project.json 存在但無法解析（讀不動），可能還在同步中、暫時讀不到，也可能是內容損毀。"
        Write-Host "確認檔案內容之後再重跑；如果懷疑是同步問題，等 Drive 同步完成再重跑。"
        exit $script:ExitNeedsYou
    }
    if (-not $manifest) {
        Write-Host "這個目錄不是 hybrid workspace 專案（沒有 .hybrid/project.json），沒有身分可以遷移。"
        exit $script:ExitNeedsYou
    }
    $projectId = Get-PropertyOrDefault -InputObject $manifest -Name 'projectId' -Default ''
    if (-not $projectId) {
        Write-Host "manifest 沒有 projectId，狀態異常，無法定位 Drive 端目錄。"
        exit $script:ExitNeedsYou
    }
    $localUuid        = Get-PropertyOrDefault -InputObject $manifest -Name 'projectUuid' -Default ''
    $localDisplayName = Get-PropertyOrDefault -InputObject $manifest -Name 'displayName' -Default ''
    $folderName       = Split-Path -Leaf $ProjectRoot

    # --- 解析 Drive 掛載點與專案目錄 ---------------------------------------
    $resolved = Resolve-DriveRoot -ProjectRoot $ProjectRoot -DriveRoot $DriveRoot
    if (Test-Unreadable $resolved) {
        Write-Host "$(Get-LocalConfigPath -ProjectRoot $ProjectRoot) 存在但無法解析（讀不動），可能還在同步中、暫時讀不到，也可能是內容損毀。"
        Write-Host "這台裝置記住的 Drive 掛載點讀不到，不會落到自動偵測——那可能解析到不同的位置。"
        Write-Host "確認檔案內容之後再重跑，或以 -DriveRoot 明確指定要用哪個掛載點。"
        exit $script:ExitNeedsYou
    }
    if (-not $resolved) {
        Write-Host "找不到 Google Drive 的掛載點，無法讀取／寫入 Drive 端的身分。"
        Write-Host "Google Drive 可能還沒登入或還沒啟動——這不是程式錯誤，重跑不會自己好。"
        Write-Host "請等它就緒，或以 -DriveRoot 指定，例如：-DriveRoot 'H:\我的雲端硬碟'"
        exit $script:ExitNeedsYou
    }
    if (-not (Test-Path -LiteralPath $resolved.Path -PathType Container)) {
        Write-Host "Drive 端路徑不存在：$($resolved.Path)（來源：$($resolved.Source)）"
        Write-Host "請確認 Google Drive 已掛載並完成同步，或以 -DriveRoot 指定正確的路徑。"
        exit $script:ExitNeedsYou
    }

    $projectDrivePath = Get-ProjectDrivePath -DriveRoot $resolved.Path -ProjectId $projectId
    if (-not (Test-Path -LiteralPath $projectDrivePath -PathType Container)) {
        Write-Host "Drive 端目錄不存在：$projectDrivePath"
        Write-Host "本機 manifest 已經有 projectId，代表這個專案在 Drive 上存在過——這通常是"
        Write-Host "還沒同步完成，不是專案不存在。"
        Write-Host "遷移工具不重建專案骨架，也不會把『還沒同步』猜成『可以動手』。"
        Write-Host "等 Google Drive 同步完成再重跑遷移。"
        exit $script:ExitNeedsYou
    }

    # --- 讀 Drive 端 origin.json：三態，「不存在」與「讀不動」都不能當成「沒有值」-
    # 這個專案的 projectId 已經存在，代表它原本應該有這份指標檔——不管是整個檔案
    # 不見了還是內容解析失敗，都比較像「還沒同步完成」或「同步中的殘檔」，不是
    # 「這個專案沒有身分」，兩者要求相反的動作（ADR-0003）。
    $driveOriginFilePath = Get-DriveOriginPath -ProjectDrivePath $projectDrivePath
    if (-not (Test-Path -LiteralPath $driveOriginFilePath)) {
        Write-Host "Drive 端目錄存在，但指標檔不存在：$driveOriginFilePath"
        Write-Host ""
        Write-Host "這通常是還沒同步完成，不是這個專案沒有身分。遷移工具不把讀不到當成"
        Write-Host "『沒有值』動手寫，避免用猜測覆蓋掉可能仍然有效的內容。"
        Write-Host "等 Drive 同步完成再重跑。"
        exit $script:ExitNeedsYou
    }
    $driveOrigin = Read-DriveOrigin -ProjectDrivePath $projectDrivePath
    if (Test-Unreadable $driveOrigin) {
        Write-Host "Drive 端的 origin.json 讀不到內容（檔案存在但無法解析）：$driveOriginFilePath"
        Write-Host ""
        Write-Host "這可能是同步中的殘檔、部分寫入，或磁碟錯誤——不是『這個專案沒有身分』。"
        Write-Host "遷移工具不會把讀不到當成空值動手寫，避免用猜測覆蓋掉唯一一份證據。"
        Write-Host "確認檔案內容之後再重跑；如果懷疑是同步問題，等 Drive 同步完成再重跑。"
        exit $script:ExitNeedsYou
    }
    $driveUuid        = Get-PropertyOrDefault -InputObject $driveOrigin -Name 'projectUuid' -Default ''
    $driveDisplayName = Get-PropertyOrDefault -InputObject $driveOrigin -Name 'displayName' -Default ''

    Write-Host "遷移檢查：$projectId"
    Write-Host "  本機端     ：$ProjectRoot"
    Write-Host "  Drive 端   ：$projectDrivePath"
    Write-Host "  本機 UUID  ：$(if ($localUuid) { $localUuid } else { '（無）' })"
    Write-Host "  Drive UUID ：$(if ($driveUuid) { $driveUuid } else { '（無）' })"
    Write-Host ""

    # --- 身分矛盾：不猜、不動手，無論有沒有 -Confirmed ---------------------
    if ($localUuid -and $driveUuid -and $localUuid -ne $driveUuid) {
        Write-Host "停下來了：身分矛盾。"
        Write-Host "  本機 projectUuid：$localUuid"
        Write-Host "  Drive projectUuid：$driveUuid"
        Write-Host ""
        Write-Host "兩端都有身分但不一致，UUID 是隨機的，任一端都無法重算出另一端——這只能人工裁決。"
        Write-Host "遷移工具不猜、不覆寫任一端，即使加了 -Confirmed 也一樣。"
        exit $script:ExitNeedsYou
    }

    # --- 已經是 v2：兩端一致，沒有東西要做 ---------------------------------
    if ($localUuid -and $driveUuid -and $localUuid -eq $driveUuid) {
        Write-Host "已經是已初始化(v2)：兩端一致，沒有東西要遷移。"
        exit $script:ExitOk
    }

    # --- 前置檢查：本專案自帶的腳本跟不跟得上（審查第 1 條）------------------
    # 只在真的要寫入時檢查——已經是 v2 或身分矛盾都不會走到這裡，不需要這道檢查。
    $bundleSupport = Test-BundleSupportsProjectUuid -ProjectRoot $ProjectRoot
    if ($bundleSupport -ne 'supported') {
        if ($bundleSupport -eq 'unreadable') {
            Write-Host "停下來了：看不懂這個專案自帶的 .hybrid\scripts\lib\paths.ps1。"
            Write-Host "讀不到內容，或找不到 Write-DriveOrigin 完整的定義與參數——可能是版面被"
            Write-Host "搬動過、內容截斷，或用了這支工具辨識不出來的寫法。"
            Write-Host "「看不懂」在已經有 UUID 的專案上跟「版本太舊」一樣危險：下一次用它"
            Write-Host "開工／收工，一樣可能把剛遷移好的 projectUuid 與 remote 清空。"
        } else {
            Write-Host "停下來了：這個專案自帶的 .hybrid\scripts\lib\paths.ps1 版本太舊。"
            Write-Host "它的 Write-DriveOrigin 沒有 ProjectUuid 參數，是全量覆寫的舊邏輯——"
            Write-Host "下一次用這份腳本開工／收工，會把剛遷移好的 projectUuid 與 remote 清空。"
        }
        Write-Host ""
        Write-Host "重新產生自帶腳本不是這支工具的職責。目前唯一可行的辦法是去模板 repo 對這個"
        Write-Host "專案重跑："
        Write-Host "  scripts\initialise.ps1 -Force -ProjectRoot <這個專案的路徑>"
        Write-Host "它會用模板目前的版本重刷 .hybrid\scripts\（Copy-TemplateBundle），"
        Write-Host "projectId／projectUuid 沿用既有值，不會被改動。重刷之後再重跑一次遷移。"
        Write-Host "注意：對這個專案自己的 .hybrid\scripts\initialise.ps1 -Force 沒有用——"
        Write-Host "它的來源與目標是同一份，不會複製任何東西，也不會報錯（唯讀審查第三輪第 2 條）。"
        exit $script:ExitNeedsYou
    }

    # 兩端至少有一端需要寫入時，remote／主線分支一律當場向 git 問一次目前的真值，
    # 問不到就傳空字串——Write-DriveOrigin 的 Remote／MainBranch 現在跟
    # ProjectUuid／DisplayName 一樣是「空字串代表沿用既有值」（paths.ps1、
    # ADR-0003），不會被這裡的空值蓋掉。這裡跟 initialise.ps1／startup.ps1 一樣，
    # 用當下實際的 git 狀態決定要寫什麼。
    $remoteNow = ''
    if (Test-HasRemote -ProjectRoot $ProjectRoot) {
        $remoteProbe = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('remote', 'get-url', 'origin')
        if ($remoteProbe.ExitCode -eq 0) { $remoteNow = $remoteProbe.Output }
    }
    $branchNow = Get-CurrentBranch -ProjectRoot $ProjectRoot
    if (-not $branchNow) { $branchNow = $script:MainBranchName }

    if ($driveUuid -and -not $localUuid) {
        # 主要的續跑情境（ADR-0003 明講）：上一次遷移把 Drive 端寫完之後被中斷，
        # 本機還沒補上。採用 Drive 端已有的值，不重新產生。
        $displayNameToUse = if ($driveDisplayName) { $driveDisplayName }
                             elseif ($localDisplayName) { $localDisplayName }
                             else { $folderName }

        Write-Host "計畫：Drive 端已有身分（可能是上一次遷移中斷後留下的狀態），本機缺 UUID。"
        Write-Host "  → 採用 Drive 端既有的 UUID，補進本機 manifest；不產生新的。"
        Show-FleetBundlePremise
        if (-not $Confirmed) {
            Write-Host ""
            Write-Host "還沒動手。確定的話加上 -Confirmed 重跑。"
            exit $script:ExitNeedsYou
        }

        $resumed = Write-LocalIdentity -ProjectRoot $ProjectRoot -Manifest $manifest -ProjectUuid $driveUuid -DisplayName $displayNameToUse
        Write-Host ""
        if ($resumed) { Write-Host "接手了上一次留下的半成品（本機端 .writing 殘檔）。" }
        Write-Host "完成：本機已補上 projectUuid $driveUuid"
        exit $script:ExitOk
    }

    if ($localUuid -and -not $driveUuid) {
        # 反過來的情境：本機已有 UUID，Drive 端缺。這支工具自己一律先寫 Drive 再寫
        # 本機，正常操作不會走到這裡——出現代表 Drive 端的 origin.json 曾經遺失或被
        # 別的流程動過。此刻只有一個候選值（本機的），不是衝突，補回 Drive 即可。
        $displayNameToUse = if ($localDisplayName) { $localDisplayName }
                             elseif ($driveDisplayName) { $driveDisplayName }
                             else { $folderName }

        Write-Host "計畫：本機已有身分，Drive 端缺（Drive 端 origin.json 遺失或未曾寫入）。"
        Write-Host "  → 把本機既有的 UUID 補回 Drive 端；不產生新的。"
        Show-FleetBundlePremise
        if (-not $Confirmed) {
            Write-Host ""
            Write-Host "還沒動手。確定的話加上 -Confirmed 重跑。"
            exit $script:ExitNeedsYou
        }

        $resumed = Write-DriveOrigin -ProjectDrivePath $projectDrivePath -ProjectId $projectId `
            -Remote $remoteNow -MainBranch $branchNow `
            -ProjectUuid $localUuid -DisplayName $displayNameToUse
        Confirm-DriveOriginWrite -ProjectDrivePath $projectDrivePath -ExpectedUuid $localUuid
        Write-Host ""
        if ($resumed) { Write-Host "接手了上一次留下的半成品（Drive 端 .writing 殘檔）。" }
        Write-Host "完成：Drive 端已補上 projectUuid $localUuid"
        exit $script:ExitOk
    }

    # --- 兩端都沒有：全新遷移 -----------------------------------------------
    $displayNameToUse = if ($localDisplayName) { $localDisplayName }
                         elseif ($driveDisplayName) { $driveDisplayName }
                         else { $folderName }

    Write-Host "計畫：兩端都沒有 projectUuid，這是一個舊(v1)專案。"
    Write-Host "  → 產生新的 UUID，先寫 Drive 端，再寫本機端（ADR-0003）。"
    Write-Host "  → 不搬動 Drive 端目錄，不改變 projectId（$projectId 維持原格式）。"
    Show-FleetBundlePremise
    if (-not $Confirmed) {
        Write-Host ""
        Write-Host "還沒動手。確定的話加上 -Confirmed 重跑。"
        exit $script:ExitNeedsYou
    }

    $newUuid = New-ProjectUuid
    $driveResumed = Write-DriveOrigin -ProjectDrivePath $projectDrivePath -ProjectId $projectId `
        -Remote $remoteNow -MainBranch $branchNow `
        -ProjectUuid $newUuid -DisplayName $displayNameToUse
    # 寫完 Drive 端之後立刻回讀確認——另一台裝置可能幾乎同時也在遷移（ADR-0003）。
    # 不是自己剛寫的那一顆就停手，本機端這一半不寫。
    Confirm-DriveOriginWrite -ProjectDrivePath $projectDrivePath -ExpectedUuid $newUuid
    # Drive 端寫完並確認過才寫本機——中間這道縫被斷電或砍行程打斷的話，重跑會落到
    # 上面「Drive 有、本機沒有」那個分支，採用剛寫好的 $newUuid，不會再產生第二個。
    $localResumed = Write-LocalIdentity -ProjectRoot $ProjectRoot -Manifest $manifest -ProjectUuid $newUuid -DisplayName $displayNameToUse

    Write-Host ""
    if ($driveResumed -or $localResumed) { Write-Host "接手了上一次留下的半成品（.writing 殘檔）。" }
    Write-Host "完成：projectUuid $newUuid 已寫入兩端。"
    exit $script:ExitOk
}
catch {
    Write-Host "遷移失敗：$($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    exit $script:ExitFailed
}
