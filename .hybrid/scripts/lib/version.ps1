# 版本：工具版本（toolVersion）與專案 schema 版本（schemaVersion）的單一入口。
#
# 兩者不合併（ADR-0008「兩個版本號，不合併」）：
#   toolVersion    semver，單一來源是 package.json 的 version（或安裝到機器上之後
#                  runtime 目錄自己的 VERSION.json）。只用於診斷與升級提示，
#                  **不是**相容判定的輸入。
#   schemaVersion  整數，專案在磁碟上的契約版本，才是相容判定唯一的輸入。

Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'paths.ps1')

# runtime 今天認得的 schema 區間（ADR-0008「相容矩陣」）。這是新版 runtime 安裝／
# 升級時寫進 VERSION.json 的值——單一來源在這裡，不要在別處另外寫死同樣的數字。
$script:RuntimeSchemaMin = 1
$script:RuntimeSchemaMax = 2

function Get-ToolVersionRoot {
    # 回答「版本檔在哪一層」。這件事沒有單一答案，因為同一批腳本會從兩種形狀被執行：
    #
    #   模板 repo   <repo>\scripts\xxx.ps1        → 版本在上一層的 package.json
    #   開工包      <包>\_bootstrap\xxx.ps1       → 版本在同一層的 VERSION.json
    #
    # 舊寫法一律取 `Split-Path -Parent $PSScriptRoot`，只有前者成立。後者的上一層是
    # 專案根目錄，兩個檔案都沒有——於是 install-heartbeat 直接爆，而 initialise 因為
    # 把這裡包在 try/catch 裡，靜靜地把版本吞成空字串再繼續往下走。
    #
    # 兩種都試，跟 Resolve-RuntimeSourceDir 對 heartbeat.ps1 做的事是同一個道理：
    # 呼叫端不必知道自己被裝在哪一種形狀裡。
    param([Parameter(Mandatory)][string]$ScriptRoot)

    foreach ($candidate in @($ScriptRoot, (Split-Path -Parent $ScriptRoot))) {
        if (-not $candidate) { continue }
        if ((Test-Path -LiteralPath (Join-Path $candidate 'VERSION.json')) -or
            (Test-Path -LiteralPath (Join-Path $candidate 'package.json'))) {
            return $candidate
        }
    }
    throw "找不到工具版本：$ScriptRoot 與其上一層都沒有 VERSION.json 或 package.json"
}

function Get-ToolVersion {
    # 讀 $Root 底下的 VERSION.json（runtime 目錄、開工包都是這個形狀）；
    # 沒有的話退回 $Root 底下的 package.json（模板 repo 根目錄是這個形狀）。
    # 兩者都讀不到就丟例外——版本是診斷用的事實，讀不到不該被吞成空字串。
    param([Parameter(Mandatory)][string]$Root)

    $versionJsonPath = Join-Path $Root 'VERSION.json'
    if (Test-Path -LiteralPath $versionJsonPath) {
        try {
            $v = Get-Content -LiteralPath $versionJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            throw "版本檔讀不動（$versionJsonPath）：$($_.Exception.Message)"
        }
        if ($v -and $v.PSObject.Properties['toolVersion'] -and $v.toolVersion) {
            return [string]$v.toolVersion
        }
        throw "版本檔沒有 toolVersion 欄位：$versionJsonPath"
    }

    $packageJsonPath = Join-Path $Root 'package.json'
    if (Test-Path -LiteralPath $packageJsonPath) {
        try {
            $p = Get-Content -LiteralPath $packageJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            throw "package.json 讀不動（$packageJsonPath）：$($_.Exception.Message)"
        }
        if ($p -and $p.PSObject.Properties['version'] -and $p.version) {
            return [string]$p.version
        }
        throw "package.json 沒有 version 欄位：$packageJsonPath"
    }

    throw "找不到工具版本：$Root 底下沒有 VERSION.json 也沒有 package.json"
}

function Get-ProjectSchemaVersion {
    # 推導規則（ADR-0008，只讀不寫——推導的結果不寫回 manifest，寫回是初始化與
    # 遷移工具的職責，這裡不搭便車）：
    #   manifest.schemaVersion 欄位存在就用它
    #   否則 manifest.projectUuid 存在 → 2
    #   否則 → 1
    #
    # 三態回傳，跟 Read-ProjectManifest 同一個道理：manifest 讀不動 →
    # New-UnreadableMarker（用 Test-Unreadable 判斷）；manifest 不存在 → $null；
    # 讀到 → 推導出的整數。
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $manifest = Read-ProjectManifest -ProjectRoot $ProjectRoot
    if (Test-Unreadable $manifest) { return (New-UnreadableMarker) }
    if (-not $manifest) { return $null }

    if ($manifest.PSObject.Properties['schemaVersion'] -and $manifest.schemaVersion) {
        return [int]$manifest.schemaVersion
    }
    $uuid = Get-PropertyOrDefault -InputObject $manifest -Name 'projectUuid' -Default ''
    if ($uuid) { return 2 }
    return 1
}

function Get-InstalledSchemaRange {
    # heartbeat.ps1 用這個決定「這個 runtime 認得哪個 schema 區間」（ADR-0008 相容矩陣）。
    #
    # 正常情況（機器層級安裝的 runtime\<版本>\heartbeat.ps1）：$RuntimeDir（也就是
    # heartbeat.ps1 自己的 $PSScriptRoot）底下有 VERSION.json，讀它——那是這次安裝
    # 當下就固定下來的宣告。
    #
    # 沒有 VERSION.json，或讀不動（開發／測試直接跑 scripts\heartbeat.ps1，不透過安裝
    # 流程；或檔案損毀）：退回這個檔案自己編譯進來的 $script:RuntimeSchemaMin / Max
    # ——同一份原始碼在真正安裝的情況下本來就會算出同一個值（Install-RuntimeFiles 寫
    # VERSION.json 時就是從這兩個變數抄過去的），這裡只是少讀一次檔案，不是另一套判準。
    # 讀不動也不該讓心跳整台失敗（ADR-0008：這一路只能跳過，exit 0，不是 exit 1）。
    param([Parameter(Mandatory)][string]$RuntimeDir)
    $versionPath = Join-Path $RuntimeDir 'VERSION.json'
    if (Test-Path -LiteralPath $versionPath) {
        try {
            $v = Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($v -and $v.PSObject.Properties['schemaMin'] -and $v.PSObject.Properties['schemaMax']) {
                return [pscustomobject]@{ Min = [int]$v.schemaMin; Max = [int]$v.schemaMax }
            }
        } catch {
            # 落到下面的編譯內建值。
        }
    }
    return [pscustomobject]@{ Min = $script:RuntimeSchemaMin; Max = $script:RuntimeSchemaMax }
}

function Test-SchemaCompatible {
    # 回傳 'ok' / 'too-old' / 'too-new'。不相容一律拒跑、不降級猜
    # （ADR-0008「不相容一律拒跑，不降級猜」）——這個函式只判斷，不決定呼叫端
    # 拿到不相容之後要做什麼（前景 exit 2、背景跳過 exit 0 是兩回事，各自的呼叫端決定）。
    param(
        [Parameter(Mandatory)][int]$Schema,
        [Parameter(Mandatory)][int]$Min,
        [Parameter(Mandatory)][int]$Max
    )
    if ($Schema -lt $Min) { return 'too-old' }
    if ($Schema -gt $Max) { return 'too-new' }
    return 'ok'
}
