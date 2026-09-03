# 路徑解析：專案 ID 的產生、Drive 掛載點的解析、本機覆寫設定檔的讀寫。
#
# 這個模組的注入點就是整套系統的測試接縫。掛載點的解析順序是：
#
#   1. 呼叫端顯式傳入的 -DriveRoot
#   2. 本機設定檔 .hybrid/local.json
#   3. 自動偵測 Google Drive 掛載點
#
# 測試走第 1 條，而第 1 條同時是正式環境「自動偵測失敗、使用者手動指定」走的路。
# 沒有任何只為測試存在的程式碼路徑。

Set-StrictMode -Version 2.0

$script:HybridDirName  = '.hybrid'
$script:DriveNamespace = '_hybrid'
$script:AssetsDirName  = '素材'
$script:DerivedDirName = '衍生品'
$script:DriveLinkName  = '_drive'

# 初始化產生的專案一律用這個分支名，不跟著各台裝置的 init.defaultBranch 走——
# 三台裝置要對得上。
$script:MainBranchName = 'master'

# 共用的 exit code 慣例：
#   0 完成
#   1 失敗
#   2 停下來了，需要使用者判斷（不是錯誤，是刻意不替他決定）
$script:ExitOk       = 0
$script:ExitFailed   = 1
$script:ExitNeedsYou = 2

function Get-NormalisedPath {
    # 去掉結尾的反斜線，但保留磁碟機根目錄的那一個——'H:' 在 Windows 是
    # 「H: 上的目前目錄」而不是根目錄。
    param([Parameter(Mandatory)][string]$Path)
    $trimmed = $Path.TrimEnd('\')
    if ($trimmed -match '^[A-Za-z]:$') { return $trimmed + '\' }
    return $trimmed
}

function Resolve-ExistingProjectRoot {
    # 解析 -ProjectRoot 並確認它存在。不存在就丟例外——但要說得出「解析成什麼」。
    #
    # 起因：使用者在提權視窗（起始目錄 C:\Windows\system32）打 -ProjectRoot "試點A"，
    # 拿到「找不到 '試點A' 路徑，因為它不存在」。那句話沒有錯，卻漏掉唯一有用的資訊
    # ——相對路徑是從哪裡解析的。使用者看著自己剛建好的 D:\試點A，第一反應會是
    # 工具壞了，而不是「我少打了 D:\」。
    #
    # 只有真的是相對路徑時才提這件事；路徑本來就是絕對的還硬扯相對路徑只會誤導。
    param([Parameter(Mandatory)][string]$ProjectRoot)

    if (Test-Path -LiteralPath $ProjectRoot) {
        return (Get-NormalisedPath (Resolve-Path -LiteralPath $ProjectRoot).Path)
    }

    if ([System.IO.Path]::IsPathRooted($ProjectRoot)) {
        throw "找不到專案目錄：$ProjectRoot"
    }

    $here = (Get-Location).Path
    $attempted = Join-Path $here $ProjectRoot
    throw ("找不到專案目錄：$ProjectRoot（相對路徑，從目前目錄 $here 解析成 $attempted）。" +
           "請改用完整路徑，例如 D:\你的專案。")
}

function Write-Utf8NoBom {
    # 產生的檔案一律不帶 BOM：JSON.parse 與部分 git 版本會被 BOM 絆倒。
    # （腳本自己則必須帶 BOM，理由見 scripts/README 或 encoding 測試。）
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}

function ConvertTo-ProjectSlug {
    # 資料夾名 → 小寫英數與連字號。專案 ID 的前半段就是這個。
    param([Parameter(Mandatory)][string]$Name)
    $slug = [regex]::Replace($Name.ToLowerInvariant(), '[^a-z0-9]+', '-').Trim('-')
    if (-not $slug) { $slug = 'project' }
    return $slug
}

function New-ProjectUuid {
    # 身分的來源。RFC 4122 v4，小寫、不帶括號。不從名稱、日期或裝置推導，
    # 產生之後永不改變（ADR-0003）。
    return ([guid]::NewGuid().ToString().ToLowerInvariant())
}

function New-ProjectId {
    # 專案 ID 一旦產生就不再變動，之後改專案名稱不影響 Drive 端的對應關係。
    # 格式是 <slug>-<yyyyMMdd>-<uuid 前 8 碼>；碰撞安全來自 UUID 後綴，不來自 slug
    # （ADR-0003）——slug 退化成 'project' 是可以接受的，不做中文轉寫。
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$ProjectUuid,
        [datetime]$Date = (Get-Date)
    )
    $uuidPrefix = $ProjectUuid.Substring(0, 8)
    return ('{0}-{1}-{2}' -f (ConvertTo-ProjectSlug -Name $ProjectName), $Date.ToString('yyyyMMdd'), $uuidPrefix)
}

function Get-DriveOriginPath {
    # Drive 端的指標檔：不靠 git 也讀得到「這個專案的 repo 在哪」。
    # 它跟租約住在一起，因為兩者性質相同——都是換裝置時需要、但又不能放進 git 的事。
    param([Parameter(Mandatory)][string]$ProjectDrivePath)
    return (Join-Path $ProjectDrivePath 'origin.json')
}

function New-UnreadableMarker {
    # 「檔案存在但解析失敗」的哨兵物件。跟 $null（檔案不存在）與正常解析後的物件是
    # 三種不同的狀態——舊版把前兩者都吞成 `$null`，於是「讀不到」被當成「沒有值」
    # 動手寫，覆蓋掉唯一一份證據（ADR-0003：「讀不到不等於沒有」）。
    return [pscustomobject]@{ HybridUnreadable = $true }
}

function Test-Unreadable {
    # 呼叫端必須用這個函式判斷「讀不動」，不能靠 `$null` 比對——那正是三態被吞成
    # 兩態的地方。
    param($Value)
    return [bool]($Value -and ($Value -is [System.Management.Automation.PSCustomObject]) -and $Value.PSObject.Properties['HybridUnreadable'])
}

function Read-DriveOrigin {
    # 三態回傳：檔案不存在 → `$null`；檔案在但解析失敗（同步中的殘檔、部分寫入、
    # 損毀）→ `New-UnreadableMarker`；讀到 → 解析後的物件。呼叫端要分辨「讀不動」
    # 必須用 `Test-Unreadable`，不能靠 `$null` 比對。
    param([Parameter(Mandatory)][string]$ProjectDrivePath)
    $path = Get-DriveOriginPath -ProjectDrivePath $ProjectDrivePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return (New-UnreadableMarker) }
}

