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
# 票 43：告警要分辨「找不到身分檔」與「身分檔讀不動」，判準跟 runtime-status 的
# 「相容判定」共用同一個函式。version.ps1 只相依 paths.ps1，沒有循環。
. (Join-Path $PSScriptRoot 'version.ps1')

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

function Format-Age {
    # 把一段時間講成人話。健康訊息要回答「多久沒動了」，因為使用者要據此判斷
    # 這是關機一夜還是排程死了——同樣一句「異常」對這兩件事沒有幫助。
    param([Parameter(Mandatory)][TimeSpan]$Span)
    $minutes = [int]$Span.TotalMinutes
    if ($minutes -lt 60) { return "$minutes 分鐘" }
    $hours = [int]$Span.TotalHours
    if ($hours -lt 48) { return "$hours 小時" }
    return "$([int]$Span.TotalDays) 天"
}

function Get-DispatcherLiveness {
    # 機器層級：派工器**有沒有起得來**。這一層是專案層級的健康檢查看不到的——
    # state.json 與 last-run.log 都是派工器自己寫的，它起不來（例如 dot-source
    # 失敗，那發生在頂層、任何 try/catch 之前），兩個檔就凍結在最後一次成功，
    # 於是每個專案都顯示「上次成功」。真機試點時兩台機器就是這樣連續失敗數小時
    # 而健康一路顯示「正常」（票 35）。
    #
    # **不能只看 log 有多舊。** 這個 repo 已經為了同樣的理由拒絕過那個做法
    # （見 HealthRecentAttemptHours 那段）：機器關機一晚，log 一樣會很舊，
    # 但含義完全不同，而分不清楚時對使用者宣稱一個可能是錯的診斷比不說更糟。
    #
    # 能區分的訊號是**排程器自己的紀錄**：它由排程器寫，不是派工器寫。
    #
    #   排程器說它跑過了，而 log 比那次還舊  → 派工器被啟動但死在寫 log 之前。決定性。
    #   排程器也很久沒跑                      → 機器八成關著。不猜，不報。
    #
    # 呼叫端負責去問作業系統（Get-ScheduledTaskInfo），把結果傳進來——查詢留在邊界，
    # 判斷留在這裡，這樣判斷才測得到。
    param(
        [string]$ListPath,
        [AllowNull()][Nullable[DateTime]]$TaskLastRun = $null,
        [AllowNull()][Nullable[int]]$TaskLastResult = $null
    )
    $logPath = Join-Path (Get-HeartbeatHome -ListPath $ListPath) 'last-run.log'
    $hasLog = Test-Path -LiteralPath $logPath
    $logTime = if ($hasLog) { (Get-Item -LiteralPath $logPath).LastWriteTime } else { $null }

    if (-not $TaskLastRun) {
        # 問不到排程器（沒安裝、模組不可用、或呼叫端沒傳）。這時只能說事實，不下診斷。
        if (-not $hasLog) {
            return [pscustomobject]@{ Severity = 'unknown'; Line = '還沒跑過（剛安裝的話等一輪，約 15 分鐘）' }
        }
        return [pscustomobject]@{
            Severity = 'unknown'
            Line = "最後一次跑完是 $($logTime.ToString('yyyy-MM-dd HH:mm:ss'))（$(Format-Age -Span ((Get-Date) - $logTime)) 前）；查不到排程器紀錄，無法判斷它現在有沒有在跑"
        }
    }

    $ranAt = $TaskLastRun.ToString('yyyy-MM-dd HH:mm:ss')

    # 排程器跑過，但派工器沒留下那一輪的紀錄——它被啟動了卻死在寫 log 之前。
    # 容忍 5 分鐘，避免「正在跑、還沒寫完」被誤判。
    if ((-not $hasLog) -or ($TaskLastRun - $logTime).TotalMinutes -gt 5) {
        $logPart = if ($hasLog) { "但紀錄停在 $($logTime.ToString('yyyy-MM-dd HH:mm:ss'))" } else { '但完全沒有紀錄' }
        return [pscustomobject]@{
            Severity = 'critical'
            Line = "排程器在 $ranAt 啟動過它，$logPart——派工器被啟動了卻死在寫紀錄之前"
        }
    }

    if ($null -ne $TaskLastResult -and $TaskLastResult -ne 0) {
        return [pscustomobject]@{
            Severity = 'critical'
            Line = "最近一次 $ranAt 失敗（排程器回報 $TaskLastResult）"
        }
    }

    return [pscustomobject]@{
        Severity = 'ok'
        Line = "正常（最近一次 $ranAt，$(Format-Age -Span ((Get-Date) - $logTime)) 前）"
    }
}

