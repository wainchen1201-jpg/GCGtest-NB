# preflight：心跳與收工共用的提交前防洩漏檢查。
#
# 依據 docs/adr/0005-preflight-blocks-only-what-it-can-name.md（已核准）與
# docs/preflight-policy.md（決策表）。這個檔案只負責「判斷」，不負責「呼叫端拿到
# 阻擋之後要做什麼」——那件事三個呼叫端各自不同（見 ADR-0005 開頭），是 heartbeat.ps1
# 與 shutdown.ps1 自己的事。
#
# 讀取候選檔案清單必須是唯讀的（ADR-0007 不變量 8）：不能用 `git add` 或 `write-tree`，
# 那會改動使用者的 index、產生 loose object。用 `git status --porcelain -z
# --untracked-files=all` 加 `git diff --cached --name-only`。

Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'paths.ps1')
. (Join-Path $PSScriptRoot 'git.ps1')

# 內容比對只套用在這個大小以下的文字檔——心跳每 15 分鐘跑一次，必須快。超過這個大小
# 的檔案仍然套用檔名與大小規則，只是不做內容特徵／熵值掃描。這不是政策檔的欄位：
# 它是掃描機制本身的效能界線，不是使用者該調的規則（跟二進位判準、_drive 排除同一類）。
$script:PreflightContentScanCapBytes = 10MB

# 政策檔（尤其是專案自己提供的 contentSignatures）的正則現在直接餵給 [regex]::IsMatch，
# 沒有這個逾時的話，一個惡意或失手的正則可以讓心跳掛住到排程器強殺為止
# （ADR-0008「資料也有權力，所以資料也有下限」）。
$script:PreflightRegexMatchTimeout = [TimeSpan]::FromSeconds(2)

function Get-PreflightPolicyPath {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    return (Join-Path (Join-Path $ProjectRoot $script:HybridDirName) 'preflight-policy.json')
}

function Get-DefaultPreflightPolicyPath {
    # 相對於這個檔案自己的位置解析，同時對「模板 repo 裡的 scripts/lib」與「被
    # Copy-TemplateBundle 複製進專案的 .hybrid/scripts/lib」成立——兩邊的相對關係
    # 是一樣的（lib/ 底下、scripts/ 上一層）。
    return (Join-Path $PSScriptRoot '..\preflight-policy.default.json')
}

function Read-PreflightPolicy {
    # 專案層 .hybrid/preflight-policy.json 存在就讀那份；不存在就退回模板帶來的
    # scripts/preflight-policy.default.json。讀不到或 schemaVersion 不認得一律丟例外
    # ——不要猜著相容（票 20 決策表：schemaVersion 的說明）。
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $projectPath = Get-PreflightPolicyPath -ProjectRoot $ProjectRoot
    $source = if (Test-Path -LiteralPath $projectPath) { $projectPath } else { Get-DefaultPreflightPolicyPath }
    if (-not (Test-Path -LiteralPath $source)) {
        throw "找不到 preflight 政策檔（專案層與模板預設值都不存在）：$source"
    }

    $raw = Get-Content -LiteralPath $source -Raw -Encoding UTF8
    try {
        $policy = $raw | ConvertFrom-Json
    } catch {
        throw "preflight 政策檔讀不動（$source）：$($_.Exception.Message)"
    }
    if (-not $policy -or -not $policy.PSObject.Properties['schemaVersion']) {
        throw "preflight 政策檔沒有 schemaVersion，格式不對：$source"
    }
    if ([int]$policy.schemaVersion -ne 1) {
        throw "preflight 政策檔的 schemaVersion 是 $($policy.schemaVersion)，這個版本的程式只認得 1。不要猜著相容——先確認新版格式的意義，再更新這裡的讀取邏輯。"
    }
    return (Merge-PreflightPolicyWithBaseline -Policy $policy)
}

