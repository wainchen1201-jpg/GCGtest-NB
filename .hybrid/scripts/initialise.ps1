<#
.SYNOPSIS
    初始化：把一個目錄變成可以開工的 hybrid workspace 專案。

.DESCRIPTION
    產生本機端骨架、在 Drive 端建立以專案 ID 命名的實體資料夾，並記下這台裝置解析
    到的掛載點。不建立 _drive/ 的 junction——那是「開工」的工作。

    偵測到目標已經是初始化過的專案時會停下來，不覆蓋既有設定。

.PARAMETER ProjectRoot
    專案在本機的位置。預設為目前目錄。

.PARAMETER DriveRoot
    Drive 端的根目錄（_hybrid 命名空間會建在它底下）。省略時自動偵測；顯式指定會被
    這台裝置記住，下次不再需要傳。

.PARAMETER Force
    已初始化時仍然重新產生骨架。專案 ID 與初始化日期沿用既有值，不重新產生。

.OUTPUTS
    exit 0 = 完成；1 = 失敗；2 = 已初始化，需要使用者確認。
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$DriveRoot,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $OutputEncoding

. (Join-Path $PSScriptRoot 'lib\paths.ps1')
. (Join-Path $PSScriptRoot 'lib\git.ps1')
. (Join-Path $PSScriptRoot 'lib\version.ps1')

$ExitAlreadyInitialised = 2

function Merge-RequiredLines {
    # 檔案不存在就照範本產生；已存在就只補上缺的行，不覆蓋使用者寫過的內容。
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][string[]]$RequiredLines
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Utf8NoBom -Path $Path -Content $Template
        return 'created'
    }

    $current = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $present = @($current -split "\r?\n" | ForEach-Object { $_.Trim() })
    $missing = @($RequiredLines | Where-Object { $present -notcontains $_ })
    if ($missing.Count -eq 0) { return 'unchanged' }

    $suffix = "`r`n`r`n# --- hybrid workspace 補上的必要設定 ---`r`n" + ($missing -join "`r`n") + "`r`n"
    Write-Utf8NoBom -Path $Path -Content ($current.TrimEnd("`r", "`n") + $suffix)
    return 'merged'
}

function Copy-TemplateBundle {
    # 把腳本與 skill 複製進專案，讓每個專案自我完備：換裝置時不必假設模板 repo
    # 放在哪，也不必先在那台機器上裝任何東西——git clone 下來就能開工。
    #
    # 代價是模板之後的變更不會自動跟上。那是已知的取捨（模板版本升級機制是
    # Out of Scope），不是疏漏。
    # 來源是「scripts 那一層」本身，不是它的上一層。這支腳本就住在那一層裡，
    # 所以 $PSScriptRoot 直接就是答案——模板 repo 的 scripts\ 與開工包的
    # _bootstrap\ 都成立。舊寫法要求上一層底下有 scripts\，開工包沒有那個形狀，
    # 於是回 'missing' 而整個初始化照樣 exit 0。
    param(
        [Parameter(Mandatory)][string]$SourceScripts,
        [Parameter(Mandatory)][string]$SkillRoot,
        [Parameter(Mandatory)][string]$ProjectRoot
    )

    $sourceScripts = $SourceScripts
    $targetScripts = Join-Path (Join-Path $ProjectRoot $script:HybridDirName) 'scripts'

    if (-not (Test-Path -LiteralPath $sourceScripts)) { return 'missing' }
    if ((Get-NormalisedPath $sourceScripts) -eq (Get-NormalisedPath $targetScripts)) { return 'skipped' }

    if (Test-Path -LiteralPath $targetScripts) {
        Remove-Item -LiteralPath $targetScripts -Recurse -Force
    }
    New-Item -ItemType Directory -Path $targetScripts -Force | Out-Null
    # -Path 而不是 -LiteralPath：後者不展開萬用字元，會去找一個叫做 * 的檔案。
    Copy-Item -Path (Join-Path $sourceScripts '*') -Destination $targetScripts -Recurse -Force

    $sourceSkill = Join-Path $SkillRoot '.claude\skills\hybrid-workspace'
    if (Test-Path -LiteralPath $sourceSkill) {
        $targetSkill = Join-Path $ProjectRoot '.claude\skills\hybrid-workspace'
        if (-not (Test-Path -LiteralPath $targetSkill)) {
            New-Item -ItemType Directory -Path $targetSkill -Force | Out-Null
        }
        Copy-Item -Path (Join-Path $sourceSkill '*') -Destination $targetSkill -Recurse -Force
    }
    return 'copied'
}

