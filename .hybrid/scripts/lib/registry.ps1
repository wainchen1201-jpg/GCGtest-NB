# 心跳清單：這台機器上有哪些專案需要被心跳照顧。
#
# 它是機器層級的東西，所以住在機器層級的位置，不在任何專案裡——專案資料夾會被
# 改名、搬走、刪掉，那正是這份清單要解決的問題（票 11）。
#
# 清單只記路徑，不記狀態。專案還在不在、是不是 git repo、有沒有變更，全部由派工器
# 在執行當下判斷。清單過期不會造成錯誤，只會讓派工器跳過一筆。

Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'paths.ps1')

function Get-HeartbeatHome {
    # 機器層級的家目錄。可覆寫是為了測試——跟 -ProjectRoot／-DriveRoot 同一個慣例，
    # 測試傳暫存路徑，絕不碰使用者真實的清單。
    param([string]$ListPath)
    if ($ListPath) { return (Get-NormalisedPath $ListPath) }

    # 排程器啟動的行程不保證帶著完整的使用者環境變數。LOCALAPPDATA 是空的時候，
    # Join-Path 會做出一個相對路徑，Test-Path 落空，清單「查無此檔」——於是心跳
    # 安靜地什麼都不做而且回報成功。實測發生過：手動跑得到 1 個專案，排程觸發
    # 的每一次都是 0 個專案。
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = Join-Path $env:USERPROFILE 'AppData\Local' }
    if (-not $base) { throw '找不到 LOCALAPPDATA 也找不到 USERPROFILE，無法決定心跳清單的位置' }
    return (Join-Path $base 'hybrid-workspace')
}

function Get-ProjectListPath {
    param([string]$ListPath)
    return (Join-Path (Get-HeartbeatHome -ListPath $ListPath) 'projects.json')
}

function Read-ProjectList {
    # **逐筆送出**，不要 `return @(...)`。
    #
    # 從函式回傳陣列時，PowerShell 在某些呼叫路徑上不會把它展開，整個陣列會被當成
    # 一個元素——結果是清單被寫成 [[{...}]]，比對 path 全部落空、去重失效。實測踩到
    # 兩次才定位到這裡。呼叫端一律用 @(Read-ProjectList ...) 收。
    #
    # 檔案不存在 = 這台還沒登記任何專案，安靜回空的。
    # 但檔案在卻讀不動要**丟例外**——那跟「沒有專案」是完全不同的兩件事。
    param([string]$ListPath)

    $path = Get-ProjectListPath -ListPath $ListPath
    # 檔案不存在 = 這台還沒登記任何專案，是正常狀態，安靜回空的。
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if (-not $raw.Trim()) { return }
        $parsed = $raw | ConvertFrom-Json
    } catch {
        # 檔案在但讀不動——**這跟「沒有專案」是完全不同的兩件事**。
        # 靜靜回空的話，排程會「成功地什麼都不做」，而且看起來一切正常。
        throw "心跳清單讀不動（$path）：$($_.Exception.Message)"
    }
    if ($null -eq $parsed) { return }
    foreach ($item in @($parsed)) { $item }
}

function Write-ProjectList {
    param(
        [string]$ListPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Entries
    )
    $path = Get-ProjectListPath -ListPath $ListPath
    # PS 5.1 沒有 -AsArray，而 ConvertTo-Json 有時會把單元素陣列退化成裸物件。
    # 所以看輸出實際長什麼樣再決定要不要補中括號——不要憑元素個數猜（猜錯就變成
    # [[{...}]]，讀回來多一層，是實測踩到的）。
    $json = if ($Entries.Count -eq 0) { '[]' } else { ConvertTo-Json @($Entries) -Depth 4 }
    if (-not $json.TrimStart().StartsWith('[')) { $json = "[`r`n$json`r`n]" }

    # 原子寫入：先寫暫存檔再換過去。清單會被背景排程隨時讀取，直接覆寫的話
    # 讀取者可能撞見寫到一半的檔案——實測發生過一次排程看到「0 個專案」。
    $temp = "$path.writing"
    Write-Utf8NoBom -Path $temp -Content $json
    Move-Item -LiteralPath $temp -Destination $path -Force
}

function Add-ProjectToList {
    # 冪等：同一個路徑加幾次都只有一筆。回傳是否真的新增了。
    param(
        [string]$ListPath,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ProjectId
    )
    $normalised = Get-NormalisedPath $ProjectRoot

    # 用 ArrayList 明確攤平。PS 5.1 的 `@(...)` + `+=` 在某些路徑上會做出「陣列裡
    # 包著一個陣列」，ConvertTo-Json 就把它序列化成 {value, Count}，之後比對 path
    # 全部落空、去重失效。這是實測踩到的，不要改回 += 的寫法。
    $entries = New-Object System.Collections.ArrayList
    foreach ($e in @(Read-ProjectList -ListPath $ListPath)) {
        if ($null -eq $e) { continue }
        $existing = Get-PropertyOrDefault -InputObject $e -Name 'path' -Default ''
        if ($existing -and ((Get-NormalisedPath $existing) -eq $normalised)) { return $false }
        [void]$entries.Add($e)
    }

    [void]$entries.Add([pscustomobject]@{
        projectId = $ProjectId
        path      = $normalised
        addedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    })
    Write-ProjectList -ListPath $ListPath -Entries $entries.ToArray()
    return $true
}