function Get-BaselinePreflightPolicy {
    # 下限規則的來源：跟著 runtime 走的 preflight-policy.default.json（安裝／升級時
    # 由 Install-RuntimeFiles 複製進 runtime\<版本>\，不是專案能碰的東西）。不管
    # 專案有沒有自己的 preflight-policy.json，這份內容都會被聯集進去。
    $path = Get-DefaultPreflightPolicyPath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "找不到 runtime 內建的 preflight 政策下限（$path）——這份檔案跟著 runtime 走，缺少代表安裝損毀。"
    }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    try {
        return ($raw | ConvertFrom-Json)
    } catch {
        throw "runtime 內建的 preflight 政策下限讀不動（$path）：$($_.Exception.Message)"
    }
}

function Merge-PreflightPolicyWithBaseline {
    # ADR-0008「政策只能收緊」：sensitiveFilePatterns／contentSignatures 一律跟下限
    # 規則做**聯集**，不是取代——專案永遠不能把下限規則拿掉，只能在它之上追加。
    # 這是「政策讀不動就丟例外」之外的第二道防線：即使政策檔完全合法，也不能把防洩漏
    # 檢查清空。其餘欄位（sizeThresholds／aggregateThresholds／entropyCheck／allowlist）
    # 不在這一票收緊的範圍內，原樣沿用專案（或預設值）自己的內容。
    param([Parameter(Mandatory)]$Policy)

    $baseline = Get-BaselinePreflightPolicy

    $patterns = New-Object System.Collections.Generic.List[string]
    $seenPatterns = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($p in (@($baseline.sensitiveFilePatterns) + @($Policy.sensitiveFilePatterns))) {
        $key = [string]$p
        if ($seenPatterns.Add($key)) { [void]$patterns.Add($key) }
    }

    $signatures = New-Object System.Collections.Generic.List[object]
    $seenNames = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($s in (@($baseline.contentSignatures) + @($Policy.contentSignatures))) {
        $name = [string]$s.name
        if ($seenNames.Add($name)) { [void]$signatures.Add($s) }
    }

    $Policy.sensitiveFilePatterns = $patterns.ToArray()
    $Policy.contentSignatures = $signatures.ToArray()

    # 【票 30 對抗審查】原本這裡只收緊樣式與簽章兩種，其餘欄位「原樣沿用專案的內容」。
    # 但 sizeThresholds.hardLimitBytes 是一條**阻擋**規則的門檻——專案把它設成
    # 999999999999 就等於自行解除單檔大小上限，而那正是整個架構存在的理由
    # （大檔進 Drive，不進 git）。實測確認繞得過去。
    #
    # 諷刺的是 schema 文件明寫「單檔硬門檻規則刻意不開放進 allowlist」。
    # **門鎖了，旁邊的牆是空的。**
    #
    # 數值一律取 min（只能更嚴），entropyCheck 一旦下限開啟就不能關。
    # 專案要放寬只有一條路：改下限規則本身，而那份檔案跟著 runtime 走，專案碰不到。
    foreach ($field in @('sizeThresholds', 'aggregateThresholds')) {
        if (-not $baseline.PSObject.Properties[$field]) { continue }
        if (-not $Policy.PSObject.Properties[$field] -or -not $Policy.$field) {
            $Policy | Add-Member -NotePropertyName $field -NotePropertyValue $baseline.$field -Force
            continue
        }
        foreach ($prop in $baseline.$field.PSObject.Properties) {
            if (-not $Policy.$field.PSObject.Properties[$prop.Name]) {
                $Policy.$field | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
                continue
            }
            $projectValue = [double]$Policy.$field.($prop.Name)
            $baselineValue = [double]$prop.Value
            if ($projectValue -gt $baselineValue) {
                $Policy.$field.($prop.Name) = $prop.Value
            }
        }
    }

    if ($baseline.PSObject.Properties['entropyCheck'] -and $baseline.entropyCheck.enabled) {
        if (-not $Policy.PSObject.Properties['entropyCheck'] -or -not $Policy.entropyCheck) {
            $Policy | Add-Member -NotePropertyName 'entropyCheck' -NotePropertyValue $baseline.entropyCheck -Force
        } elseif (-not $Policy.entropyCheck.enabled) {
            $Policy.entropyCheck.enabled = $true
        }
    }

    return $Policy
}