$gitignoreTemplate = @"
# _drive/ 是掛到 Google Drive 的 junction。git 會直接穿透 junction、把雲端內容
# 當成一般檔案收錄，所以排除它是正確性要求而不是慣例（ADR-0001）。
/_drive/

# 掛載點偵測失敗時的本機覆寫。每台裝置各自持有，不進版控。
/.hybrid/local.json

# 編輯器與工具的殘留物。心跳很忠實，沒排除的東西它都會送上雲端——這幾條不放這裡，
# 每個專案的歷史都會長出一堆自動產生的垃圾。
# 專案類型專屬的忽略規則（例如 KiCad 的 *.kicad_prl）請寫在專案自己的 .gitignore，
# 不要加進模板——模板不假設任何特定的專案內容。
.history/
__pycache__/

# 原子寫入（先寫 .writing 再 Move-Item）中途被砍掉留下的半成品。本機端的
# .hybrid/project.json.writing 沒排除的話，心跳的 git add -A 會把它送上雲端
# （ADR-0007 不變量 5(b)）。
*.writing

# 打包檔留下的東西。它們屬於「怎麼把專案弄到這台機器上」，不屬於專案內容。
/_bootstrap/
/開工.cmd
/開工說明.md
/開工包/
"@

$gitattributesTemplate = @"
* text=auto

# Git LFS 預留但未啟用。需要時：先 git lfs install，再把下面用得到的行取消註解。
#*.vsdx filter=lfs diff=lfs merge=lfs -text
#*.step filter=lfs diff=lfs merge=lfs -text
#*.stp  filter=lfs diff=lfs merge=lfs -text
#*.zip  filter=lfs diff=lfs merge=lfs -text
"@

