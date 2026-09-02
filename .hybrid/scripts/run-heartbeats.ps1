<#
.SYNOPSIS
    派工器：讀清單，對每個還在的專案跑一次**機器層級安裝的** runtime 心跳。

.DESCRIPTION
    這支腳本住在機器層級（`%LOCALAPPDATA%\hybrid-workspace\`），由單一的工作排程器
    項目呼叫。它**不含任何心跳邏輯**——只負責找出要處理誰，然後呼叫
    `runtime\<current 版本>\heartbeat.ps1`（docs/adr/0008-scheduler-runs-installed-runtime-not-repo-scripts.md）。

    **它不會呼叫專案自己的 `.hybrid\scripts\heartbeat.ps1`。**那份是進版控的資料，
    任何能改寫 repo 的人都能改到它——排程執行的內容只能來自安裝時就固定下來的
    那一份 runtime，這是 ADR-0008 的核心。

    公平性與逾時是這裡的重點。序列處理最危險的失效不是整個排程停掉，而是
    **「排程看起來正常，某些專案卻永遠輪不到」**：一個專案的 push 卡住，派工器就停在
    那裡，後面的專案完全沒機會；期間每一次觸發都被 MultipleInstances=IgnoreNew 直接
    丟棄（StartWhenAvailable 補不回這種，它只處理「當時無法啟動」）；等到排程器的
    ExecutionTimeLimit 強殺，可能正好殺在 git 操作中間，留下 lock。下一輪又從清單
    開頭開始，同一個專案再卡住，後面的就永遠餓死。

    所以：**依「最久沒被嘗試」排序**（不是固定順序）、**每個專案各自有逾時**（不靠
    排程器強殺）、**整輪有 soft budget**、**禁止任何互動式認證提示**（否則 push 會
    無限等一個沒人看得到的對話框）。

.PARAMETER ListPath
    清單所在的目錄。預設 `%LOCALAPPDATA%\hybrid-workspace`。測試接縫——同一個參數
    也覆寫 runtime 的位置（ADR-0008：測試接縫是既有的那一個，`-ListPath` 一個參數
    同時覆寫清單與 runtime 路徑）。

.PARAMETER ProjectTimeoutSeconds
    單一專案的上限。超過就終止它的整棵行程樹，繼續下一個。

.PARAMETER BudgetSeconds
    整輪的上限。超過就收尾，剩下的留給下一輪——它們的 lastAttempt 較舊，會排在前面。

.OUTPUTS
    永遠 exit 0。個別專案的成敗記在 last-run.log 與 state.json，不讓其中一個拖垮
    排程項目的狀態。
#>
[CmdletBinding()]
param(
    [string]$ListPath,
    [int]$ProjectTimeoutSeconds = 240,
    [int]$BudgetSeconds = 720
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $OutputEncoding

. (Join-Path $PSScriptRoot 'lib\paths.ps1')
. (Join-Path $PSScriptRoot 'lib\registry.ps1')
. (Join-Path $PSScriptRoot 'lib\runtime.ps1')

# 背景執行時沒有人看得到對話框。任何互動式提示都等同無限掛住，所以一律關掉——
# 認證失敗要當場失敗，不要卡在那裡把後面的專案一起餓死。
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'Never'
$env:GIT_ASKPASS = 'echo'

$lines = @()
function Note {
    param([string]$Text)
    $script:lines += ("{0}  {1}" -f (Get-Date).ToString('HH:mm:ss'), $Text)
    Write-Host $Text
}

function Invoke-ProjectHeartbeat {
    # 開子行程並自己控制逾時。一個專案炸掉或卡住，都不能連累其他專案。
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][string]$Home2
    )
    $outFile = Join-Path $Home2 ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp')
    $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outFile `
        -ArgumentList @(
            # -ExecutionPolicy Bypass 這裡指的是機器層級安裝的固定檔案
            # （runtime\<版本>\heartbeat.ps1），跟專案 repo 的內容無關——那正是
            # ADR-0008 要的效果：繞過原則的對象已經不是「任何人能改寫的資料」。
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$ScriptPath`"", '-ProjectRoot', "`"$ProjectPath`"", '-ListPath', "`"$Home2`""
        )

    # 先碰一下 Handle 把控制代碼快取起來，否則 Start-Process -PassThru 回來的物件
    # 在行程結束後讀不到 ExitCode（會是空的，於是每次都被當成失敗）。實測踩到。
    $null = $proc.Handle

    $finished = $proc.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
        # 終止整棵行程樹——git 是子行程，只殺 powershell 會留下孤兒。
        & taskkill.exe /T /F /PID $proc.Id | Out-Null
        try { $proc.WaitForExit(5000) | Out-Null } catch { }
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Code = 'timeout'; Summary = "超過 $TimeoutSeconds 秒，已終止" }
    }

    $summary = ''
    if (Test-Path -LiteralPath $outFile) {
        $content = @(Get-Content -LiteralPath $outFile -Encoding UTF8 -ErrorAction SilentlyContinue |
            Where-Object { $_ -and $_.Trim() })
        if ($content.Count -gt 0) { $summary = $content[-1] }
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ Code = "$($proc.ExitCode)"; Summary = $summary }
}