function ConvertTo-PreflightGlobRegex {
    # `*` 代表任意字元（含零個），其餘照字面。回傳已加上 ^...$ 錨點的正規表示式字串。
    param([Parameter(Mandatory)][string]$Glob)
    $escaped = [regex]::Escape($Glob) -replace '\\\*', '.*'
    return "^$escaped`$"
}

function Test-PreflightGlobMatch {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Glob
    )
    $pattern = ConvertTo-PreflightGlobRegex -Glob $Glob
    return [regex]::IsMatch(
        $Value, $pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase,
        $script:PreflightRegexMatchTimeout)
}

function Test-PreflightAllowlistPathGlobValid {
    # ADR-0008「allowlist 不得涵蓋下限規則」的具體機制：pathGlob 必須指到具體路徑，
    # 不能是純萬用字元（`*`、`**`、`**/*` 這類）。這條限制原本只寫在
    # docs/preflight-policy.schema.json 的 `pattern: "[^*/]"`，沒有任何程式碼真的
    # 檢查它——一筆 `pathGlob: "*"` 的 allowlist 項目今天就能讓整條 sensitiveFilePattern
    # 或 contentSignature 規則形同虛設，這正是「政策放寬掉下限」的洞。跟 schema 用
    # 同一個判準：字串裡至少要有一個不是 `*` 也不是 `/` 的字元。
    #
    # 【票 30 對抗審查】原本的判準（長度 >= 3 且至少一個非 `*` 非 `/` 的字元）擋得住
    # `*`、`**`、`**/*`，但 **擋不住 `*.*` 或 `*en*`**——兩者都滿足那兩個條件，
    # 而 Test-PreflightGlobMatch 把 `*` 展成 `.*`，於是它們幾乎匹配每一個路徑。
    # 實測：一筆 `pathGlob: "*.*"` 就讓 `.env` 通過，內容 SECRET=abc 被提交進 git。
    #
    # 判準改成跟這條規則的**用途**對齊：allowlist 是「逐檔」的例外（阻擋訊息自己就是
    # 這樣寫的），所以**最後一段必須是具體檔名，不能含萬用字元**。
    #   放行：`.env.example`、`docs/samples/example.pem`、`**/example.pem`
    #   擋掉：`*`、`**/*`、`*.*`、`*en*`
    # 目錄那幾段仍然可以用萬用字元——那不會讓例外擴散到「任意檔案」，只是讓同一個
    # 檔名在不同位置都適用。
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PathGlob)
    if ($PathGlob.Length -lt 3) { return $false }
    if (-not [regex]::IsMatch($PathGlob, '[^*/]')) { return $false }

    $segments = $PathGlob -split '/'
    $leaf = $segments[$segments.Count - 1]
    if ([string]::IsNullOrEmpty($leaf)) { return $false }
    return (-not $leaf.Contains('*'))
}