function Write-DriveOrigin {
    # 四個內容欄位一律「空字串代表沿用既有值」，不代表清空。
    #
    # ProjectUuid／DisplayName：呼叫端可能是還沒有 UUID 的 v1 專案（讀取側相容），
    # 不能因為它沒有就把 Drive 端已經有的值蓋掉（寫入側不搭便車：由本機的空值覆寫
    # Drive 端，等於本機間接替它「遷移」了）。
    #
    # Remote／MainBranch：origin.json 是**別台裝置** bootstrap 時決定要 clone 哪個 repo
    # 的唯一來源（ADR-0003）。呼叫端問不到本機 remote，只代表「這台現在不知道」，
    # 不代表「這個專案沒有 remote」——把它寫成空字串會讓另外兩台裝置接不回來。
    # 真的要改 remote 是刻意的動作，那條路走票 26 的身分核對，不是從這裡靜靜蓋掉。
    param(
        [Parameter(Mandatory)][string]$ProjectDrivePath,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Remote,
        [Parameter(Mandatory)][AllowEmptyString()][string]$MainBranch,
        [AllowEmptyString()][string]$ProjectUuid = '',
        [AllowEmptyString()][string]$DisplayName = ''
    )
    $existing = Read-DriveOrigin -ProjectDrivePath $ProjectDrivePath
    if (Test-Unreadable $existing) {
        # 既有檔案讀不動時不可以寫——「空值沿用既有值」的機制靠 $existing 才成立，
        # 讀不到的話沿用會悄悄變回清空（ADR-0003）。寧可整個寫入中止，讓呼叫端決定
        # 怎麼處理，也不要用猜測覆蓋掉可能仍然有效的內容。
        throw "既有的 origin.json 讀不動（檔案存在但無法解析），為了不讓「空值沿用既有值」的機制悄悄變成清空，寫入已中止：$(Get-DriveOriginPath -ProjectDrivePath $ProjectDrivePath)"
    }
    $uuidToWrite = $ProjectUuid
    if (-not $uuidToWrite) {
        $uuidToWrite = Get-PropertyOrDefault -InputObject $existing -Name 'projectUuid' -Default ''
    }
    $displayNameToWrite = $DisplayName
    if (-not $displayNameToWrite) {
        $displayNameToWrite = Get-PropertyOrDefault -InputObject $existing -Name 'displayName' -Default ''
    }
    $remoteToWrite = $Remote
    if (-not $remoteToWrite) {
        $remoteToWrite = Get-PropertyOrDefault -InputObject $existing -Name 'remote' -Default ''
    }
    $mainBranchToWrite = $MainBranch
    if (-not $mainBranchToWrite) {
        $mainBranchToWrite = Get-PropertyOrDefault -InputObject $existing -Name 'mainBranch' -Default ''
    }

    $json = ConvertTo-Json ([ordered]@{
        projectId   = $ProjectId
        projectUuid = $uuidToWrite
        displayName = $displayNameToWrite
        remote      = $remoteToWrite
        mainBranch  = $mainBranchToWrite
        updatedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        updatedBy   = $env:COMPUTERNAME
    })

    # 原子寫入（ADR-0007 不變量 6）：先寫暫存檔再 Move-Item，跟 Write-ProjectList
    # （registry.ps1）同一個手法。origin.json 讀者（Read-DriveOrigin、心跳、遷移工具
    # 續跑判斷）任何時刻看到的都必須是「完整合法」或「檔案不存在」，不能是寫到一半。
    $finalPath = Get-DriveOriginPath -ProjectDrivePath $ProjectDrivePath
    $temp = "$finalPath.writing"
    # 上一次寫到一半就被砍掉的話，這裡會留著同名暫存檔。清掉它再寫，並把「接手了
    # 半成品」回傳給呼叫端——不變量 5(b) 要求這件事被說出來，不能靜靜蓋過去。
    $resumedStalePartial = Test-Path -LiteralPath $temp
    if ($resumedStalePartial) { Remove-Item -LiteralPath $temp -Force }
    Write-Utf8NoBom -Path $temp -Content $json
    Move-Item -LiteralPath $temp -Destination $finalPath -Force
    return $resumedStalePartial
}