$homeDir = Get-HeartbeatHome -ListPath $ListPath
if (-not (Test-Path -LiteralPath $homeDir)) {
    New-Item -ItemType Directory -Path $homeDir -Force | Out-Null
}
$state = Read-HeartbeatState -ListPath $ListPath
$started = Get-Date

try {
    # 一定要記下讀的是哪一個檔。「0 個專案」有兩種完全不同的成因——真的沒登記，
    # 或路徑解析錯了——而它們在紀錄上長得一模一樣。實測被這個騙過兩次。
    $listFile = Get-ProjectListPath -ListPath $ListPath
    Note "清單：$listFile"

    # 「0 個專案」有好幾種成因，而它們印出來長得一模一樣。這裡把證據一起記下，
    # 免得又要靠猜——實測被騙過兩次：一次以為是寫入競態，一次以為是環境變數。
    $exists = Test-Path -LiteralPath $listFile
    # $exists 直接內插會印出 PowerShell 的型別字面值 True／False，混在中文診斷句裡
    # 看起來像程式壞掉而不是在報告狀態。這一行是「0 個專案」那種狀況的唯一證據，
    # 讀的人不該還要先判斷它是不是壞了。
    if ($exists) {
        $size = (Get-Item -LiteralPath $listFile -Force).Length
        $listState = "存在，$size 位元組"
    } else {
        $listState = '不存在'
    }
    Note "  $listState；執行身分=$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

    $entries = @(Read-ProjectList -ListPath $ListPath)
    Note "清單裡有 $($entries.Count) 個專案"

    # --- 決定這一輪要跑哪一支 runtime 的 heartbeat.ps1（ADR-0008）------------
    # 找不到可用的 runtime（這台還沒裝，或 current／previous 指向的目錄都不見了）
    # 就本輪不處理任何專案，exit 0——**不退回專案自己的 bundle**，那正是這份
    # 設計要關掉的信任邊界。
    $activeHeartbeat = Resolve-ActiveHeartbeatScript -ListPath $ListPath
    if (-not $activeHeartbeat.Found) {
        Note "runtime：$($activeHeartbeat.Reason)"
        Note "本輪不處理任何專案。"
    } else {
        if ($activeHeartbeat.UsedPrevious) {
            Note "runtime：版本 $($activeHeartbeat.Version)——$($activeHeartbeat.Reason)"
        } else {
            Note "runtime：版本 $($activeHeartbeat.Version)（$($activeHeartbeat.ScriptPath)）"
        }

        # 依「最久沒被嘗試」排序，不要每次都從清單開頭開始。固定順序的話，第一個專案
        # 一卡住，後面的就永遠輪不到——這是序列派工最容易被忽略的失效模式。
        $ordered = @($entries | Sort-Object -Property @{ Expression = {
            $p = Get-PropertyOrDefault -InputObject $_ -Name 'path' -Default ''
            if ($p -and $state.ContainsKey($p)) { [string]$state[$p].lastAttempt } else { '' }
        } })

        foreach ($entry in $ordered) {
            $path = Get-PropertyOrDefault -InputObject $entry -Name 'path' -Default ''
            if (-not $path) { continue }

            $elapsed = ((Get-Date) - $started).TotalSeconds
            if ($elapsed -ge $BudgetSeconds) {
                Note "這一輪的時間用完了（$([int]$elapsed) 秒），其餘留給下一輪"
                break
            }

            if (-not (Test-Path -LiteralPath $path)) {
                # 不自動從清單移除。Google Drive 的虛擬磁碟在登入後可能還沒掛好，
                # 路徑不存在往往是暫時的——自動移除會把暫時故障變成永久失去保護。
                Note "跳過（資料夾不在，暫時或永久都可能）：$path"
                continue
            }

            # 門檻比的是「整輪還剩多少預算」，不是「單一專案的逾時」——拿後者去比，
            # 只要把 ProjectTimeoutSeconds 設小就會一個專案都跑不到。
            $budgetLeft = $BudgetSeconds - $elapsed
            if ($budgetLeft -lt 5) {
                Note "這一輪的預算用完了，$path 留給下一輪"
                break
            }
            $remaining = [int][math]::Max(1, [math]::Min($ProjectTimeoutSeconds, $budgetLeft))

            $result = Invoke-ProjectHeartbeat -ScriptPath $activeHeartbeat.ScriptPath -ProjectPath $path `
                -TimeoutSeconds $remaining -Home2 $homeDir
            Note ("[{0}] {1} — {2}" -f $result.Code, (Split-Path -Leaf $path), $result.Summary)

            # 心跳被 preflight／版本不相容／政策讀不動擋下時 exit code 一律是 0
            # （ADR-0005、ADR-0008：不能是 1，那會跟真正的失敗混進同一個訊號）。
            # 但這一次終究是「沒有拿到保護」，所以在這裡的狀態記錄上要算成沒有成功
            # ——ok 不能只看 exit code，還要看最後一行是不是這幾種固定格式的標記
            # （heartbeat.ps1 跳過時印的最後一行）。
            $preflightMatch = [regex]::Match($result.Summary, '^SKIPPED-BY-PREFLIGHT files=(.*)$')
            $versionMatch   = [regex]::Match($result.Summary, '^SKIPPED-BY-VERSION schema=(\d+) supported=(\d+)-(\d+)$')
            $policyMatch    = [regex]::Match($result.Summary, '^SKIPPED-BY-POLICY reason=(.*)$')
            # 票 26：--force-with-lease 被拒絕跟 preflight／版本不相容同一類——exit code
            # 是 0（不污染 LastTaskResult），但這一次終究沒有拿到保護，要算成非成功。
            $leaseRejectedMatch = [regex]::Match($result.Summary, '^REJECTED-BY-LEASE branch=(.*)$')
            $skippedByPreflight = $preflightMatch.Success
            $skippedByVersion   = $versionMatch.Success
            $skippedByPolicy    = $policyMatch.Success
            $rejectedByLease    = $leaseRejectedMatch.Success
            $skipped = $skippedByPreflight -or $skippedByVersion -or $skippedByPolicy -or $rejectedByLease

            $now = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
            $prev = if ($state.ContainsKey($path)) { $state[$path] } else { $null }
            $fails = [int](Get-PropertyOrDefault -InputObject $prev -Name 'consecutiveFailures' -Default '0')
            $ok = ($result.Code -eq '0') -and (-not $skipped)
            $lastResult = if ($skippedByPreflight) { 'skipped-by-preflight' }
                          elseif ($skippedByVersion) { 'skipped-by-version' }
                          elseif ($skippedByPolicy) { 'skipped-by-policy' }
                          elseif ($rejectedByLease) { 'rejected-by-lease' }
                          else { $result.Code }
            $entryState = [ordered]@{
                lastAttempt         = $now
                lastSuccess         = if ($ok) { $now } else { Get-PropertyOrDefault -InputObject $prev -Name 'lastSuccess' -Default '' }
                lastResult          = $lastResult
                consecutiveFailures = if ($ok) { 0 } else { $fails + 1 }
            }
            if ($skippedByPreflight) {
                $entryState.skippedByPreflightFiles = @($preflightMatch.Groups[1].Value -split '\|' | Where-Object { $_ })
            }
            if ($skippedByVersion) {
                $entryState.skippedByVersionSchema    = [int]$versionMatch.Groups[1].Value
                $entryState.skippedByVersionSupported = "$($versionMatch.Groups[2].Value)-$($versionMatch.Groups[3].Value)"
            }
            if ($skippedByPolicy) {
                $entryState.skippedByPolicyReason = $policyMatch.Groups[1].Value
            }
            if ($rejectedByLease) {
                $entryState.rejectedByLeaseBranch = $leaseRejectedMatch.Groups[1].Value
            }
            $state[$path] = [pscustomobject]$entryState
        }
    }
}
catch {
    Note "派工器本身出錯：$($_.Exception.Message)"
}
finally {
    # $homeDir 不是 $home。$home 是 PowerShell 的自動變數（使用者家目錄），
    # 打錯的話紀錄檔會靜靜寫到 C:\Users\<你>\last-run.log 去——實測踩到。
    $header = "=== " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + " ==="
    try {
        Write-Utf8NoBom -Path (Join-Path $homeDir 'last-run.log') -Content ((@($header) + $lines) -join "`r`n")
        Write-Utf8NoBom -Path (Get-HeartbeatStatePath -ListPath $ListPath) -Content (ConvertTo-Json $state -Depth 4)
    } catch {
        Write-Host "寫不了紀錄：$($_.Exception.Message)"
    }
}

exit 0