function Get-PreflightCandidateFiles {
    # 唯讀取得「即將新增、修改、刪除」的路徑清單。回傳陣列，每筆
    # { Path（相對路徑，正斜線）; FullPath; Deleted }。
    #
    # 絕不能用 git add 或 write-tree（ADR-0007 不變量 8）。
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $status = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('status', '--porcelain', '-z', '--untracked-files=all')
    $cached = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('diff', '--cached', '--name-only')

    $paths = New-Object System.Collections.Generic.List[string]
    $deletedSet = New-Object 'System.Collections.Generic.HashSet[string]'

    if ($status.Output) {
        $tokens = $status.Output -split "`0"
        $i = 0
        while ($i -lt $tokens.Count) {
            $entry = $tokens[$i]
            if ([string]::IsNullOrEmpty($entry)) { $i++; continue }
            if ($entry.Length -lt 4) { $i++; continue }
            $xy = $entry.Substring(0, 2)
            $path = $entry.Substring(3)
            [void]$paths.Add($path)
            if ($xy.Contains('D')) { [void]$deletedSet.Add($path) }
            # rename／copy：下一個 token 是舊路徑，不是新的候選檔案，跳過它。
            if ($xy[0] -eq 'R' -or $xy[0] -eq 'C') { $i++ }
            $i++
        }
    }
    if ($cached.Output) {
        foreach ($line in ($cached.Output -split "`n")) {
            $trimmed = $line.Trim()
            if ($trimmed -and -not $paths.Contains($trimmed)) { [void]$paths.Add($trimmed) }
        }
    }

    $result = @()
    foreach ($p in @($paths | Select-Object -Unique)) {
        $full = Join-Path $ProjectRoot $p
        $isDeleted = $deletedSet.Contains($p) -or -not (Test-Path -LiteralPath $full -PathType Leaf)
        $result += [pscustomobject]@{ Path = $p; FullPath = $full; Deleted = $isDeleted }
    }
    return $result
}

function Assert-PreflightNeverScansDrive {
    # 顯式斷言：_drive/ 不該出現在候選清單裡。它已經被 .gitignore 排除、天然不在清單裡
    # ——這條斷言防的是規則漂移（ADR-0005：那底下每次讀取都會觸發 Drive 串流下載）。
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Paths)
    foreach ($p in $Paths) {
        $normalised = $p -replace '\\', '/'
        if ($normalised -eq $script:DriveLinkName -or $normalised.StartsWith("$($script:DriveLinkName)/")) {
            throw "preflight 的候選清單裡出現了 $($script:DriveLinkName)/ 底下的路徑（$p）——這不該發生，代表排除規則漂移了（ADR-0005）。"
        }
    }
}

function Test-PreflightBinaryFile {
    # 只看前 8 KB 有沒有 NUL byte——夠判斷是不是二進位，不必整檔讀進來。
    param([Parameter(Mandatory)][string]$FullPath)
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { return $false }
    $stream = [System.IO.File]::OpenRead($FullPath)
    try {
        $buffer = New-Object byte[] 8192
        $read = $stream.Read($buffer, 0, $buffer.Length)
        for ($i = 0; $i -lt $read; $i++) {
            if ($buffer[$i] -eq 0) { return $true }
        }
        return $false
    } finally {
        $stream.Dispose()
    }
}

function Get-PreflightTextContent {
    # 太大就回 $null，呼叫端據此跳過內容比對（只留檔名與大小規則）。
    param([Parameter(Mandatory)][string]$FullPath)
    $info = Get-Item -LiteralPath $FullPath
    if ($info.Length -gt $script:PreflightContentScanCapBytes) { return $null }
    return [System.IO.File]::ReadAllText($FullPath, [System.Text.Encoding]::UTF8)
}

function Get-PreflightShannonEntropyBitsPerChar {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if (-not $Text) { return 0 }
    $counts = @{}
    foreach ($ch in $Text.ToCharArray()) {
        if ($counts.ContainsKey($ch)) { $counts[$ch] = $counts[$ch] + 1 } else { $counts[$ch] = 1 }
    }
    $len = $Text.Length
    $entropy = 0.0
    foreach ($c in $counts.Values) {
        $p = $c / $len
        $entropy = $entropy - ($p * [math]::Log($p, 2))
    }
    return $entropy
}

function Test-PreflightAllowlisted {
    # 逐檔、逐規則比對 allowlist（只認 sensitiveFilePattern／contentSignature 兩種）。
    # expiresAt 過期的例外當成不存在——規則恢復阻擋。
    param(
        [Parameter(Mandatory)]$Policy,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$RelativePath
    )
    $today = (Get-Date).Date
    $normalisedPath = $RelativePath -replace '\\', '/'
    foreach ($entry in @($Policy.allowlist)) {
        if (-not $entry) { continue }
        if ([string]$entry.rule -ne $Rule) { continue }
        if (-not (Test-PreflightAllowlistPathGlobValid -PathGlob ([string]$entry.pathGlob))) { continue }
        if (-not (Test-PreflightGlobMatch -Value $normalisedPath -Glob ([string]$entry.pathGlob))) { continue }
        if ($entry.PSObject.Properties['expiresAt'] -and $entry.expiresAt) {
            $expires = [datetime]::Parse([string]$entry.expiresAt)
            if ($today -gt $expires) { continue }
        }
        return $true
    }
    return $false
}

