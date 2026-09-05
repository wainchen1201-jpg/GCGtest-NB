<#
.SYNOPSIS
    比對／建立 Drive 端「素材」的 checksum manifest，找出新增、遺失、內容變更的檔案。

.DESCRIPTION
    只掃描 素材（AssetsDir），絕不掃描 衍生品（DerivedDir）——衍生品可以從專案內的
    來源檔重新產生，不是不可變素材（CONTEXT.md）。manifest 存在 Drive 端專案資料夾
    底下的 integrity\assets-manifest.json，跟 origin.json／lease.json 同一層，理由見
    scripts\lib\integrity.ps1 檔頭。

    這支腳本只讀與報告，絕不刪除、搬移或覆寫任何素材檔案（ADR-0007 不變量 3）。唯一
    會被寫入的是 manifest 本身，而且只在帶 -Generate 時才寫，並且是原子寫入（不變量
    6）。

    「遺失」在這裡分不出兩種情況：檔案被使用者刪除，或者 Google Drive 還沒把它同步
    下來——兩者要求相反的動作（前者什麼都不用做，後者應該等待），本工具不會替你猜，
    輸出裡會把這個限制明講。

.PARAMETER ProjectRoot
    專案在本機的位置。預設為目前目錄。

.PARAMETER DriveRoot
    Drive 端的根目錄。省略時依「本機設定檔 → 自動偵測」的順序解析。

.PARAMETER Generate
    把現在掃描到的狀態寫成新的 manifest 基準線。寫入前一樣會先比對舊 manifest（如果
    有的話）並印出差異——所以就算是要接受新的基準線，仍然看得到「跟上一版比起來變了
    什麼」。有任何檔案讀不到（Unreadable）時拒絕寫入：用不完整的掃描結果覆蓋基準線，
    等於讓那些檔案從此不再被追蹤，卻不會有任何訊息告訴你。

    有檔案在基準線裡、現在掃描不到（Missing）時同樣拒絕寫入，除非明確加上
    -AcceptMissing（票 30）。

.PARAMETER AcceptMissing
    承認「遺失的那些檔案確實不在了」，允許 -Generate 把它們從基準線裡拿掉。

    這是破壞性的：舊 manifest 沒有備份，覆寫之後那筆紀錄回不來。所以跟收工的
    -DriveSynced、撤離的 -Confirmed 一樣，要人明講——工具分不出「被刪掉」與
    「還沒同步下來」，而那兩者要求相反的動作。

.OUTPUTS
    exit 0 = 完成，沒有需要你判斷的事；1 = 失敗；2 = 停下來了，需要你判斷
    （出現差異、缺少基準線、讀不到既有的 manifest／Drive 端目錄，或有遺失的
    檔案而沒有加 -AcceptMissing）。
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$DriveRoot,
    [switch]$Generate,
    [switch]$AcceptMissing
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $OutputEncoding

. (Join-Path $PSScriptRoot 'lib\paths.ps1')
. (Join-Path $PSScriptRoot 'lib\integrity.ps1')

function Write-FileList {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Items, [Parameter(Mandatory)][scriptblock]$Format)
    foreach ($item in $Items) { Write-Host "  * $(& $Format $item)" }
}

