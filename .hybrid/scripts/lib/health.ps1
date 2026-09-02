# 健康檢查：把 state.json、preflight-skip-log.jsonl、專案清單收成一個判定結果
# （票 28／S17）。純唯讀，不寫任何東西——跟 runtime-status.ps1 同一個原則。
#
# 這個檔案只負責「判斷」。要不要印、印成一行還是好幾行，是三個呼叫端
# （runtime-status.ps1、startup.ps1、shutdown.ps1）各自的事——但「印成什麼格式」
# 這件事本身收在 Get-ProjectHealthSummaryLines，避免同一段格式化邏輯被複製兩份
# （這個 repo 已經因為兩份 SKILL.md 走岔被咬過一次）。

Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'paths.ps1')
. (Join-Path $PSScriptRoot 'registry.ps1')
. (Join-Path $PSScriptRoot 'preflight.ps1')

# 三個告警門檻（票 28 票面明列的是第一個，後兩個由這一票決定並說明理由）。

# 連續失敗：票面明列 3 次。
$script:HealthConsecutiveFailureThreshold = 3

# 過久未成功：心跳每 15 分鐘一次，24 小時等於最多 96 次嘗試。用「天」當門檻在這個
# 頻率下太晚——3 天等於快 300 次嘗試都沒被看見；用「幾小時」又容易把單次的暫時性
# 問題（鎖檔、瞬斷）誤判成停擺。24 小時是這兩者之間站得住腳的一個量級：一整天、
# 96 次機會都沒有一次成功，已經不是雜訊。
$script:HealthStaleSuccessHours = 24

# 「心跳仍在跑」的判定窗：只有在最近確實還有嘗試（機器醒著、排程仍在觸發）的前提下，
# 「過久未成功」才是站得住腳的告警——否則沒辦法把「這台機器好幾天沒開」跟「心跳本身
# 停擺」分開，兩者的 lastAttempt 都會很舊，但含義完全不同。這裡刻意不猜
# （ADR-0004「認證失敗不與網路不通分辨」同一種精神：分不清楚就不對使用者宣稱一個
# 可能是錯的診斷）——分不清楚就不觸發，只在訊號夠清楚時才說話。
$script:HealthRecentAttemptHours = 2

function ConvertTo-HealthDateTime {
    # state.json 的時間戳記是 Get-Date 的 'yyyy-MM-ddTHH:mm:sszzz' 格式。空字串
    # （從沒發生過）與解析失敗（理論上不該發生，但檔案終究可能被手動改壞）都回 $null，
    # 讓呼叫端當成「沒有這個時間點可用」處理，不拋例外。
    param([AllowEmptyString()][string]$Value)
    if (-not $Value) { return $null }
    try { return [DateTimeOffset]::Parse($Value).UtcDateTime }
    catch { return $null }
}

function Get-LatestPreflightSkipTrace {
    # 讀 .hybrid/preflight-skip-log.jsonl 的最後一筆（票 21）。這份紀錄進版控、
    # 跨三台裝置都看得到，跟只存在這台機器 %LOCALAPPDATA% 底下的 state.json 不同來源
    # ——用它來回答「這個卡點是什麼時候開始的」，state.json 的 consecutiveFailures
    # 答不出這一句（它只知道次數，不知道起點，且僅限這台機器的次數）。
    #
    # 回傳 $null（沒有紀錄）或 [pscustomobject]@{ FirstAt; Count; Files }。
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $path = Get-PreflightSkipLogPath -ProjectRoot $ProjectRoot
    $records = @(Read-JsonlRecords -Path $path)
    if ($records.Count -eq 0) { return $null }
    $last = $records[$records.Count - 1]
    # 不能走 Get-PropertyOrDefault 取陣列欄位——它的 -Default 是 [string]，
    # 傳 @() 會轉型失敗（跟 preflight.ps1 的 Add-PreflightSkipTrace 同一個註解）。
    #
    # `@()` 要包住整個 if/else 陳述式，不能只包內層分支：只包內層時，只有一個
    # 元素的陣列會在指派給 $files 的路上被攤平成純量（實測踩到——`files` 陣列剛好
    # 只有一個檔名時，$files 變成字串而不是陣列，後面呼叫端取 .Count 在 StrictMode
    # 下直接炸掉）。這個 repo 其餘地方處理同一個問題一律用「包住整個陳述式」
    # 這個寫法（例如 registry.ps1 的 `$entries = @(Read-ProjectList ...)`）。
    $files = @(if ($last.PSObject.Properties['files']) { $last.files } else { @() })
    return [pscustomobject]@{
        FirstAt = Get-PropertyOrDefault -InputObject $last -Name 'firstAt' -Default ''
        Count   = [int](Get-PropertyOrDefault -InputObject $last -Name 'count' -Default '1')
        Files   = $files
    }
}