try {
    if (-not (Test-Path -LiteralPath $ProjectRoot)) {
        New-Item -ItemType Directory -Path $ProjectRoot -Force | Out-Null
    }
    $ProjectRoot = Get-NormalisedPath (Resolve-Path -LiteralPath $ProjectRoot).Path

    # --- 重複初始化保護 ---------------------------------------------------
    # 停在這裡不覆蓋。要不要 -Force 是使用者的判斷，腳本不替他決定。
    $existing = Read-ProjectManifest -ProjectRoot $ProjectRoot
    if (Test-Unreadable $existing) {
        Write-Host "$(Get-ProjectManifestPath -ProjectRoot $ProjectRoot) 存在但無法解析（讀不動），可能還在同步中、暫時讀不到，也可能是內容損毀。"
        Write-Host "確認檔案內容之後再重跑；如果懷疑是同步問題，等 Drive 同步完成再重跑。"
        exit $script:ExitNeedsYou
    }
    if ($existing -and -not $Force) {
        Write-Host "這個目錄已經是初始化過的專案。"
        Write-Host "  專案 ID：$($existing.projectId)（初始化於 $($existing.initialisedOn)）"
        Write-Host ""
        Write-Host "初始化不覆蓋既有設定。確定要重新產生骨架就加上 -Force——"
        Write-Host "專案 ID 與初始化日期會沿用，不會變動。"
        exit $ExitAlreadyInitialised
    }

    $displayName = Split-Path -Leaf $ProjectRoot
    $initialisedOn = if ($existing) { [string]$existing.initialisedOn }
                     else { (Get-Date).ToString('yyyy-MM-dd') }

    # v1 既有專案（Force 重建骨架）沒有 projectUuid 就沿用空字串——日常重建骨架不是
    # 票 16 的遷移工具，不能順手替它補身分（ADR-0003：寫入側不搭便車）。
    $projectUuid = if ($existing) { Get-PropertyOrDefault -InputObject $existing -Name 'projectUuid' -Default '' }
                   else { New-ProjectUuid }

    # --- 解析 Drive 掛載點 ------------------------------------------------
    $resolved = Resolve-DriveRoot -ProjectRoot $ProjectRoot -DriveRoot $DriveRoot
    if (Test-Unreadable $resolved) {
        Write-Host "$(Get-LocalConfigPath -ProjectRoot $ProjectRoot) 存在但無法解析（讀不動），可能還在同步中、暫時讀不到，也可能是內容損毀。"
        Write-Host "這台裝置記住的 Drive 掛載點讀不到，不會落到自動偵測——那可能解析到不同的位置。"
        Write-Host "確認檔案內容之後再重跑，或以 -DriveRoot 明確指定要用哪個掛載點。"
        exit $script:ExitNeedsYou
    }
    if (-not $resolved) {
        Write-Host "找不到 Google Drive 的掛載點，無法決定 Drive 端要建在哪裡。"
        Write-Host "請重跑一次並以 -DriveRoot 指定，例如："
        Write-Host "  -DriveRoot 'H:\我的雲端硬碟'"
        Write-Host "指定過的路徑會被這台裝置記住，下次不必再傳。"
        exit $script:ExitNeedsYou
    }
    if (-not (Test-Path -LiteralPath $resolved.Path -PathType Container)) {
        Write-Host "Drive 端路徑不存在：$($resolved.Path)"
        Write-Host "來源是 $($resolved.Source)。請確認 Google Drive 已掛載，或以 -DriveRoot 指定正確的路徑。"
        exit $script:ExitNeedsYou
    }

    if (-not $existing) {
        # 同一天、slug 又退化成同一個字串（例如兩個純中文名稱）時，Drive 上會出現一排
        # 人類分不出來的 <slug>-<日期>-<uuid8> 目錄。這值得說一聲，但**不阻擋**——
        # 碰撞安全來自 UUID 後綴（ADR-0003），這兩個目錄本來就不會撞在一起，而且
        # 「換一個資料夾名稱」不是一個合理的下一步：專案就叫那個名字。
        # 依 ADR-0005 的判準，說不出下一步的檢查只能警告。
        $slug = ConvertTo-ProjectSlug -Name $displayName
        $prefix = '{0}-{1}-' -f $slug, (Get-Date).ToString('yyyyMMdd')
        $siblings = @(Find-DriveProjectsByPrefix -DriveRoot $resolved.Path -Prefix $prefix)
        if ($siblings.Count -gt 0) {
            Write-Host "提醒：Drive 上今天已經有 $($siblings.Count) 個同前綴（$prefix*）的專案目錄。"
            Write-Host "      它們是不同的專案，不會互相影響；只是用檔案總管看的時候分不出來。"
            Write-Host "      認人請看各目錄 origin.json 的 displayName。"
            Write-Host ""
        }
    }

    $projectId = if ($existing) { [string]$existing.projectId }
                 else { New-ProjectId -ProjectName $displayName -ProjectUuid $projectUuid }

    # --- Drive 端 ---------------------------------------------------------
    $projectDrivePath = Get-ProjectDrivePath -DriveRoot $resolved.Path -ProjectId $projectId

    if ($existing -and $projectUuid) {
        # 已初始化(v2) 重建骨架：依 projectId 找到的目錄，其 projectUuid 必須與本機相同
        # （ADR-0003）。不同就是「身分矛盾」，只能人工裁決，不猜、不改動任何一端。
        $driveIdentity = Read-DriveOrigin -ProjectDrivePath $projectDrivePath
        if (Test-Unreadable $driveIdentity) {
            # 讀不到不能當成「沒有矛盾」放行——那正是把「讀不動」吞成「沒有值」
            # 的同一個錯誤（審查第 7 條）。這裡「沒有值」的意思是「沒有矛盾，繼續」，
            # 所以吞下去會讓身分矛盾檢查被靜默跳過，一路把本機骨架與 bundle 重寫掉。
            Write-Host "停下來了：既有的 $(Get-DriveOriginPath -ProjectDrivePath $projectDrivePath) 讀不到（檔案存在但無法解析）。"
            Write-Host "無法確認 Drive 端是不是跟本機同一個身分，不能排除身分矛盾——需要你確認之後再重跑。"
            exit $script:ExitNeedsYou
        }
        $driveUuid = Get-PropertyOrDefault -InputObject $driveIdentity -Name 'projectUuid' -Default ''
        if ($driveUuid -and $driveUuid -ne $projectUuid) {
            Write-Host "停下來了：身分矛盾。"
            Write-Host "  本機 projectUuid：$projectUuid"
            Write-Host "  Drive 端 projectUuid：$driveUuid（$projectDrivePath）"
            Write-Host ""
            Write-Host "兩端都有身分但不一致，UUID 是隨機的，任一端都無法重算出另一端——這只能人工裁決。"
            exit $script:ExitNeedsYou
        }
    }
    $assetsPath  = Join-Path $projectDrivePath $script:AssetsDirName
    $derivedPath = Join-Path $projectDrivePath $script:DerivedDirName
    foreach ($dir in @($projectDrivePath, $assetsPath, $derivedPath)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    if (-not $existing) {
        # UUID 先寫 Drive 端、後寫 git 端（ADR-0003）：兩個寫入不可能原子，選這個順序
        # 是因為「Drive 有、git 沒有」可偵測且可續跑；反過來的話 git 端的值會被推送
        # 出去，另一台裝置可能先讀到它、替 Drive 端產生另一個不同的 UUID。remote 此刻
        # 還沒有（本機 git 都還沒 init），下面拿到 remote 之後會再補寫一次。
        Write-DriveOrigin -ProjectDrivePath $projectDrivePath -ProjectId $projectId `
            -Remote '' -MainBranch $script:MainBranchName `
            -ProjectUuid $projectUuid -DisplayName $displayName | Out-Null
    }

    # --- 本機端骨架 -------------------------------------------------------
    $gitignoreState = Merge-RequiredLines `
        -Path (Join-Path $ProjectRoot '.gitignore') `
        -Template $gitignoreTemplate `
        -RequiredLines @('/_drive/', '/.hybrid/local.json', '.history/', '__pycache__/', '*.writing', '/_bootstrap/', '/開工.cmd', '/開工說明.md', '/開工包/')

    $gitattributesState = Merge-RequiredLines `
        -Path (Join-Path $ProjectRoot '.gitattributes') `
        -Template $gitattributesTemplate `
        -RequiredLines @('* text=auto')

    $manifestData = [ordered]@{
        projectId      = $projectId
        initialisedOn  = $initialisedOn
        driveNamespace = $script:DriveNamespace
        assetsDir      = $script:AssetsDirName
        derivedDir     = $script:DerivedDirName
    }
    if ($projectUuid) {
        # 只有新專案，或 Force 重建的既有 v2 專案才帶這幾個欄位——v1 專案的 Force
        # 重建骨架不是遷移工具，不能順手把它升級成 v2（ADR-0003：寫入側不搭便車）。
        # schemaVersion／lastWrittenByToolVersion 跟 projectUuid 同一個 if 分支，
        # 理由相同（ADR-0008：schemaVersion 只在讀取側用推導規則補，寫入側不搭便車）。
        $manifestData['projectUuid'] = $projectUuid
        $manifestData['displayName'] = $displayName
        $manifestData['schemaVersion'] = 2
        $toolVersion = ''
        try { $toolVersion = Get-ToolVersion -Root (Get-ToolVersionRoot -ScriptRoot $PSScriptRoot) } catch { }
        $manifestData['lastWrittenByToolVersion'] = $toolVersion
    }
    Write-Utf8NoBom -Path (Get-ProjectManifestPath -ProjectRoot $ProjectRoot) -Content (
        ConvertTo-Json $manifestData
    )

    # 腳本來源就是這支腳本自己所在的那一層——模板 repo 的 scripts\、開工包的
    # _bootstrap\、專案自帶的 .hybrid\scripts\，三種形狀都成立。
    #
    # skill 的來源則是選用的，所以解析失敗要退回去而不是拋出來：跑專案自帶那份時
    # .hybrid\scripts 與 .hybrid 都沒有版本檔，而那條路徑的 bundle 本來就會回
    # 'skipped'（來源等於目的地），根本用不到 skill 來源。讓一個選用的東西擋掉整個
    # 初始化，是把「找不到」誤當成「不能繼續」。Copy-TemplateBundle 自己會用
    # Test-Path 決定要不要複製。
    $skillRoot = try { Get-ToolVersionRoot -ScriptRoot $PSScriptRoot }
                 catch { Split-Path -Parent $PSScriptRoot }
    $bundleState = Copy-TemplateBundle -SourceScripts $PSScriptRoot `
        -SkillRoot $skillRoot -ProjectRoot $ProjectRoot

    $gitState = 'existing'
    if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot '.git'))) {
        try {
            & git -C $ProjectRoot init --quiet
            & git -C $ProjectRoot symbolic-ref HEAD "refs/heads/$script:MainBranchName"
            $gitState = 'created'
        } catch {
            $gitState = 'failed'
        }
    }

    # Drive 端的指標檔：讓別台裝置不靠 git 就知道這個專案的 repo 在哪。
    # 打包檔的 bootstrap 就是讀這個（票 10）。
    $remoteUrl = ''
    if (Test-HasRemote -ProjectRoot $ProjectRoot) {
        $remoteProbe = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('remote', 'get-url', 'origin')
        if ($remoteProbe.ExitCode -eq 0) { $remoteUrl = $remoteProbe.Output }
    }
    Write-DriveOrigin -ProjectDrivePath $projectDrivePath -ProjectId $projectId `
        -Remote $remoteUrl -MainBranch $script:MainBranchName `
        -ProjectUuid $projectUuid -DisplayName $displayName | Out-Null

    # 顯式指定的路徑要被記住——但只有在自動偵測給不出同樣答案時才留下設定檔。
    $overrideSaved = $false
    if ($resolved.Source -eq 'parameter') {
        $overrideSaved = Save-DriveRootOverride -ProjectRoot $ProjectRoot -DriveRoot $resolved.Path
    }

    # --- 回報 -------------------------------------------------------------
    $sourceLabel = switch ($resolved.Source) {
        'parameter' { if ($overrideSaved) { '呼叫參數（已記住，下次不必再傳）' } else { '呼叫參數（與自動偵測一致，未留設定檔）' } }
        'config'    { '本機設定檔' }
        'detected'  { '自動偵測' }
        default     { $resolved.Source }
    }

    Write-Host "初始化完成"
    Write-Host "  專案 ID    ：$projectId"
    Write-Host "  本機端     ：$ProjectRoot"
    Write-Host "  Drive 端   ：$projectDrivePath"
    Write-Host "  掛載點來源 ：$sourceLabel"
    Write-Host "  .gitignore ：$gitignoreState／.gitattributes：$gitattributesState／git repo：$gitState"
    $bundleLabel = switch ($bundleState) {
        'copied'  { '腳本與 skill 已複製進 .hybrid/scripts 與 .claude/skills（專案自帶，進版控）' }
        # 來源與目標路徑相同，什麼都沒複製——這一份 initialise.ps1 自己就是來源。
        # 只會發生在「跑的是專案自帶那份 .hybrid\scripts\initialise.ps1，且
        # -ProjectRoot 指向同一個專案」——在模板 repo 對自己跑，來源是 <repo>\scripts、
        # 目標是 <repo>\.hybrid\scripts，路徑不同，回的是 'copied'。不能報成「就在
        # 模板 repo 裡」：對一個帶著舊 bundle 的專案跑自己那份 -Force，使用者以為
        # bundle 被重刷了，其實一個位元組都沒動（唯讀審查第三輪第 2 條）。要真的
        # 更新，得去模板 repo 對這個專案跑 initialise.ps1 -Force -ProjectRoot <這個專案>。
        'skipped' { '來源與目標路徑相同，沒有複製——bundle 沒有被更新到；如果是想拿到模板最新版，改去模板 repo 對這個專案跑 initialise.ps1 -Force -ProjectRoot' }
        'missing' { '找不到模板的 scripts/，沒有複製' }
        default   { $bundleState }
    }
    Write-Host "  自帶工具   ：$bundleLabel"
    Write-Host ""
    Write-Host "下一步"
    Write-Host "  1. 執行「開工」建立 _drive/ 的 junction。在那之前專案裡還沒有 _drive/。"
    # 只有真的複製進去了才敢這樣講。沒複製成功時照樣印這一句，等於指著一支不存在的
    # 腳本叫使用者去跑——而且會在「換裝置」那一刻才爆，離現場最遠。
    if ($bundleState -in @('copied', 'skipped')) {
        Write-Host "     這個專案自帶腳本，換裝置後直接跑 .hybrid\scripts\startup.ps1 就行。"
    } else {
        Write-Host "     這個專案**沒有**自帶腳本（$bundleLabel），換裝置後必須另外準備一份工具。"
    }
    Write-Host "  2. 離線釘選必須手動做一次——Google Drive 沒有實作 Windows Cloud Files API，"
    Write-Host "     attrib +P 對它無效，程式碼碰不到這個設定："
    Write-Host "       在檔案總管開啟 $assetsPath"
    Write-Host "       右鍵 → 離線存取 → 可離線使用"
    Write-Host "     衍生品（$derivedPath）維持串流，不要釘選。"

    exit 0
}
catch {
    Write-Host "初始化失敗：$($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    exit 1
}