function Find-DriveProjectsByPrefix {
    # 同一個 slug-date 前綴底下已經存在的 Drive 專案（忽略 UUID 後綴）。
    #
    # 用在建立新專案的 Drive 目錄前：slug 退化成 'project' 時，同一天很容易有兩個
    # 不相關的專案共用同一個前綴（ADR-0003）。UUID 後綴本身已經保證兩者不會實際
    # 撞到同一個目錄，這裡要抓的是另一件事——人類會看不出這兩個目錄其實無關，
    # 所以只在前綴底下已經有一個「真的連了 git remote」的既有專案時才停手；
    # remote 是空的（該目錄可能只是還沒設定完成、甚至是失敗的殘留）不構成阻擋。
    param(
        [Parameter(Mandatory)][string]$DriveRoot,
        [Parameter(Mandatory)][string]$Prefix
    )
    $namespace = Join-Path (Get-NormalisedPath $DriveRoot) $script:DriveNamespace
    if (-not (Test-Path -LiteralPath $namespace)) { return @() }
    return @(Get-ChildItem -LiteralPath $namespace -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith($Prefix) } |
        ForEach-Object { $_.Name })
}

function Find-DriveProject {
    # 用資料夾名稱找 Drive 端的專案。回傳 Matches（0..n）與 Available（全部候選）。
    #
    # 比對規則：完全相同優先，其次是唯一的前綴符合——專案 ID 的組成就是
    # 「資料夾名的 slug + 初始化日期」，所以前綴比對是照定義走的，不是硬湊。
    #
    # **配對不唯一時不做選擇。** 呼叫端負責停下來讓使用者自己看。
    param(
        [Parameter(Mandatory)][string]$DriveRoot,
        [Parameter(Mandatory)][string]$FolderName
    )
    $namespace = Join-Path (Get-NormalisedPath $DriveRoot) $script:DriveNamespace
    if (-not (Test-Path -LiteralPath $namespace)) {
        return [pscustomobject]@{ Matches = @(); Available = @() }
    }

    # 只認真的是專案的資料夾。_hybrid/ 底下難免會出現別的東西（解壓縮出來的工具、
    # 隨手放的資料夾），把它們列成候選只會誤導人，更糟的是可能被前綴比對命中。
    # 判準：我們的腳本一定會在專案資料夾裡留下這三者之一。
    $available = @(Get-ChildItem -LiteralPath $namespace -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName 'origin.json')) -or
            (Test-Path -LiteralPath (Join-Path $_.FullName 'lease.json')) -or
            (Test-Path -LiteralPath (Join-Path $_.FullName $script:AssetsDirName))
        } |
        ForEach-Object { $_.Name })
    $slug = ConvertTo-ProjectSlug -Name $FolderName

    $exact = @($available | Where-Object { $_ -eq $FolderName -or $_ -eq $slug })
    if ($exact.Count -gt 0) {
        return [pscustomobject]@{ Matches = $exact; Available = $available }
    }

    $prefixed = @($available | Where-Object { $_ -like "$slug-*" })
    return [pscustomobject]@{ Matches = $prefixed; Available = $available }
}