function Get-ProjectHealth {
    # 把「這個專案在這台機器上的心跳有沒有問題」收成一個判定結果。純讀取。
    #
    # 回傳 [pscustomobject]@{
    #   Path; Exists; LastAttempt; LastSuccess; LastResult; ConsecutiveFailures
    #   Severity ('ok' / 'warning' / 'critical')
    #   Alerts (string[]，Severity 是 'ok' 時必為空陣列)
    # }
    param(
        [Parameter(Mandatory)][string]$Path,
        $State
    )
    $exists = Test-Path -LiteralPath $Path
    $lastAttempt = Get-PropertyOrDefault -InputObject $State -Name 'lastAttempt' -Default ''
    $lastSuccess = Get-PropertyOrDefault -InputObject $State -Name 'lastSuccess' -Default ''
    $lastResult  = Get-PropertyOrDefault -InputObject $State -Name 'lastResult' -Default ''
    $fails = [int](Get-PropertyOrDefault -InputObject $State -Name 'consecutiveFailures' -Default '0')

    # 資料夾不見了（票面「散在四個地方」的第四個訊號）：其餘判定沒有意義，直接回報。
    if (-not $exists) {
        return [pscustomobject]@{
            Path = $Path; Exists = $exists; LastAttempt = $lastAttempt; LastSuccess = $lastSuccess
            LastResult = $lastResult; ConsecutiveFailures = $fails
            Severity = 'critical'
            Alerts = @('資料夾不在了（清單裡仍登記著這個路徑，暫時或永久都可能）')
        }
    }

    $alerts = New-Object System.Collections.ArrayList
    $severity = 'ok'

    # 告警一：連續失敗達門檻。lastResult 可能是既有的固定標記（票 21/25/26 各自的
    # skip／reject 語義），也可能是心跳本身丟例外時的原始 exit code——分開講清楚。
    if ($fails -ge $script:HealthConsecutiveFailureThreshold) {
        $detail = switch ($lastResult) {
            'skipped-by-preflight' {
                $trace = Get-LatestPreflightSkipTrace -ProjectRoot $Path
                if ($trace -and $trace.Files.Count -gt 0) {
                    "preflight 持續擋下（自 $($trace.FirstAt) 起已經 $($trace.Count) 次）：$($trace.Files -join '、')"
                } else {
                    'preflight 持續擋下（心跳沒有 override，需要收工時處理）'
                }
            }
            'skipped-by-version' { '專案與這台機器的 runtime schema 不相容，持續被跳過——需要升級專案或這台的 runtime（upgrade-runtime.ps1）' }
            'skipped-by-policy'  { 'preflight 政策檔持續讀不動或版本不認得，持續被跳過' }
            'rejected-by-lease'  {
                # 這條分支只有這台裝置會寫（票 26 的 wip/<deviceId>-<工作目錄雜湊>
                # 命名規則），持續被拒絕不太可能是真的雙寫衝突——更可能是推送本身
                # 一直失敗（認證或網路），只是 heartbeat.ps1 把所有 push 非零結束碼
                # 都記成同一種標記（ADR-0008 的既有設計，這裡不重新分類，只是解讀）。
                '推送持續被 --force-with-lease 拒絕——這條分支只有這台裝置會寫，持續被拒絕通常是認證或網路出了問題，不是真的雙寫衝突'
            }
            default { "心跳本身持續失敗（結果代碼 $lastResult）" }
        }
        [void]$alerts.Add("連續 $fails 次沒有成功（門檻 $script:HealthConsecutiveFailureThreshold）：$detail")
        $severity = 'critical'
    } elseif ($lastResult -eq 'rejected-by-lease') {
        # 告警三（認證問題）：還沒到連續失敗門檻，但單一裝置專屬分支被拒絕本身就不
        # 正常，不必等到累積 3 次才提醒——早一步看到，處理成本比等到告警三次低。
        [void]$alerts.Add('推送被 --force-with-lease 拒絕——這條分支只有這台裝置會寫，被拒絕通常是認證或網路問題，值得提早檢查')
        $severity = 'warning'
    }

    # 告警二：過久未成功。只在還沒被前面的規則判成 critical 時才評估——已經 critical
    # 的專案不需要再疊訊息，摘要不能變成一大片。
    if ($severity -ne 'critical') {
        $successTime = ConvertTo-HealthDateTime $lastSuccess
        if ($successTime) {
            $attemptTime = ConvertTo-HealthDateTime $lastAttempt
            $now = (Get-Date).ToUniversalTime()
            $hoursSinceAttempt = if ($attemptTime) { ($now - $attemptTime).TotalHours } else { [double]::PositiveInfinity }
            $hoursSinceSuccess = ($now - $successTime).TotalHours
            if (($hoursSinceAttempt -le $script:HealthRecentAttemptHours) -and ($hoursSinceSuccess -ge $script:HealthStaleSuccessHours)) {
                [void]$alerts.Add("心跳明顯還在跑（最近一次嘗試 $lastAttempt），但已經超過 $([int]$hoursSinceSuccess) 小時沒有成功過（門檻 $script:HealthStaleSuccessHours 小時）")
                if ($severity -eq 'ok') { $severity = 'warning' }
            }
        }
    }

    return [pscustomobject]@{
        Path = $Path; Exists = $exists; LastAttempt = $lastAttempt; LastSuccess = $lastSuccess
        LastResult = $lastResult; ConsecutiveFailures = $fails
        Severity = $severity; Alerts = @($alerts.ToArray())
    }
}

function Get-ProjectHealthSummaryLines {
    # 給開工／收工摘要用：健康時只回一行；有問題時第一行是狀態，後面每行一個告警。
    # 呼叫端負責印出來（這個檔案只負責判斷與格式化，不 Write-Host——跟這個 repo
    # 其餘 lib 檔案同一個慣例，Write-Host 留給腳本自己）。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$ListPath
    )
    $state = Read-HeartbeatState -ListPath $ListPath
    $projectState = if ($state.ContainsKey($ProjectRoot)) { $state[$ProjectRoot] } else { $null }
    $report = Get-ProjectHealth -Path $ProjectRoot -State $projectState

    if (-not $report.LastAttempt) {
        return @('尚無心跳紀錄（可能還沒被排程觸發過，或這台機器還沒安裝 install-heartbeat.ps1）')
    }
    if ($report.Severity -eq 'ok') {
        return @("正常（最近一次心跳 $($report.LastAttempt)）")
    }

    $label = if ($report.Severity -eq 'critical') { '告警' } else { '警告' }
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("$label——最近一次心跳 $($report.LastAttempt)：")
    foreach ($msg in $report.Alerts) { [void]$lines.Add("  * $msg") }
    return @($lines.ToArray())
}