function Invoke-PreflightScan {
    # 主要進入點。回傳 { Blocked; BlockingFindings; Warnings; Candidates }。
    # BlockingFindings 每筆 { Rule; File; Message }——Rule 只會是
    # sensitiveFilePattern／contentSignature／hardSizeLimit 三種之一
    # （_drive/ 那條不在這裡，寫死在 git.ps1 的 Assert-DriveLinkIgnored）。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$Policy
    )

    $candidates = @(Get-PreflightCandidateFiles -ProjectRoot $ProjectRoot)
    Assert-PreflightNeverScansDrive -Paths @($candidates | ForEach-Object { $_.Path })

    $blocking = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]
    $totalBytes = [long]0
    $totalCount = 0

    foreach ($c in $candidates) {
        if ($c.Deleted) { continue }

        $basename = Split-Path -Path $c.Path -Leaf
        $size = [long]0
        if (Test-Path -LiteralPath $c.FullPath -PathType Leaf) {
            $size = (Get-Item -LiteralPath $c.FullPath).Length
        }
        $totalBytes = $totalBytes + $size
        $totalCount = $totalCount + 1

        # --- 敏感檔名／副檔名 ---------------------------------------------
        foreach ($pattern in @($Policy.sensitiveFilePatterns)) {
            if (Test-PreflightGlobMatch -Value $basename -Glob $pattern) {
                if (-not (Test-PreflightAllowlisted -Policy $Policy -Rule 'sensitiveFilePattern' -RelativePath $c.Path)) {
                    $blocking.Add([pscustomobject]@{
                        Rule    = 'sensitiveFilePattern'
                        File    = $c.Path
                        Message = "檔名命中已知的憑證樣式（$pattern）。加進 .gitignore，或移進 _drive/；如果確定是不含機密的範例檔，逐檔加進 allowlist 並附理由。"
                    })
                }
                break
            }
        }

        # --- 大小門檻 -------------------------------------------------------
        if ($size -gt [long]$Policy.sizeThresholds.hardLimitBytes) {
            $hardMib = [math]::Round($Policy.sizeThresholds.hardLimitBytes / 1MB, 1)
            $sizeMib = [math]::Round($size / 1MB, 1)
            $blocking.Add([pscustomobject]@{
                Rule    = 'hardSizeLimit'
                File    = $c.Path
                Message = "$sizeMib MiB，超過硬門檻 $hardMib MiB（GitHub push 會直接拒絕）。改用 Git LFS 追蹤，或移進 _drive/（若屬於 CONTEXT.md 定義的外部素材或衍生品）。"
            })
        } elseif ($size -gt [long]$Policy.sizeThresholds.softLimitBytes) {
            $sizeMib = [math]::Round($size / 1MB, 1)
            $warnings.Add("$($c.Path)：$sizeMib MiB，超過軟門檻（GitHub 開始警告的大小）。可以考慮 LFS 或 _drive/，不強制。")
        }

        # --- 內容特徵／熵值（只對非二進位檔） -------------------------------
        if (-not (Test-PreflightBinaryFile -FullPath $c.FullPath)) {
            $text = Get-PreflightTextContent -FullPath $c.FullPath
            if ($null -ne $text) {
                foreach ($sig in @($Policy.contentSignatures)) {
                    $sigMatched = $false
                    try {
                        $sigMatched = [regex]::IsMatch(
                            $text, [string]$sig.pattern,
                            [System.Text.RegularExpressions.RegexOptions]::None,
                            $script:PreflightRegexMatchTimeout)
                    } catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
                        # 逾時當成「這一條沒有比對出結果」，不讓它把整次心跳／收工炸掉
                        # （ADR-0008：正則的下限是逾時，不是正確性——一個效能有問題的
                        # 正則不該讓背景排程整台失敗）。
                        $warnings.Add("$($c.Path)：內容特徵「$($sig.name)」的正則比對逾時（超過 $($script:PreflightRegexMatchTimeout.TotalSeconds) 秒），已跳過這一條。")
                        continue
                    }
                    if ($sigMatched) {
                        if (-not (Test-PreflightAllowlisted -Policy $Policy -Rule 'contentSignature' -RelativePath $c.Path)) {
                            $blocking.Add([pscustomobject]@{
                                Rule    = 'contentSignature'
                                File    = $c.Path
                                Message = "內容命中「$($sig.description)」（$($sig.name)）。視為已外洩：先去對應平台撤銷，再從內容移除——如果先前已經 commit 過，歷史裡還在，要額外處理。"
                            })
                        }
                    }
                }

                if ($Policy.entropyCheck.enabled) {
                    $minLen = [int]$Policy.entropyCheck.minLength
                    $threshold = [double]$Policy.entropyCheck.minEntropyBitsPerChar
                    $tokenPattern = "[A-Za-z0-9+/=_\-]{$minLen,}"
                    foreach ($m in [regex]::Matches($text, $tokenPattern)) {
                        $entropy = Get-PreflightShannonEntropyBitsPerChar -Text $m.Value
                        if ($entropy -ge $threshold) {
                            $warnings.Add("$($c.Path)：有長度 $($m.Value.Length) 的高熵值字串，可能是雜湊或編碼內容，人工檢視（entropyCheck）。")
                            break
                        }
                    }
                }
            }
        }
    }

    if ($totalBytes -gt [long]$Policy.aggregateThresholds.totalAddedBytes -or
        $totalCount -gt [int]$Policy.aggregateThresholds.totalAddedFileCount) {
        $totalMb = [math]::Round($totalBytes / 1MB, 1)
        $warnings.Add("本次新增／修改共 $totalCount 個檔案、$totalMb MB，超過總量門檻。檢查是不是把一批外部素材放錯了地方，考慮移進 _drive/。")
    }

    return [pscustomobject]@{
        Blocked          = ($blocking.Count -gt 0)
        BlockingFindings = $blocking.ToArray()
        Warnings         = $warnings.ToArray()
        Candidates       = $candidates
    }
}