function Get-ProjectListAgreement {
    # 派工器上一輪看到的清單，跟我現在看到的，是不是同一份？
    #
    # 派工器每一輪都把它自己看到的大小與專案數寫進 last-run.log；這支腳本從**它自己的
    # 行程**也看得到同樣兩個數字。兩者本來就該相等——**不等就是異常**。
    #
    # 這個判斷刻意不去問「為什麼不等」。三裝置試點時的成因是 MSIX 重導向
    # （封裝環境裡的行程看到套件私有的副本，排程工作看到真實檔案，票 38），
    # 但同樣的不一致也可能來自權限、環境變數空掉（run-heartbeats.ps1 的註解說
    # 「實測被這個騙過兩次」，那兩次是這個變體）、或路徑解析錯。
    #
    # 不需要知道成因，也不需要判斷自己在哪——**只比對兩個都已經存在的觀察值**。
    # 這也是它不會誤報的原因：兩個行程讀同一個路徑卻拿到不同大小，本身就是事實。
    #
    # 讀不到 log、或 log 是舊版格式（沒有那兩個數字）→ 回 $null，什麼都不說。
    # 把「格式不認得」當成「不一致」會在每台還沒升級的機器上誤報。
    param([string]$ListPath)

    $logPath = Join-Path (Get-HeartbeatHome -ListPath $ListPath) 'last-run.log'
    if (-not (Test-Path -LiteralPath $logPath)) { return $null }

    try {
        $log = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
    } catch {
        return $null
    }

    $sizeMatch = [regex]::Match($log, '存在，(\d+) 位元組')
    $countMatch = [regex]::Match($log, '清單裡有 (\d+) 個專案')
    if (-not $sizeMatch.Success) { return $null }

    $seenBytes = [int]$sizeMatch.Groups[1].Value
    $seenCount = if ($countMatch.Success) { [int]$countMatch.Groups[1].Value } else { -1 }

    # **不要叫它 $listFilePath。** PowerShell 的變數名不分大小寫，那個名字會覆寫參數
    # $ListPath（家目錄），於是下一行的 Read-ProjectList 拿到的是檔案路徑、再往下
    # 多接一層，找不到檔案而安靜回空的——真機上這裡印出「0 個專案」，而同一次
    # 輸出底下的「登記的專案（共 2 個）」說 2。同一支腳本對同一件事給了兩個答案，
    # 而那段訊息的全部說服力正來自「兩個觀察值不相等」。
    $listFilePath = Get-ProjectListPath -ListPath $ListPath
    if (-not (Test-Path -LiteralPath $listFilePath)) {
        return [pscustomobject]@{
            Agrees = $false
            Lines = @(
                "清單不一致：派工器上一輪看到 $seenBytes 位元組的清單，但我現在看不到那個檔案。",
                '  你讀到的清單，跟心跳讀到的不是同一份。'
            )
        }
    }
    $nowBytes = (Get-Item -LiteralPath $listFilePath -Force).Length
    $nowCount = @(Read-ProjectList -ListPath $ListPath).Count

    if ($seenBytes -eq $nowBytes) { return [pscustomobject]@{ Agrees = $true; Lines = @() } }

    $countPart = if ($seenCount -ge 0) { "，$seenCount 個專案" } else { '' }
    return [pscustomobject]@{
        Agrees = $false
        Lines = @(
            "清單不一致：**你讀到的清單，跟心跳讀到的不是同一份。**",
            "  派工器上一輪看到：$seenBytes 位元組$countPart",
            "  這個行程看到的  ：$nowBytes 位元組，$nowCount 個專案",
            "  路徑            ：$listFilePath",
            '  同一個路徑在兩個行程眼中是不同的檔案。常見成因：這個行程跑在封裝或沙箱',
            '  環境裡（讀寫被重導向到私有副本）、權限不同、或環境變數解析到別的位置。',
            '  後果：從這裡做的登記，排程的心跳看不到。'
        )
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
            'skipped-by-version' {
                # schema 0 不是「版本太舊」，是**根本沒有 .hybrid\project.json**——
                # 通常是清單裡的殘留條目（那個目錄被刪掉或換成別的東西了）。
                #
                # 兩者的下一步完全不同，而給錯的那個是可執行的：照著跑 upgrade-runtime
                # 會 exit 0、然後什麼都沒改變。ADR-0005 說「說得出下一步才有資格擋」——
                # 說得出一個**做不到的**下一步，比說不出更糟。
                # 不能用 Get-PropertyOrDefault：它靠 truthiness 判斷有沒有值，
                # 而 schema **0 本身就是我們要分辨的那個值**，在 PowerShell 裡 0 是 falsy，
                # 於是會拿到預設值。這裡直接看屬性在不在。
                $schemaSeen = -1
                if ($State -and $State.PSObject.Properties['skippedByVersionSchema']) {
                    $schemaSeen = [int]$State.skippedByVersionSchema
                }
                if ($schemaSeen -eq 0) {
                    # 【票 43】schema 0 是「無法判定」的哨兵值，而它涵蓋**兩種**狀態：
                    #   找不到 .hybrid\project.json → 清單裡的殘留條目，移除是對的
                    #   檔案在、但讀不動             → 一個正常的專案，身分檔壞了，
                    #                                  要修不是要移除
                    #
                    # heartbeat.ps1 在印標記行之前就分辨過了（它算出 $reason 印給人看），
                    # 但標記行只帶得出 schema=0，於是 state.json 沒有這個區分。
                    # 真機上的後果：一個身分檔被編輯壞掉的專案，告警叫人跑
                    # leave-device.ps1——那會拆掉 junction、把一個正常的專案移出保護，
                    # 而真正的問題（一行 JSON）原封不動。
                    #
                    # 不改標記行的協定（票 43 方案 A 的風險）：run-heartbeats.ps1 住在
                    # 機器層級、由 install-heartbeat 更新，heartbeat.ps1 住在 runtime\ 、
                    # 由 upgrade-runtime 更新——兩者版本可以不一致（票 37 的形狀）。
                    # 新 heartbeat 在標記行後面加東西，舊 run-heartbeats 的正則（有 $ 錨點）
                    # 就比對不到，那一輪會不再被算成「沒有拿到保護」——悄悄回到票 35 之前。
                    #
                    # 改成在**給建議的當下自己讀**，判準跟 runtime-status 的「相容判定」
                    # 完全相同。沒有跨行程協定，就沒有版本相容問題；而且兩者從此讀同一個
                    # 來源、在同一個時刻，不可能再各說各話（真機上就是它們互相矛盾）。
                    #
                    # 依據「現在」而不是「當時」是刻意的：使用者要的是「我現在該做什麼」。
                    # 「資料夾整個不在」不必在這裡處理——上面第 235 行就提早回報了
                    # （而且說得更好）。第一版我在這裡也加了一支，寫完才發現它到不了：
                    # **死程式碼比沒有更糟，它會讓下一個人以為這裡處理過那個情況。**
                    $schemaNow = Get-ProjectSchemaVersion -ProjectRoot $Path
                    if (Test-Unreadable $schemaNow) {
                        '這個專案的 .hybrid\project.json 讀不動（內容壞了，或同步到一半），持續被跳過——它是一個正常的專案，把那個檔案修好就會恢復。**不要**用 leave-device.ps1，那會把它移出保護，而檔案還是壞的'
                    } elseif ($null -eq $schemaNow) {
                        '這個路徑不是 hybrid workspace 專案（讀不到 .hybrid\project.json），持續被跳過——通常是清單裡的殘留條目，用 leave-device.ps1 把它移除'
                    } else {
                        "現在已經讀得到 .hybrid\project.json（schema $schemaNow）——問題看起來已經處理掉了，下一輪心跳應該就會恢復；如果沒有恢復再回來看這裡"
                    }
                } else {
                    '專案與這台機器的 runtime schema 不相容，持續被跳過——需要升級專案或這台的 runtime（upgrade-runtime.ps1）'
                }
            }
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
        # 這句話原本無條件列兩個可能原因：「還沒被排程觸發過」或「還沒安裝」。
        # 三裝置試點時 PC2 那台**兩個都是假的**——排程當天觸發過兩次且結果 0，
        # install-heartbeat 也在稍早提權裝好了。真正的原因是第三種：專案登記在一份
        # 派工器看不到的清單裡（票 38 的 MSIX 重導向）。
        #
        # 「列了可能原因、但正確答案不在裡面」比含糊更糟：讀的人會從那兩個選項裡挑
        # 一個去查，兩條都走到死路，然後大概率得出「大概是還沒跑到」然後就算了。
        #
        # 分辨方式不需要知道 MSIX，只要比對兩個現成的觀察值：**派工器最近跑完過一輪**
        # （last-run.log 有新的時間戳）**卻沒有這個專案的紀錄**。這兩件事並存本身就
        # 說明派工器沒有在處理這個專案，不管成因是沒登記、登記到別份清單、或別的。
        $dispatcherRanRecently = $false
        $logPath = Join-Path (Get-HeartbeatHome -ListPath $ListPath) 'last-run.log'
        if (Test-Path -LiteralPath $logPath) {
            $age = (Get-Date) - (Get-Item -LiteralPath $logPath).LastWriteTime
            $dispatcherRanRecently = $age.TotalMinutes -le $script:HealthRecentAttemptHours * 60
        }
        if ($dispatcherRanRecently) {
            return @(
                '派工器最近跑完過一輪，但那一輪沒有這個專案——它沒有在處理這個專案。',
                '  最可能是這個專案不在派工器讀得到的那份清單裡（開工的登記可能沒有落到同一份）。',
                '  用 runtime-status.ps1 看「登記的專案」那一段，確認它在不在裡面。'
            )
        }
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
