# 中央 runtime：機器層級、安裝時就固定下來的心跳執行內容
# （docs/adr/0008-scheduler-runs-installed-runtime-not-repo-scripts.md）。
#
# 版面（ADR-0008「安裝、升級、回滾、失敗隔離」段）：
#   %LOCALAPPDATA%\hybrid-workspace\
#     runtime\
#       current.json    { version, previous, switchedAt }
#       <版本>\
#         heartbeat.ps1
#         lib\...
#         preflight-policy.default.json
#         VERSION.json  { toolVersion, schemaMin, schemaMax, installedAt, installedFrom }
#
# 這個檔案只負責「檔案版面與指標檔的讀寫」——安裝、升級、派工器三個呼叫端共用同一份，
# 避免版面定義散落在三個地方而漂移。

Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'paths.ps1')
. (Join-Path $PSScriptRoot 'registry.ps1')
. (Join-Path $PSScriptRoot 'version.ps1')

function Get-RuntimeRoot {
    param([string]$ListPath)
    return (Join-Path (Get-HeartbeatHome -ListPath $ListPath) 'runtime')
}

function Get-RuntimeCurrentPath {
    param([string]$ListPath)
    return (Join-Path (Get-RuntimeRoot -ListPath $ListPath) 'current.json')
}

function Get-RuntimeVersionDir {
    param(
        [string]$ListPath,
        [Parameter(Mandatory)][string]$Version
    )
    return (Join-Path (Get-RuntimeRoot -ListPath $ListPath) $Version)
}

function Read-RuntimeCurrent {
    # 三態回傳，跟 Read-ProjectManifest 同一個道理：不存在 → $null；
    # 存在但解析失敗 → New-UnreadableMarker（用 Test-Unreadable 判斷）；讀到 → 物件。
    param([string]$ListPath)
    $path = Get-RuntimeCurrentPath -ListPath $ListPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if (-not $raw.Trim()) { return (New-UnreadableMarker) }
        return ($raw | ConvertFrom-Json)
    } catch {
        return (New-UnreadableMarker)
    }
}

function Write-RuntimeCurrent {
    # 原子寫入（ADR-0007 不變量 6）：先寫暫存檔再 Move-Item。這是升級「換指標」
    # 那一步唯一被信任的寫入路徑——ADR-0008 的第 4 步。
    param(
        [string]$ListPath,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Previous
    )
    $path = Get-RuntimeCurrentPath -ListPath $ListPath
    $content = ConvertTo-Json ([ordered]@{
        version    = $Version
        previous   = $Previous
        switchedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    })
    $temp = "$path.writing"
    Write-Utf8NoBom -Path $temp -Content $content
    Move-Item -LiteralPath $temp -Destination $path -Force
}

function Resolve-RuntimeSourceDir {
    # 來源可以是模板 repo 的根目錄（底下有 scripts\heartbeat.ps1），也可以是已經是
    # 「scripts 那一層」本身的目錄（開工包的 _bootstrap\，或直接把 scripts\ 傳進來）
    # ——兩種都是 ADR-0008「升級的來源」允許的形狀，這裡不強迫呼叫端知道是哪一種。
    param([Parameter(Mandatory)][string]$SourceRoot)
    $nested = Join-Path $SourceRoot 'scripts'
    if (Test-Path -LiteralPath (Join-Path $nested 'heartbeat.ps1')) { return (Get-NormalisedPath $nested) }
    if (Test-Path -LiteralPath (Join-Path $SourceRoot 'heartbeat.ps1')) { return (Get-NormalisedPath $SourceRoot) }
    throw "找不到 heartbeat.ps1：$SourceRoot 底下試過 scripts\heartbeat.ps1 與 heartbeat.ps1 都沒有"
}