function Add-JsonlRecord {
    # 原子附加一行 JSON 到 .jsonl 檔（ADR-0007 不變量 6 的同一個手法：先寫暫存檔再
    # Move-Item，讀者任何時刻看到的都是「寫完的完整內容」或「檔案還是舊的」，不會是
    # 寫到一半）。
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Record
    )
    $line = (ConvertTo-Json $Record -Depth 6 -Compress)
    $existing = ''
    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    }
    $newContent = if ($existing) { $existing.TrimEnd("`r", "`n") + "`r`n" + $line + "`r`n" } else { $line + "`r`n" }
    $temp = "$Path.writing"
    Write-Utf8NoBom -Path $temp -Content $newContent
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Read-JsonlRecords {
    # 讀回整個 .jsonl。空白行略過；讀不動就當成空的——痕跡是給人看的紀錄，
    # 它自己壞掉不該讓心跳連帶失敗（心跳的失敗語義見 ADR-0005）。
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if (-not $raw) { return @() }
        return @($raw -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    catch { return @() }
}

function Write-JsonlRecords {
    # 整個重寫（原子）。只有「更新最後一筆」會用到——追加走 Add-JsonlRecord。
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records
    )
    $lines = @($Records | ForEach-Object { ConvertTo-Json $_ -Depth 6 -Compress })
    $temp = "$Path.writing"
    Write-Utf8NoBom -Path $temp -Content (($lines -join "`r`n") + "`r`n")
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Get-PreflightSkipLogPath {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    return (Join-Path (Join-Path $ProjectRoot $script:HybridDirName) 'preflight-skip-log.jsonl')
}

function Add-PreflightSkipTrace {
    # ADR-0005 Consequences：心跳的每一次跳過，除了機器層級 state.json 之外，還必須在
    # 專案裡留下使用者看得到的痕跡——把已知的失效藏起來，比沒有這個檢查更糟。
    #
    # 寫在 .hybrid/（進版控的專案層級位置，不是 _drive/）：下一次心跳如果沒被擋，這個
    # 檔案會被一起帶進 wip 分支、之後併入主線，變成 git 歷史裡看得到的紀錄，不會因為
    # 沒人剛好在那台機器前面就消失。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][object[]]$BlockingFindings
    )
    $now   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $files = @($BlockingFindings | ForEach-Object { $_.File } | Select-Object -Unique | Sort-Object)
    $rules = @($BlockingFindings | ForEach-Object { $_.Rule } | Select-Object -Unique | Sort-Object)
    $path  = Get-PreflightSkipLogPath -ProjectRoot $ProjectRoot

    # 阻擋項沒變就累加次數，不追加新的一筆。ADR-0005 要的是「留下看得到的痕跡」，
    # 不是「每 15 分鐘記一筆一模一樣的」——心跳每 15 分鐘跑一次，使用者的 .env 放著
    # 一天就是 96 行、一週約 670 行，而且會在他修好的那一刻整批被 commit 進 git 歷史。
    # 次數本身也是有用的資訊：它就是「這個專案已經多久沒有被心跳保護」的度量。
    $records = @(Read-JsonlRecords -Path $path)
    $last = if ($records.Count -gt 0) { $records[$records.Count - 1] } else { $null }
    $sameAsLast = $false
    if ($last) {
        # 不能走 Get-PropertyOrDefault——它的 -Default 是 [string]，傳 @() 會轉型失敗。
        $lastFiles = if ($last.PSObject.Properties['files']) { @($last.files) } else { @() }
        $lastRules = if ($last.PSObject.Properties['rules']) { @($last.rules) } else { @() }
        $sameAsLast = (($lastFiles -join '|') -eq ($files -join '|')) -and
                      (($lastRules -join '|') -eq ($rules -join '|'))
    }

    if ($sameAsLast) {
        $lastCount = if ($last.PSObject.Properties['count']) { [int]$last.count } else { 1 }
        $count = $lastCount + 1
        $record = [ordered]@{
            firstAt = if ($last.PSObject.Properties['firstAt']) { [string]$last.firstAt } else { $now }
            lastAt  = $now
            count   = $count
            device  = $env:COMPUTERNAME
            flow    = 'heartbeat'
            files   = $files
            rules   = $rules
        }
        $records[$records.Count - 1] = $record
        Write-JsonlRecords -Path $path -Records $records
    } else {
        $record = [ordered]@{
            firstAt = $now
            lastAt  = $now
            count   = 1
            device  = $env:COMPUTERNAME
            flow    = 'heartbeat'
            files   = $files
            rules   = $rules
        }
        Add-JsonlRecord -Path $path -Record $record
    }
    return $record
}

function Get-PreflightOverrideLogPath {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    return (Join-Path (Join-Path $ProjectRoot $script:HybridDirName) 'preflight-override-log.jsonl')
}

function Add-PreflightOverrideRecord {
    # 形狀對照 docs/preflight-policy.schema.json 的 $defs/overrideRecord。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidateSet('shutdown', 'proxy-shutdown')][string]$Flow,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string[]]$Files,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$CommitSha
    )
    $record = [ordered]@{
        overriddenAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        device       = $env:COMPUTERNAME
        sessionId    = $SessionId
        flow         = $Flow
        files        = @($Files | Select-Object -Unique)
        reason       = $Reason
        commitSha    = $CommitSha
    }
    Add-JsonlRecord -Path (Get-PreflightOverrideLogPath -ProjectRoot $ProjectRoot) -Record $record
    return $record
}