function Find-GoogleDriveRoot {
    # 自動偵測掛載點。找不到就回 $null——由呼叫端決定要落到設定檔還是要求使用者指定。
    # Google Drive 桌面版掛出來的磁碟機 VolumeName 是 'Google Drive'。
    #
    # 測試接縫：設定環境變數 HYBRID_TEST_NO_GOOGLE_DRIVE=1 時直接回 $null，不去問
    # Win32_LogicalDisk。這台機器上有沒有真的掛 Google Drive 是環境細節，測試不能
    # 依賴它、也沒辦法讓它在別的機器上總是一致（唯讀審查第三輪第 4 條）——這是「自動
    # 偵測失敗」分支唯一測得到的辦法。正式環境不會設這個變數。
    if ($env:HYBRID_TEST_NO_GOOGLE_DRIVE -eq '1') { return $null }
    $volume = Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue |
        Where-Object { $_.VolumeName -and $_.VolumeName -match 'Google Drive' } |
        Select-Object -First 1
    if (-not $volume) { return $null }

    $root = $volume.DeviceID + '\'
    foreach ($name in @('我的雲端硬碟', 'My Drive', '我的云端硬盘')) {
        $candidate = Join-Path $root $name
        if (Test-Path -LiteralPath $candidate -PathType Container) { return $candidate }
    }
    return $root
}

function Get-LocalConfigPath {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    return (Join-Path (Join-Path $ProjectRoot $script:HybridDirName) 'local.json')
}

function Read-LocalConfig {
    # 三態回傳，跟 Read-DriveOrigin／Read-ProjectManifest 同一個道理：檔案不存在
    # → `$null`；存在但解析失敗（同步中的殘檔、部分寫入、損毀）→ `New-UnreadableMarker`；
    # 讀到 → 解析後的物件。呼叫端要分辨「讀不動」必須用 `Test-Unreadable`。
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $path = Get-LocalConfigPath -ProjectRoot $ProjectRoot
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return (New-UnreadableMarker)
    }
}