function Get-DeviceIdPath {
    # 持久裝置識別的存放位置——跟 projects.json／runtime 同一個家（機器層級），
    # 走既有的 -ListPath 接縫（票 26；ADR-0006 deviceId 欄位說明；不變量 13）。
    param([string]$ListPath)
    return (Join-Path (Get-HeartbeatHome -ListPath $ListPath) 'device.json')
}

function Get-OrCreatePersistentDeviceId {
    # 首次安裝／首次使用時鑄一顆 GUID 並存起來，之後每次讀取都拿同一顆——這是
    # ADR-0006 deviceId 欄位「重灌之後同名會碰撞」要解決的問題的另一半：deviceId
    # 本身必須不受重灌影響地留在機器上。
    #
    # 讀不動（同步中的殘檔、內容損毀——雖然這個檔案是本機檔案，理論上不該遇到
    # Drive 那種同步問題，但防毒鎖檔、寫到一半斷電仍然可能發生）時**不生新的**：
    # 悄悄換一顆新 deviceId 會讓這台機器手上所有既有租約的所有權判定全部失真
    # （原本判 self 的，deviceId 換了就退回比對 deviceName，仍然安全，但已經不是
    # 「同一顆」的原意了）。所以讀不動就丟例外，讓呼叫端的既有錯誤處理接手，
    # 不要在這裡用猜測覆蓋掉可能仍然有效的內容（ADR-0003「讀不到不等於沒有」
    # 同一個道理，套用在機器層級檔案上）。
    #
    # 沒有加檔案鎖：跟 Add-ProjectToList 同一個既有慣例（read-modify-write，
    # 本機 NTFS 檔案系統操作很快），這台機器上兩個行程幾乎同時第一次呼叫時
    # 理論上可能各自鑄一顆、後寫的覆蓋先寫的——但這只發生在「這台機器從沒產生過
    # deviceId」的那一次，之後的所有呼叫都是穩定的讀取。就算真的撞上，ADR-0006
    # 的比對規則本來就有 deviceName 這個退回，不會讓任何一份租約變得判不出來。
    param([string]$ListPath)
    $path = Get-DeviceIdPath -ListPath $ListPath
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
            $parsed = $raw | ConvertFrom-Json
        } catch {
            throw "裝置識別檔讀不動（$path）：$($_.Exception.Message)"
        }
        $existing = Get-PropertyOrDefault -InputObject $parsed -Name 'deviceId' -Default ''
        if ($existing) { return $existing }
        throw "裝置識別檔存在但沒有 deviceId 欄位（$path）"
    }

    $newId = [guid]::NewGuid().ToString().ToLowerInvariant()
    $content = ConvertTo-Json ([ordered]@{
        deviceId  = $newId
        createdAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    })
    $temp = "$path.writing"
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    Write-Utf8NoBom -Path $temp -Content $content
    Move-Item -LiteralPath $temp -Destination $path -Force
    return $newId
}

function Get-HeartbeatStatePath {
    param([string]$ListPath)
    return (Join-Path (Get-HeartbeatHome -ListPath $ListPath) 'state.json')
}

function Read-HeartbeatState {
    # 派工器對每個專案留下的嘗試與成敗紀錄（run-heartbeats.ps1 寫入）。
    # 檔案不存在或讀不動都安靜回空的 hashtable——這份狀態是輔助診斷用的，
    # 讀不到不該讓呼叫端（派工器本身、runtime-status.ps1）跟著失敗。
    param([string]$ListPath)
    $path = Get-HeartbeatStatePath -ListPath $ListPath
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if (-not $raw.Trim()) { return @{} }
        $obj = $raw | ConvertFrom-Json
        $map = @{}
        foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = $p.Value }
        return $map
    } catch { return @{} }
}

function Remove-ProjectFromList {
    # 回傳是否真的移除了。
    param(
        [string]$ListPath,
        [Parameter(Mandatory)][string]$ProjectRoot
    )
    $normalised = Get-NormalisedPath $ProjectRoot
    $kept = New-Object System.Collections.ArrayList
    $removed = $false

    foreach ($e in @(Read-ProjectList -ListPath $ListPath)) {
        if ($null -eq $e) { continue }
        $p = Get-PropertyOrDefault -InputObject $e -Name 'path' -Default ''
        if ($p -and ((Get-NormalisedPath $p) -eq $normalised)) {
            $removed = $true
            continue
        }
        [void]$kept.Add($e)
    }

    if (-not $removed) { return $false }
    Write-ProjectList -ListPath $ListPath -Entries $kept.ToArray()
    return $true
}
