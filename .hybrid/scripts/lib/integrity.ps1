# Drive 端素材的完整性：checksum manifest 的讀寫、掃描與比對，以及備份清單
# （第二備份接口）的讀取。
#
# 只掃「素材」（AssetsDirName），絕不掃「衍生品」（DerivedDirName）——衍生品可以從
# 專案內的來源檔重新產生，不是不可變素材，把它們納入 checksum 追蹤只會在它們被正常
# 重新產生時製造假警報（CONTEXT.md「外部素材」與「衍生品」的分界；票 27 驗收條件
# 「不把衍生品誤當不可變素材」）。呼叫端負責只把 AssetsPath 傳進來，這個模組本身不
# 認識 DerivedDirName。
#
# manifest 與備份清單都放在 Drive 端專案資料夾底下的 integrity\ 子資料夾，跟
# origin.json／lease.json 同一層（不在 素材\ 或 衍生品\ 裡面）：
#   * 這是關於 Drive 端資料的營運中繼資料，不是專案內容本身，跟 origin.json／
#     lease.json 性質相同——放進 素材\ 會被自己的下一次掃描當成一個素材檔案，
#     放進 衍生品\ 則暗示它可以被任意重新產生，但 manifest 一旦被覆寫，舊版本
#     記錄的「上一次的狀態」就回不來了，不是真正意義上的衍生品。
#   * 存在 Drive（而不是進 git）：manifest 描述的是 _drive/ 底下的內容，而
#     _drive/ 本身完全不進 git（ADR-0001）。放進 git 的話，任何一台裝置產生的
#     manifest 都要額外走一次 commit/push/pull 才能被別台看到，而它描述的素材
#     本身不受 git 保護，兩者分開放毫無意義。放在 Drive 端則跟隨 Drive 本身的
#     同步——時點一樣不可觀測，但至少所有裝置看的是同一份檔案，不需要 git 這一層。
#
# 備份清單（backups.json）是「第二備份」的**介面**，不是備份系統本身——這個 repo
# 沒有產生備份的工具（票 27 範圍明寫：定義接口＋dry-run，不是實作備份程式）。這個
# 模組只讀它，從不寫它；由使用者或外部工具維護內容。

Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'paths.ps1')

$script:IntegrityDirName       = 'integrity'
$script:AssetsManifestFileName = 'assets-manifest.json'
$script:BackupListFileName     = 'backups.json'

function Get-IntegrityDrivePath {
    param([Parameter(Mandatory)][string]$ProjectDrivePath)
    return (Join-Path $ProjectDrivePath $script:IntegrityDirName)
}

function Get-AssetsManifestPath {
    param([Parameter(Mandatory)][string]$ProjectDrivePath)
    return (Join-Path (Get-IntegrityDrivePath -ProjectDrivePath $ProjectDrivePath) $script:AssetsManifestFileName)
}

function Get-BackupListPath {
    param([Parameter(Mandatory)][string]$ProjectDrivePath)
    return (Join-Path (Get-IntegrityDrivePath -ProjectDrivePath $ProjectDrivePath) $script:BackupListFileName)
}

function Read-AssetsManifest {
    # 三態回傳，跟 Read-DriveOrigin 同一個道理：檔案不存在 → `$null`；存在但解析
    # 失敗（同步中的殘檔、部分寫入、損毀）→ `New-UnreadableMarker`；讀到 → 解析後
    # 的物件。呼叫端要分辨「讀不動」必須用 `Test-Unreadable`，不能靠 `$null` 比對。
    param([Parameter(Mandatory)][string]$ProjectDrivePath)
    $path = Get-AssetsManifestPath -ProjectDrivePath $ProjectDrivePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return (New-UnreadableMarker) }
}

function Write-AssetsManifestAtomic {
    # 原子寫入（ADR-0007 不變量 6）：先寫暫存檔再 Move-Item，跟 Write-DriveOrigin
    # （paths.ps1）同一個手法。回傳是否接手了上一次寫到一半留下的半成品——不變量
    # 5(b) 要求這件事被說出來，由呼叫端印出來，不能悶掉。
    param(
        [Parameter(Mandatory)][string]$ProjectDrivePath,
        [Parameter(Mandatory)]$Manifest
    )
    $finalPath = Get-AssetsManifestPath -ProjectDrivePath $ProjectDrivePath
    $dir = Split-Path -Parent $finalPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $temp = "$finalPath.writing"
    $resumedStalePartial = Test-Path -LiteralPath $temp
    if ($resumedStalePartial) { Remove-Item -LiteralPath $temp -Force }
    Write-Utf8NoBom -Path $temp -Content (ConvertTo-Json $Manifest -Depth 6)
    Move-Item -LiteralPath $temp -Destination $finalPath -Force
    return $resumedStalePartial
}

function Read-BackupList {
    # 同樣三態回傳。這個模組只讀，從不寫——內容由使用者或外部備份工具維護。
    param([Parameter(Mandatory)][string]$ProjectDrivePath)
    $path = Get-BackupListPath -ProjectDrivePath $ProjectDrivePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return (New-UnreadableMarker) }
}