function Resolve-DriveRoot {
    # 回傳 Path 與 Source（parameter / config / detected），解析不出來時回 $null；
    # local.json 讀不動時回 `New-UnreadableMarker`（用 `Test-Unreadable` 判斷）。
    #
    # 讀不動不可以落到自動偵測：這台裝置留著 local.json，正是因為自動偵測給不出
    # 同樣的答案（`Save-DriveRootOverride` 的設計，見下方）——讀不到就往下掉的話，
    # 等於用猜的去解析出另一個掛載點，`Get-ProjectDrivePath` 可能因此指向一個
    # 不存在的目錄，被日常指令當成「還沒同步」而無條件補建出一個空殼專案
    # （ADR-0003：讀不到不等於沒有）。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$DriveRoot
    )
    if ($DriveRoot) {
        return [pscustomobject]@{ Path = (Get-NormalisedPath $DriveRoot); Source = 'parameter' }
    }

    $config = Read-LocalConfig -ProjectRoot $ProjectRoot
    if (Test-Unreadable $config) { return (New-UnreadableMarker) }
    if ($config -and $config.PSObject.Properties['driveRoot'] -and $config.driveRoot) {
        return [pscustomobject]@{ Path = (Get-NormalisedPath ([string]$config.driveRoot)); Source = 'config' }
    }

    $detected = Find-GoogleDriveRoot
    if ($detected) {
        # 偵測成功**不寫** local.json，這是刻意的，不是漏寫。
        # 把猜出來的值寫成設定，等於把一次成功的猜測升格成永久事實：下次 Drive
        # 掛在別的地方時，那個檔案會讓工具停止重新偵測，而錯誤會看起來像設定正確。
        # 只有使用者用 -DriveRoot 明確指定時才落地——那是人的決定，不是猜測。
        #
        # 外顯症狀是「自動偵測成功，但 .hybrid\local.json 不存在」。看起來像 bug，
        # 三裝置試點時 PC2 就是這樣提報的（它沒有替我們判斷，只擺出事實）。
        # 這段註解存在的目的就是擋下「好心補上」那一手。
        return [pscustomobject]@{ Path = (Get-NormalisedPath $detected); Source = 'detected' }
    }
    return $null
}

function Save-DriveRootOverride {
    # 設定檔只在自動偵測給不出同樣答案時才存在。偵測得到就把殘留的設定檔清掉，
    # 免得裝置換了掛載點之後還被舊值綁住。回傳是否留下了設定檔。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$DriveRoot
    )
    $path = Get-LocalConfigPath -ProjectRoot $ProjectRoot
    $detected = Find-GoogleDriveRoot

    if ($detected -and ((Get-NormalisedPath $detected) -eq (Get-NormalisedPath $DriveRoot))) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        return $false
    }

    Write-Utf8NoBom -Path $path -Content (ConvertTo-Json ([ordered]@{
        driveRoot = (Get-NormalisedPath $DriveRoot)
        device    = $env:COMPUTERNAME
    }))
    return $true
}

function Get-ProjectManifestPath {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    return (Join-Path (Join-Path $ProjectRoot $script:HybridDirName) 'project.json')
}

function Read-ProjectManifest {
    # 三態回傳，跟 Read-DriveOrigin 同一個道理：檔案不存在 → `$null`；存在但解析
    # 失敗 → `New-UnreadableMarker`（用 `Test-Unreadable` 判斷）；讀到 → 解析後的
    # 物件。
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $path = Get-ProjectManifestPath -ProjectRoot $ProjectRoot
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return (New-UnreadableMarker) }
}

function Get-PropertyOrDefault {
    # StrictMode 下直接讀不存在的屬性會炸，而 project.json 的欄位會隨版本增加。
    #
    # **注意：這個函式用 truthiness 判斷「有沒有值」，所以數值 0 會被當成沒有值。**
    # 它的設計對象是字串欄位——那裡「空字串」與「不存在」要求同樣的處理，合在一起是對的。
    # 但如果欄位是數字而 0 是一個有意義的值（例如 schema 版本 0 表示「根本沒有 manifest」），
    # 這個函式會回給你預設值，而你不會收到任何警告。實測踩過一次。
    #
    # 那種欄位要直接看屬性在不在：
    #   if ($obj -and $obj.PSObject.Properties['欄位']) { [int]$obj.欄位 }
    param(
        $InputObject,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Default
    )
    if ($InputObject -and $InputObject.PSObject.Properties[$Name] -and $InputObject.$Name) {
        return [string]$InputObject.$Name
    }
    return $Default
}