try {
    $ProjectRoot = Resolve-ExistingProjectRoot -ProjectRoot $ProjectRoot

    # --- 讀本機端專案身分 ---------------------------------------------------
    $manifest = Read-ProjectManifest -ProjectRoot $ProjectRoot
    if (Test-Unreadable $manifest) {
        Write-Host "$(Get-ProjectManifestPath -ProjectRoot $ProjectRoot) 存在但無法解析（讀不動），可能還在同步中、暫時讀不到，也可能是內容損毀。"
        Write-Host "確認檔案內容之後再重跑；如果懷疑是同步問題，等 Drive 同步完成再重跑。"
        exit $script:ExitNeedsYou
    }
    if (-not $manifest) {
        Write-Host "$ProjectRoot 還不是 hybrid workspace 專案（找不到 .hybrid\project.json）。"
        Write-Host "請先執行 initialise.ps1 或 startup.ps1。"
        exit $script:ExitFailed
    }
    $projectId = [string]$manifest.projectId
    $assetsDirName = Get-PropertyOrDefault -InputObject $manifest -Name 'assetsDir' -Default $script:AssetsDirName

    # --- 解析 Drive 掛載點 ---------------------------------------------------
    $resolved = Resolve-DriveRoot -ProjectRoot $ProjectRoot -DriveRoot $DriveRoot
    if (Test-Unreadable $resolved) {
        Write-Host "$(Get-LocalConfigPath -ProjectRoot $ProjectRoot) 存在但無法解析（讀不動），可能還在同步中、暫時讀不到，也可能是內容損毀。"
        Write-Host "確認檔案內容之後再重跑，或以 -DriveRoot 明確指定要用哪個掛載點。"
        exit $script:ExitNeedsYou
    }
    if (-not $resolved) {
        Write-Host "找不到 Google Drive 的掛載點，無法解析 Drive 端的素材目錄。"
        Write-Host "請以 -DriveRoot 指定，或確認 Google Drive 已經在這台裝置上登入。"
        exit $script:ExitNeedsYou
    }
    if (-not (Test-Path -LiteralPath $resolved.Path -PathType Container)) {
        Write-Host "Drive 端路徑不存在：$($resolved.Path)（來源：$($resolved.Source)）"
        Write-Host "請確認 Google Drive 已掛載，或以 -DriveRoot 指定正確的路徑。"
        exit $script:ExitNeedsYou
    }

    $projectDrivePath = Get-ProjectDrivePath -DriveRoot $resolved.Path -ProjectId $projectId

    # --- 「不在」的兩種不可分辨的原因：先擋在這裡，不往下猜 -------------------
    # 專案資料夾或素材資料夾本身不存在時，不去掃一個「空的」結果冒充「素材都不見
    # 了」——那極可能只是 Google Drive 還沒把整個資料夾同步下來，或掛載點解析錯誤，
    # 不是真的遺失。這面鏡射 startup.ps1「Drive 端資料夾不見」段落的判斷（ADR-0004）。
    if (-not (Test-Path -LiteralPath $projectDrivePath -PathType Container)) {
        Write-Host "停下來了：Drive 端找不到這個專案的資料夾。"
        Write-Host "  該在的位置：$projectDrivePath"
        Write-Host ""
        Write-Host "「不在」在這裡分不出兩種情況：Google Drive 還沒把它同步下來，或者這個專案"
        Write-Host "的 Drive 資料夾真的被刪掉了——兩者要求相反的動作，本工具不會替你猜，也不會"
        Write-Host "建立、修改或刪除任何東西。"
        Write-Host "請等 Drive 同步完成再重跑；懷疑是真的被刪，請找別台裝置或 Drive 網頁版確認。"
        exit $script:ExitNeedsYou
    }
    $assetsPath = Join-Path $projectDrivePath $assetsDirName
    if (-not (Test-Path -LiteralPath $assetsPath -PathType Container)) {
        Write-Host "停下來了：素材資料夾不存在：$assetsPath"
        Write-Host ""
        Write-Host "同樣分不出「還沒同步」跟「被刪掉」——本工具不會替你猜，也不會建立這個資料夾。"
        Write-Host "確認 Google Drive 同步狀態，或到別台裝置／Drive 網頁版確認素材資料夾還在，再重跑。"
        exit $script:ExitNeedsYou
    }

    # --- 掃描現況 -------------------------------------------------------------
    Write-Host "掃描素材：$assetsPath"
    $scan = Get-AssetFileScan -AssetsPath $assetsPath
    Write-Host "  找到 $($scan.Files.Count) 個檔案"
    if ($scan.Unreadable.Count -gt 0) {
        Write-Host "  $($scan.Unreadable.Count) 個檔案讀不到（可能是雲端佔位檔還在下載，或被其他程式鎖住）："
        Write-FileList -Items $scan.Unreadable -Format { param($u) "$($u.Path)：$($u.Reason)" }
    }
    Write-Host ""

    # --- 讀既有 manifest --------------------------------------------------
    $existingManifest = Read-AssetsManifest -ProjectDrivePath $projectDrivePath
    if (Test-Unreadable $existingManifest) {
        Write-Host "停下來了：既有的 manifest 存在但無法解析（讀不動）。"
        Write-Host "  $(Get-AssetsManifestPath -ProjectDrivePath $projectDrivePath)"
        Write-Host ""
        Write-Host "可能還在同步中，也可能已經損毀——不會覆蓋它，確認內容之後再重跑；"
        Write-Host "確定要放棄舊 manifest 的話，手動刪除那個檔案之後再用 -Generate 重建。"
        exit $script:ExitNeedsYou
    }

    $diff = $null
    if (-not $existingManifest) {
        if (-not $Generate) {
            Write-Host "這個專案還沒有 manifest 基準線，沒有東西可以比對。"
            Write-Host "加上 -Generate 先建立一份基準線，之後才能用 drive-verify 偵測差異。"
            exit $script:ExitNeedsYou
        }
        Write-Host "首次建立 manifest，沒有舊版本可比對。"
    } else {
        $manifestFiles = @($existingManifest.files | ForEach-Object {
            [pscustomobject]@{ Path = [string]$_.path; Sha256 = [string]$_.sha256; Size = [int64]$_.size }
        })
        $diff = Compare-AssetManifest -ManifestFiles $manifestFiles -CurrentFiles $scan.Files -CurrentUnreadable $scan.Unreadable
    }

    # --- 報告差異 ---------------------------------------------------------
    $hasDiff = $false
    if ($diff) {
        Write-Host "新增：$($diff.Added.Count)"
        Write-FileList -Items $diff.Added -Format { param($i) $i.Path }

        Write-Host "內容變更：$($diff.Changed.Count)"
        Write-FileList -Items $diff.Changed -Format { param($i) "$($i.Path)（$($i.OldSha256.Substring(0,8)) → $($i.NewSha256.Substring(0,8))）" }

        Write-Host "遺失：$($diff.Missing.Count)"
        if ($diff.Missing.Count -gt 0) {
            Write-FileList -Items $diff.Missing -Format { param($i) $i.Path }
            Write-Host ""
            Write-Host "  「遺失」在這裡分不出兩種情況：這台裝置的 Google Drive 還沒把它同步下來，"
            Write-Host "  或者檔案真的被刪掉了——兩者要求相反的動作，本工具不會替你猜，也不會自動"
            Write-Host "  處理。請先確認 Google Drive 同步狀態；如果懷疑是真的遺失，可以用"
            Write-Host "  drive-restore.ps1 看依目前設定的第二備份清單能不能找回來（那支也只會"
            Write-Host "  列出該做什麼，不會自動動手）。"
        }

        Write-Host "不變：$($diff.Unchanged.Count)"
        $hasDiff = ($diff.Added.Count -gt 0 -or $diff.Missing.Count -gt 0 -or $diff.Changed.Count -gt 0 -or $diff.Unreadable.Count -gt 0)
        Write-Host ""
    }

    # --- 建立新基準線 -------------------------------------------------------
    if ($Generate) {
        if ($scan.Unreadable.Count -gt 0) {
            Write-Host "停下來了：$($scan.Unreadable.Count) 個檔案讀不到，-Generate 不會用不完整的掃描結果覆蓋 manifest。"
            Write-Host "那樣會讓這些檔案從基準線裡悄悄消失，之後也不會再被追蹤。"
            Write-Host "等它們變成可讀（例如 Google Drive 同步／下載完成，或解除鎖定）之後再重跑。"
            exit $script:ExitNeedsYou
        }

        # 【票 30 對抗審查】上面那道守衛擋的是「讀不到」，而「遺失」原本沒有同一道。
        # 於是素材被刪（或 Drive 那一側同步出問題）之後跑一次 -Generate，
        # 那些檔案就從基準線裡消失了——而 integrity.ps1 自己的註解寫著
        # 「manifest 一旦被覆寫，舊版本記錄的『上一次的狀態』就回不來了」。
        #
        # 最糟的是它在覆寫之前才剛印過這段話：
        #   「『遺失』在這裡分不出兩種情況……本工具不會替你猜，也不會自動處理。」
        # **然後它就處理了。** 訊息說不替你決定，接著就替你決定了——
        # 這正是這條線一路在拆的無聲失效第二形態，只是這次出現在結構上而不是措辭上。
        #
        # 照這個 repo 既有的慣例辦：破壞性的那一半要明講（收工要 -DriveSynced、
        # 撤離要 -Confirmed）。預設拒絕，要接受就加 -AcceptMissing。
        if ($diff -and $diff.Missing.Count -gt 0 -and -not $AcceptMissing) {
            Write-Host "停下來了：有 $($diff.Missing.Count) 個檔案在基準線裡、現在掃描不到，-Generate 不會直接覆寫。"
            Write-Host "覆寫之後它們會從基準線裡消失，而舊的 manifest 沒有備份——那筆紀錄就回不來了。"
            Write-Host ""
            Write-Host "先確認它們是哪一種："
            Write-Host "  * Google Drive 還沒同步下來 → 等同步完成再重跑，不要接受"
            Write-Host "  * 真的被刪掉了、而且那是你要的 → 加上 -AcceptMissing 重跑"
            Write-Host "  * 真的被刪掉了、但不是你要的 → 先用 drive-restore.ps1 看能不能找回來"
            exit $script:ExitNeedsYou
        }

        $manifestData = [ordered]@{
            schemaVersion = 1
            projectId     = $projectId
            assetsDir     = $assetsDirName
            generatedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
            generatedBy   = $env:COMPUTERNAME
            manifestId    = (Get-AssetManifestId -Files $scan.Files)
            files         = @($scan.Files | ForEach-Object { [ordered]@{ path = $_.Path; sha256 = $_.Sha256; size = $_.Size } })
        }
        $resumed = Write-AssetsManifestAtomic -ProjectDrivePath $projectDrivePath -Manifest $manifestData
        if ($resumed) { Write-Host "接手了上一次寫到一半的 manifest 殘檔，已重新完整寫入。" }
        Write-Host "manifest 已更新：$(Get-AssetsManifestPath -ProjectDrivePath $projectDrivePath)"
        Write-Host "  收錄 $($scan.Files.Count) 個檔案，manifestId：$($manifestData.manifestId)"
        exit $script:ExitOk
    }

    if ($hasDiff) { exit $script:ExitNeedsYou }
    Write-Host "跟基準線一致，沒有差異。"
    exit $script:ExitOk
}
catch {
    Write-Host "drive-verify 失敗：$($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    exit $script:ExitFailed
}