function Test-RuntimeContentMatches {
    # 已安裝的版本目錄，內容跟來源是不是同一份？
    #
    # 存在的理由：升級原本只看「目標版本目錄在不在」就決定跳過，等於相信
    # **版本字串相同 ⇒ 內容相同**。三裝置真機試點把那個假設證偽了兩次——
    # 兩台都回報 1.0.0 而內容差四個 commit；開工包與 repo 的 VERSION.json
    # 甚至是同一顆雜湊，卻描述著三個檔案不同的兩棵樹（票 33）。
    #
    # 後果最嚴重的地方不是「跳過」本身，是**升級在最需要它的時候靜默地什麼都不做**。
    #
    # 比對範圍就是 Install-RuntimeFiles 會複製的那些，**刻意排除 VERSION.json**：
    # 那個檔案由 Install-RuntimeFiles 自己重寫（加上 schemaMin/Max、installedAt、
    # installedFrom），所以裝完之後必然跟來源不同——把它算進去等於每次都重裝，
    # 「跳過」那條路徑就永遠走不到，中斷續跑的最佳化也就沒了。
    #
    # 任何一邊讀不動、或檔案集合對不起來，一律回 $false：這裡的「不確定」要往
    # 重新安裝的方向倒，因為重裝的代價只是多花幾秒，而錯誤地跳過會留下一份
    # 看起來裝好了、實際上是舊的 runtime。
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$RuntimeVersionDir
    )
    if (-not (Test-Path -LiteralPath $RuntimeVersionDir)) { return $false }

    try {
        $sourceDir = Resolve-RuntimeSourceDir -SourceRoot $SourceRoot
    } catch {
        return $false
    }

    # 來源這一側要比對的相對路徑清單（與 Install-RuntimeFiles 一致）。
    $relatives = New-Object System.Collections.ArrayList
    [void]$relatives.Add('heartbeat.ps1')
    $libDir = Join-Path $sourceDir 'lib'
    if (Test-Path -LiteralPath $libDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $libDir -File -Recurse)) {
            [void]$relatives.Add('lib\' + $f.FullName.Substring($libDir.Length).TrimStart('\'))
        }
    }
    $policyName = 'preflight-policy.default.json'
    if (Test-Path -LiteralPath (Join-Path $sourceDir $policyName)) {
        [void]$relatives.Add($policyName)
    }

    foreach ($rel in $relatives) {
        $a = Join-Path $sourceDir $rel
        $b = Join-Path $RuntimeVersionDir $rel
        if (-not (Test-Path -LiteralPath $b)) { return $false }
        try {
            $ha = (Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash
            $hb = (Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash
        } catch {
            return $false
        }
        if ($ha -ne $hb) { return $false }
    }

    # 目的地多出來的檔案也算不同——那可能是上一版留下的東西，而 runtime 目錄
    # 是要拿去執行的，多一支來歷不明的腳本不該被當成「已經裝好了」。
    # VERSION.json 是唯一的例外（它本來就由這裡重寫）。
    $destFiles = @(Get-ChildItem -LiteralPath $RuntimeVersionDir -File -Recurse)
    foreach ($f in $destFiles) {
        $rel = $f.FullName.Substring($RuntimeVersionDir.Length).TrimStart('\')
        if ($rel -eq 'VERSION.json') { continue }
        if ($relatives -notcontains $rel) { return $false }
    }

    return $true
}

function Install-RuntimeFiles {
    # 把一份 runtime 原始檔複製到 $DestinationDir（呼叫端決定是 runtime\<版本>\
    # 還是 runtime\<版本>.staging\），並寫入 VERSION.json。**不寫 current.json**
    # ——那是驗證通過之後呼叫端才做的宣告（ADR-0008：驗證在宣告之前）。
    #
    # 複製整個 lib\ 目錄，不是手動列舉檔名：runtime 執行心跳需要的 lib 會隨程式演進
    # （票 25 之後可能再加 version.ps1 之外的東西），列舉容易漏。多帶幾支目前用不到
    # 的 lib 檔案沒有安全代價——「專案只提供資料」守的是 $ProjectRoot 底下的內容
    # 不能被 dot-source／執行，不是 runtime 自己的 lib 目錄要多精簡。
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestinationDir,
        [Parameter(Mandatory)][string]$ToolVersion
    )
    $sourceDir = Resolve-RuntimeSourceDir -SourceRoot $SourceRoot

    # 開頭無條件刪除同名目的地（比照 git.ps1:175 對暫存 index 的處理）：留下上一次
    # 沒清乾淨的半成品，會讓這次複製的結果混進舊檔案。
    if (Test-Path -LiteralPath $DestinationDir) {
        Remove-Item -LiteralPath $DestinationDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null

    Copy-Item -LiteralPath (Join-Path $sourceDir 'heartbeat.ps1') -Destination $DestinationDir -Force

    $libSourceDir = Join-Path $sourceDir 'lib'
    if (-not (Test-Path -LiteralPath $libSourceDir)) {
        throw "找不到 lib\：$libSourceDir"
    }
    New-Item -ItemType Directory -Path (Join-Path $DestinationDir 'lib') -Force | Out-Null
    Copy-Item -Path (Join-Path $libSourceDir '*') -Destination (Join-Path $DestinationDir 'lib') -Recurse -Force

    $policySrc = Join-Path $sourceDir 'preflight-policy.default.json'
    if (-not (Test-Path -LiteralPath $policySrc)) {
        throw "找不到 preflight-policy.default.json：$policySrc"
    }
    Copy-Item -LiteralPath $policySrc -Destination $DestinationDir -Force

    $versionInfo = [ordered]@{
        toolVersion   = $ToolVersion
        schemaMin     = $script:RuntimeSchemaMin
        schemaMax     = $script:RuntimeSchemaMax
        installedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        installedFrom = $sourceDir
    }
    Write-Utf8NoBom -Path (Join-Path $DestinationDir 'VERSION.json') -Content (ConvertTo-Json $versionInfo)
    return $sourceDir
}

function Read-RuntimeVersionInfo {
    # 三態回傳，同一個道理：不存在 → $null；讀不動 → New-UnreadableMarker；讀到 → 物件。
    param([Parameter(Mandatory)][string]$RuntimeVersionDir)
    $path = Join-Path $RuntimeVersionDir 'VERSION.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return (New-UnreadableMarker)
    }
}

function Test-SelfVerifyRuntime {
    # ADR-0008 升級流程第 2 步：對一個暫存的空 git repo 跑一次剛複製好的 heartbeat.ps1，
    # 斷言 exit 0 且輸出可解析。失敗就代表這份 runtime 不能用——呼叫端要刪掉 staging，
    # 什麼都不改變（可回滾的環境重建，ADR-0004 那一類）。
    #
    # 回傳 [pscustomobject]@{ Ok; ExitCode; Output }。
    param([Parameter(Mandatory)][string]$RuntimeVersionDir)

    $heartbeatScript = Join-Path $RuntimeVersionDir 'heartbeat.ps1'
    if (-not (Test-Path -LiteralPath $heartbeatScript)) {
        return [pscustomobject]@{ Ok = $false; ExitCode = $null; Output = "找不到 $heartbeatScript" }
    }

    $probeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('hybrid-runtime-selfverify-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null
    try {
        & git -C $probeRoot init --quiet
        & git -C $probeRoot symbolic-ref HEAD 'refs/heads/master'

        $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -Wait `
            -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', "`"$heartbeatScript`"", '-ProjectRoot', "`"$probeRoot`""
            ) `
            -RedirectStandardOutput (Join-Path $probeRoot 'selfverify-out.txt') `
            -RedirectStandardError (Join-Path $probeRoot 'selfverify-err.txt')

        $stdout = ''
        $outFile = Join-Path $probeRoot 'selfverify-out.txt'
        if (Test-Path -LiteralPath $outFile) { $stdout = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue }

        return [pscustomobject]@{ Ok = ($proc.ExitCode -eq 0); ExitCode = $proc.ExitCode; Output = $stdout }
    } catch {
        return [pscustomobject]@{ Ok = $false; ExitCode = $null; Output = $_.Exception.Message }
    } finally {
        Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-ActiveHeartbeatScript {
    # 派工器（run-heartbeats.ps1）用來決定「這一輪要跑哪一支 heartbeat.ps1」的
    # 單一入口。回傳 [pscustomobject]@{ Found; ScriptPath; Version; UsedPrevious; Reason }。
    #
    # ADR-0008「current.json 讀不到或指向不存在的目錄」：
    #   不存在（這台還沒裝 runtime）→ Found=$false，呼叫端印可讀原因、
    #     本輪不處理任何專案、exit 0。不退回專案 bundle。
    #   讀不動 → 跟「不存在」一樣不猜——不知道 version 是什麼，也就沒有 previous 可退。
    #   指向的目錄不見了 → 退回 previous 並大聲說（UsedPrevious=$true，Reason 非空）。
    #   兩個都不在 → Found=$false。
    param([string]$ListPath)

    $currentPath = Get-RuntimeCurrentPath -ListPath $ListPath
    $current = Read-RuntimeCurrent -ListPath $ListPath

    if ($null -eq $current) {
        return [pscustomobject]@{
            Found = $false; ScriptPath = $null; Version = $null; UsedPrevious = $false
            Reason = "這台機器還沒安裝 runtime（$currentPath 不存在）——請以系統管理員身分執行一次 install-heartbeat.ps1"
        }
    }
    if (Test-Unreadable $current) {
        return [pscustomobject]@{
            Found = $false; ScriptPath = $null; Version = $null; UsedPrevious = $false
            Reason = "runtime 指標檔讀不動（$currentPath）——可能是同步中的殘檔或內容損毀"
        }
    }

    $primaryVersion = Get-PropertyOrDefault -InputObject $current -Name 'version' -Default ''
    if (-not $primaryVersion) {
        return [pscustomobject]@{
            Found = $false; ScriptPath = $null; Version = $null; UsedPrevious = $false
            Reason = "runtime 指標檔沒有 version 欄位（$currentPath）"
        }
    }

    $primaryScript = Join-Path (Get-RuntimeVersionDir -ListPath $ListPath -Version $primaryVersion) 'heartbeat.ps1'
    if (Test-Path -LiteralPath $primaryScript) {
        return [pscustomobject]@{
            Found = $true; ScriptPath = $primaryScript; Version = $primaryVersion; UsedPrevious = $false; Reason = ''
        }
    }

    $previousVersion = Get-PropertyOrDefault -InputObject $current -Name 'previous' -Default ''
    if ($previousVersion) {
        $previousScript = Join-Path (Get-RuntimeVersionDir -ListPath $ListPath -Version $previousVersion) 'heartbeat.ps1'
        if (Test-Path -LiteralPath $previousScript) {
            return [pscustomobject]@{
                Found = $true; ScriptPath = $previousScript; Version = $previousVersion; UsedPrevious = $true
                Reason = "current 指向的版本 $primaryVersion 找不到（目錄可能被防毒隔離或清理工具移除），已退回 previous（$previousVersion）"
            }
        }
    }

    return [pscustomobject]@{
        Found = $false; ScriptPath = $null; Version = $null; UsedPrevious = $false
        Reason = "current 指向的版本 $primaryVersion 找不到，previous（$(if ($previousVersion) { $previousVersion } else { '無' })）也沒有可用的 runtime"
    }
}

function Invoke-RefreshProjectBundle {
    # 用這台機器目前的 runtime 當來源，刷新 -ProjectRoot 指定的專案自帶的
    # .hybrid\scripts\（heartbeat.ps1、lib\、preflight-policy.default.json）。
    # 不需要模板 repo，不需要提權（ADR-0008「舊專案的過渡」）。
    #
    # upgrade-runtime.ps1 -RefreshBundle（使用者直接下的前景指令）與
    # migrate-project-identity.ps1 的 'unsupported' 分支（票 25 G 段：拿掉票 16 的
    # 權宜，改成工具自己動手）共用這個函式，避免同一段複製邏輯散落兩處而漂移。
    #
    # 回傳 [pscustomobject]@{ Ok; RuntimeVersion; Reason }：Ok=$false 時
    # RuntimeVersion 可能是空字串（連 current.json 都讀不到），Reason 是可讀原因；
    # Ok=$true 時 Reason 是空字串。
    param(
        [string]$ListPath,
        [Parameter(Mandatory)][string]$ProjectRoot
    )
    if (-not (Test-Path -LiteralPath $ProjectRoot)) {
        return [pscustomobject]@{ Ok = $false; RuntimeVersion = ''; Reason = "專案目錄不存在：$ProjectRoot" }
    }
    $current = Read-RuntimeCurrent -ListPath $ListPath
    if (($null -eq $current) -or (Test-Unreadable $current)) {
        return [pscustomobject]@{ Ok = $false; RuntimeVersion = ''; Reason = '這台機器還沒有可用的 runtime，沒有東西可以拿來刷新（先安裝或升級 runtime）。' }
    }
    $runtimeVersion = Get-PropertyOrDefault -InputObject $current -Name 'version' -Default ''
    $runtimeDir = Get-RuntimeVersionDir -ListPath $ListPath -Version $runtimeVersion
    if (-not (Test-Path -LiteralPath (Join-Path $runtimeDir 'heartbeat.ps1'))) {
        return [pscustomobject]@{ Ok = $false; RuntimeVersion = $runtimeVersion; Reason = "runtime 指標指向的版本（$runtimeVersion）目錄不在了：$runtimeDir" }
    }

    $targetScripts = Join-Path (Join-Path $ProjectRoot $script:HybridDirName) 'scripts'
    New-Item -ItemType Directory -Path (Join-Path $targetScripts 'lib') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $runtimeDir 'heartbeat.ps1') -Destination $targetScripts -Force
    Copy-Item -Path (Join-Path (Join-Path $runtimeDir 'lib') '*') -Destination (Join-Path $targetScripts 'lib') -Recurse -Force
    $policySrc = Join-Path $runtimeDir 'preflight-policy.default.json'
    if (Test-Path -LiteralPath $policySrc) {
        Copy-Item -LiteralPath $policySrc -Destination $targetScripts -Force
    }

    return [pscustomobject]@{ Ok = $true; RuntimeVersion = $runtimeVersion; Reason = '' }
}