function Get-ProjectDrivePath {
    # Drive 端一律以專案 ID 定址，並住在獨立命名空間底下，不跟既有資料夾撞名。
    param(
        [Parameter(Mandatory)][string]$DriveRoot,
        [Parameter(Mandatory)][string]$ProjectId
    )
    return (Join-Path (Join-Path (Get-NormalisedPath $DriveRoot) $script:DriveNamespace) $ProjectId)
}

function Confirm-IdentityConsistency {
    # ADR-0007 不變量 9：本機 manifest 的 projectUuid 與 Drive origin.json 的不同時，
    # 開工／收工／代理收工全部停手（exit 2），兩端都不寫。兩端都沒有 UUID 的舊專案
    # 不算不一致；只有一端有（半遷移）也不算矛盾——這兩種都不阻擋，但要說出來
    # （ADR-0003：「遷移完成之前一律降級成舊行為並且說出來」）。這個函式本身只讀，
    # 不寫任一端，補值只能靠使用者明確執行遷移工具（寫入側不搭便車）。
    #
    # 呼叫端必須在任何宣告類副作用（Write-DriveOrigin／Add-ProjectToList／New-Lease）
    # 之前呼叫這個函式（依 ADR-0004，這是「驗證」階段的檢查：開工落在掛載之後、
    # 宣告之前）。開工在這之前已經動過 local.json、Drive 端目錄與 junction——那些
    # 是環境重建，冪等、可回滾，不是宣告（ADR-0004），所以「任何寫入之前」這個
    # 講法不精確，唯讀審查第三輪第 6 條。
    #
    # 這個函式不自己 exit——它回傳判定結果，由呼叫端印訊息並決定要不要 exit（票 18）。
    # 原因：三支呼叫端要在宣告階段失敗時逆序回滾已完成的副作用，回滾靠呼叫端自己的
    # try/catch；lib 函式裡直接 `exit` 會讓行程立刻終止，呼叫端的回滾邏輯完全沒有
    # 機會跑——`exit` 終止的是整個行程，不是可以被 try/catch/finally 攔下的例外。
    #
    # 回傳 [pscustomobject]@{ Blocked; ExitCode; Messages }：
    #   Blocked   是否應該停手
    #   ExitCode  Blocked 為真時呼叫端要用的 exit code；Blocked 為假時是 $null
    #   Messages  依序印出的訊息，可能是空陣列
    #
    # Drive 端讀不動（Test-Unreadable）不能當成「沒有值」放行——那正是把「讀不到」
    # 吞成「沒有值」的同一個錯誤（唯讀審查第 7 條）：這裡「沒有值」代表「沒有矛盾，
    # 繼續」，吞下去會讓身分矛盾檢查被靜默跳過。
    #
    # 同一個錯誤還有一個更常見的變形（唯讀審查第三輪第 1 條，第四輪第 1 條修正）：
    # Drive 端專案目錄本身剛才不存在（被刪掉，或 Google Drive 還沒同步下來），指標檔
    # 自然也讀不到——但這時 Read-DriveOrigin 回的是 `$null`（檔案不存在），不是
    # Test-Unreadable 認得的損毀標記，於是被當成「Drive 端沒有值」直接放行成「半遷移」。
    #
    # 第四輪第 1 條：原本靠呼叫端傳一個 -DriveRestored 旗標分辨，但那個旗標只在算出
    # 它的那次行程內為真——開工在算完旗標之後、呼叫這個函式之前，會先把 Drive 端目錄
    # 本身補出來（環境重建，冪等），所以下一次執行時目錄已經存在、旗標必然是 false，
    # 這裡就會把「還沒同步」誤判成「半遷移」放行，然後在幽靈目錄裡補寫一份空 UUID 的
    # origin.json——訊息叫使用者「再重跑」，而重跑正是觸發這個破壞性寫入的動作。
    #
    # 改成不依賴呼叫端旗標的黏著判斷：`$localUuid -and -not $driveIdentity`。這件事
    # 成立的理由是 Write-DriveOrigin 永遠會寫出這個檔案——真正的半遷移（目錄一直都在，
    # 只是還沒補上 UUID）必定有 origin.json，只是 projectUuid 欄位是空字串，所以
    # `$driveIdentity` 會是一個物件而不是 `$null`。`$null` 只可能代表「檔案不存在」，
    # 也就是 Drive 端目錄沒同步或被刪除——不管重跑幾次都一樣，不會因為目錄被本次呼叫
    # 補出來而改變答案。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$ProjectDrivePath
    )
    $localUuid = Get-PropertyOrDefault -InputObject $Manifest -Name 'projectUuid' -Default ''

    $driveIdentity = Read-DriveOrigin -ProjectDrivePath $ProjectDrivePath
    if (Test-Unreadable $driveIdentity) {
        return [pscustomobject]@{
            Blocked  = $true
            ExitCode = $script:ExitNeedsYou
            Messages = @(
                "$(Get-DriveOriginPath -ProjectDrivePath $ProjectDrivePath) 存在但無法解析（讀不動），可能還在同步中、暫時讀不到，也可能是內容損毀。",
                "無法確認本機與 Drive 端的專案身分是否一致，不能排除身分矛盾（ADR-0007 不變量 9）——需要你確認之後再重跑。"
            )
        }
    }
    if ($localUuid -and -not $driveIdentity) {
        return [pscustomobject]@{
            Blocked  = $true
            ExitCode = $script:ExitNeedsYou
            Messages = @(
                "$(Get-DriveOriginPath -ProjectDrivePath $ProjectDrivePath) 讀不到——Drive 端這個專案沒有這個檔案。",
                "真正的半遷移一定會有 origin.json（只是 projectUuid 欄位是空字串）；這個檔案不存在，代表 Drive 端這個專案的資料夾還沒同步下來，或被刪掉了。",
                "無法確認本機與 Drive 端的專案身分是否一致，不能排除身分矛盾（ADR-0007 不變量 9）——需要你確認之後再重跑。"
            )
        }
    }
    $driveUuid = Get-PropertyOrDefault -InputObject $driveIdentity -Name 'projectUuid' -Default ''

    if ($localUuid -and $driveUuid -and $localUuid -ne $driveUuid) {
        return [pscustomobject]@{
            Blocked  = $true
            ExitCode = $script:ExitNeedsYou
            Messages = @(
                "停下來了：身分矛盾。",
                "  本機 projectUuid  ：$localUuid（$(Get-ProjectManifestPath -ProjectRoot $ProjectRoot)）",
                "  Drive projectUuid ：$driveUuid（$(Get-DriveOriginPath -ProjectDrivePath $ProjectDrivePath)）",
                "",
                "兩端都有身分但不一致，UUID 是隨機的，任一端都無法重算出另一端——這只能人工裁決。",
                "兩端都沒有被寫入（ADR-0007 不變量 9）。"
            )
        }
    }

    if ($localUuid -and -not $driveUuid) {
        return [pscustomobject]@{
            Blocked  = $false
            ExitCode = $null
            Messages = @(
                "身分：半遷移狀態——本機已有 projectUuid（$localUuid），Drive 端還沒有。",
                "不是身分矛盾，這道指令也不會替你補上（ADR-0003：寫入側不搭便車）。",
                "要完成遷移，請執行 .hybrid\scripts\migrate-project-identity.ps1"
            )
        }
    }

    if ($driveUuid -and -not $localUuid) {
        return [pscustomobject]@{
            Blocked  = $false
            ExitCode = $null
            Messages = @(
                "身分：半遷移狀態——Drive 端已有 projectUuid（$driveUuid），本機還沒有。",
                "不是身分矛盾，這道指令也不會替你補上（ADR-0003：寫入側不搭便車）。",
                "要完成遷移，請執行 .hybrid\scripts\migrate-project-identity.ps1"
            )
        }
    }

    if (-not $localUuid -and -not $driveUuid) {
        return [pscustomobject]@{
            Blocked  = $false
            ExitCode = $null
            Messages = @("身分：舊專案（v1），本機與 Drive 端都還沒有 projectUuid，沿用舊行為（ADR-0003）。")
        }
    }

    return [pscustomobject]@{ Blocked = $false; ExitCode = $null; Messages = @() }
}