function Get-RelativeAssetPath {
    # AssetsPath 底下的相對路徑，一律用正斜線——跟 manifest 裡存的格式一致，也不受
    # 裝置的磁碟機代號或掛載路徑影響（可攜、可跨裝置比對）。
    param(
        [Parameter(Mandatory)][string]$AssetsPath,
        [Parameter(Mandatory)][string]$FullPath
    )
    $root = (Get-NormalisedPath $AssetsPath)
    $relative = $FullPath.Substring($root.Length).TrimStart('\')
    return ($relative -replace '\\', '/')
}

function Get-AssetFileScan {
    # 掃描素材目錄底下的所有檔案並逐一算 SHA256。
    #
    # 回傳 pscustomobject { Files; Unreadable }：
    #   Files      —— @{ Path; Sha256; Size } 陣列，依 Path 排序。
    #   Unreadable —— @{ Path; Reason } 陣列，依 Path 排序。檔案存在但算不出雜湊
    #     （鎖住、或 Google Drive 虛擬磁碟的雲端佔位檔還在下載中）——這跟「檔案
    #     不存在」是不同的狀態，不能吞成同一種（ADR-0003「讀不到不等於沒有」的
    #     同一個原則，套用在檔案內容而不是 JSON 設定檔上）。
    param([Parameter(Mandatory)][string]$AssetsPath)

    $files = New-Object System.Collections.ArrayList
    $unreadable = New-Object System.Collections.ArrayList

    $items = @(Get-ChildItem -LiteralPath $AssetsPath -File -Recurse -Force -ErrorAction SilentlyContinue)
    foreach ($item in $items) {
        $relative = Get-RelativeAssetPath -AssetsPath $AssetsPath -FullPath $item.FullName
        try {
            $hash = Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256
            [void]$files.Add([pscustomobject]@{
                Path   = $relative
                Sha256 = $hash.Hash.ToLowerInvariant()
                Size   = $item.Length
            })
        } catch {
            [void]$unreadable.Add([pscustomobject]@{
                Path   = $relative
                Reason = $_.Exception.Message
            })
        }
    }

    return [pscustomobject]@{
        Files      = @($files | Sort-Object -Property Path)
        Unreadable = @($unreadable | Sort-Object -Property Path)
    }
}

function Get-AssetManifestId {
    # 這份素材狀態的指紋：對排序後的 (path, sha256) 清單算 SHA256。刻意不含
    # generatedAt／generatedBy 這些中繼資料——只要檔案內容與清單相同，不論哪一台
    # 裝置、什麼時候產生，manifestId 都一樣。備份清單（backups.json）的
    # coversAssetsSnapshotOf 用它標記「這份備份對應素材的哪個狀態」，不必依賴容易
    # 出錯的時間戳記比對。
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Files)
    $lines = @($Files | ForEach-Object { "$($_.Path)`t$($_.Sha256)" })
    $joined = $lines -join "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($joined)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
        return -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    } finally {
        $sha256.Dispose()
    }
}

function Compare-AssetManifest {
    # 拿「manifest 記錄的狀態」跟「現在掃描到的狀態」比對，分成四類（票 27 驗收
    # 條件「新增、遺失、內容變更可分辨」，外加誠實地把「讀不到」單獨列出來，不
    # 吞進另外三類的任何一類）：
    #
    #   Added      —— 現在有，manifest 沒有記錄過。
    #   Missing    —— manifest 記錄過，現在掃描不到，而且不是因為讀不動
    #                 （見下方 CurrentUnreadable 的排除規則）。呼叫端必須把它當成
    #                 「可能被刪、也可能還沒同步下來」——這個函式本身分不出來，也
    #                 不負責措辭（那是呼叫端的事）。
    #   Changed    —— 兩邊都有，但 Sha256 不同。
    #   Unchanged  —— 兩邊都有，Sha256 相同。
    #
    # CurrentUnreadable 直接透傳（呼叫端已經知道是誰）；同一個路徑如果既在
    # manifest 裡、現在又讀不到，算進 Unreadable、不算進 Missing——「讀不到」跟
    # 「真的不見了」不是同一件事，含混地當成 Missing 會讓使用者以為檔案已經確定
    # 消失，而其實可能只是暫時打不開。
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ManifestFiles,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$CurrentFiles,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$CurrentUnreadable
    )

    $manifestByPath = @{}
    foreach ($f in $ManifestFiles) { $manifestByPath[$f.Path] = $f }
    $currentByPath = @{}
    foreach ($f in $CurrentFiles) { $currentByPath[$f.Path] = $f }
    $unreadablePaths = @{}
    foreach ($u in $CurrentUnreadable) { $unreadablePaths[$u.Path] = $true }

    $added = New-Object System.Collections.ArrayList
    $changed = New-Object System.Collections.ArrayList
    $unchanged = New-Object System.Collections.ArrayList
    $missing = New-Object System.Collections.ArrayList

    foreach ($path in $currentByPath.Keys) {
        if (-not $manifestByPath.ContainsKey($path)) {
            [void]$added.Add($currentByPath[$path])
        } elseif ($manifestByPath[$path].Sha256 -ne $currentByPath[$path].Sha256) {
            [void]$changed.Add([pscustomobject]@{
                Path      = $path
                OldSha256 = $manifestByPath[$path].Sha256
                NewSha256 = $currentByPath[$path].Sha256
            })
        } else {
            [void]$unchanged.Add($currentByPath[$path])
        }
    }
    foreach ($path in $manifestByPath.Keys) {
        if (-not $currentByPath.ContainsKey($path) -and -not $unreadablePaths.ContainsKey($path)) {
            [void]$missing.Add($manifestByPath[$path])
        }
    }

    return [pscustomobject]@{
        Added      = @($added | Sort-Object -Property Path)
        Missing    = @($missing | Sort-Object -Property Path)
        Changed    = @($changed | Sort-Object -Property Path)
        Unreadable = @($CurrentUnreadable | Sort-Object -Property Path)
        Unchanged  = @($unchanged | Sort-Object -Property Path)
    }
}
