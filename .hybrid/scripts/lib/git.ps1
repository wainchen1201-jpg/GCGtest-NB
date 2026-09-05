# git 操作：拉取、讀取進度、查心跳分支留下了什麼。
#
# 這一層刻意很薄。git 已經提供 merge、原子化更新與衝突偵測，我們不重做——
# antiuse 約七成的複雜度來自手工實作這些能力，接上 git 之後它們一併消失。

Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'paths.ps1')

function Invoke-Git {
    # 回傳 ExitCode 與 Output。stderr 不攔截，讓 git 自己說話——PowerShell 5.1 攔截
    # 原生指令的 stderr 會把每一行包成 ErrorRecord，反而製造假的失敗。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    # core.quotepath=false：否則含中文的檔名會被印成 octal 逃逸序列，使用者看到
    # 的是 "PC-A \347\232\204..." 而不是檔名。這裡的輸出是要給人看的。
    $output = & git -C $ProjectRoot -c core.quotepath=false @Arguments
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = (@($output) -join "`n").Trim()
    }
}

function Test-GitRepo {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    return (Test-Path -LiteralPath (Join-Path $ProjectRoot '.git'))
}

function Get-CurrentBranch {
    # symbolic-ref 而不是 rev-parse --abbrev-ref：剛 init、還沒有第一筆 commit 的
    # repo 也讀得到分支名，而且不會往 stderr 噴 fatal。
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $result = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('symbolic-ref', '--short', '-q', 'HEAD')
    if ($result.ExitCode -ne 0) { return $null }
    return $result.Output
}

function Test-HasCommits {
    # 同理，rev-parse --verify HEAD 在空 repo 會噴 fatal。rev-list 是安靜的：
    # 沒有 commit 就回空字串、exit 0。
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $result = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('rev-list', '-n', '1', '--all')
    return ($result.ExitCode -eq 0 -and $result.Output)
}

function Test-HasRemote {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $result = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('remote')
    return ($result.ExitCode -eq 0 -and $result.Output)
}

function Get-LastCommitSummary {
    # 「上次做到哪」。沒有 commit 就回 $null——新初始化的專案是正常狀態，不是錯誤。
    param([Parameter(Mandatory)][string]$ProjectRoot)
    if (-not (Test-HasCommits -ProjectRoot $ProjectRoot)) { return $null }
    $result = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('log', '-1', '--date=short', '--format=%h %ad %s')
    if ($result.ExitCode -ne 0) { return $null }
    return $result.Output
}

function Invoke-MainlinePull {
    # 回傳 State：no-remote / no-commits / pulled / failed。
    # 沒有 remote 不是錯誤——離線或還沒接 GitHub 的專案照樣要能開工。
    param([Parameter(Mandatory)][string]$ProjectRoot)

    if (-not (Test-HasRemote -ProjectRoot $ProjectRoot)) {
        return [pscustomobject]@{ State = 'no-remote'; Detail = '' }
    }
    if (-not (Test-HasCommits -ProjectRoot $ProjectRoot)) {
        return [pscustomobject]@{ State = 'no-commits'; Detail = '' }
    }
    # 先自己判斷分岔，而不是讓 pull 去撞牆。
    # git 的失敗原因走 stderr，而我們刻意不攔 stderr（攔了在 PS 5.1 會製造假失敗），
    # 所以撞牆之後只能回報一個空白的理由。與其如此，不如先問清楚再決定。
    $branch = Get-CurrentBranch -ProjectRoot $ProjectRoot
    if (-not $branch) {
        return [pscustomobject]@{ State = 'failed'; Detail = '讀不到目前的分支' }
    }
    # fetch 的 exit code 一定要接住。票 18 把拉取從「回報用」升格成驗證閘門之後，
    # 漏看它就等於「閘門可以用過期資料放行」：只要本機不落後於**上次成功 fetch 留下的**
    # origin/<branch>，下面就會回 up-to-date、根本走不到 pull --ff-only，於是離線或
    # 認證失敗完全不會浮出來（唯讀審查第 1 條實測：remote 指到不存在的路徑時，開工
    # 照樣 exit 0、取得租約、印「已經是最新的」，而遠端其實已經前進一筆）。
    # 原因不猜（git.ps1 刻意不攔 stderr），交給呼叫端並列三種可能性。
    $fetch = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('fetch', '--quiet', 'origin')
    if ($fetch.ExitCode -ne 0) {
        return [pscustomobject]@{ State = 'failed'; Detail = "拿不到遠端的最新狀態（fetch 結束碼 $($fetch.ExitCode)）" }
    }

    $upstream = "origin/$branch"
    if (-not (Get-RefCommit -ProjectRoot $ProjectRoot -Ref $upstream)) {
        return [pscustomobject]@{ State = 'no-upstream'; Detail = $upstream }
    }

    $localOnly  = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('rev-list', '--count', "$upstream..$branch")
    $remoteOnly = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('rev-list', '--count', "$branch..$upstream")
    $ahead  = if ($localOnly.ExitCode -eq 0)  { [int]$localOnly.Output }  else { 0 }
    $behind = if ($remoteOnly.ExitCode -eq 0) { [int]$remoteOnly.Output } else { 0 }

    if ($ahead -gt 0 -and $behind -gt 0) {
        return [pscustomobject]@{
            State  = 'diverged'
            Detail = "本機多 $ahead 筆、遠端多 $behind 筆"
        }
    }
    if ($behind -eq 0) {
        return [pscustomobject]@{ State = 'up-to-date'; Detail = '' }
    }

    $result = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('pull', '--ff-only')
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{ State = 'failed'; Detail = $result.Output }
    }
    return [pscustomobject]@{ State = 'pulled'; Detail = "拉進 $behind 筆" }
}

function Test-GitOperationInProgress {
    # 心跳是背景執行的，隨時可能撞上使用者正在做的 rebase、merge 或 commit。
    # 撞上就跳過這一次——下一次心跳還會來，但打斷一個 rebase 沒有下一次。
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $gitDir = Join-Path $ProjectRoot '.git'
    foreach ($marker in @('rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD',
                          'REVERT_HEAD', 'BISECT_LOG', 'index.lock')) {
        if (Test-Path -LiteralPath (Join-Path $gitDir $marker)) { return $true }
    }
    return $false
}

function ConvertTo-RemoteIdentity {
    # 把 remote URL 解析成 Host/Owner/Repo，https 與 scp-like ssh 語法都吃
    # （票 26：「git remote get-url 的格式有 https 與 ssh 兩種，解析要兩種都吃得下」）。
    #
    # 解析不出來（本機路徑、bare repo 的檔案系統路徑——這個 repo 的測試套件本身
    # 大量使用這種 origin）回 $null，呼叫端把它當成「無法比對」，不是「不符」。
    # 這不是漏洞：這個檢查要抓的是「同一個 GitHub/GitLab 之類的 host 上，owner/repo
    # 被換掉了」，本機路徑從一開始就沒有 owner/repo 這個概念可以比對。
    # 【票 30 F7】原本兩條正則都寫死「host 後面剛好兩段」（`owner/repo`），
    # 也就是只認得 GitHub／Bitbucket 那種扁平形狀。實測（探針，13 種真實 URL）：
    #
    #   github.com/owner/repo               → 解析得出
    #   gitlab.com/group/subgroup/repo      → **解析不出**
    #   dev.azure.com/org/project/_git/repo → **解析不出**
    #   server/gitea/org/team/repo          → **解析不出**
    #
    # 而解析不出來的下一步是「無法比對，不阻擋」。所以**用 GitLab 子群組或
    # Azure DevOps 的人，這道保護從來沒有生效過，而且沒有任何訊息說「我沒比」**
    # ——無聲失效的第一種形態，出現在一道安全檢查上。
    #
    # 改成：host 後面的整段路徑都收下來，最後一段是 repo，其餘是 owner。
    # 兩個 URL 只要指向同一個地方就會算出同一組值，指向不同地方就會被抓到。
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RemoteUrl)
    if (-not $RemoteUrl) { return $null }
    $url = $RemoteUrl.Trim()

    # $host 是 PowerShell 的唯讀自動變數，而變數名**不分大小寫**——用 $host 會在
    # 執行期炸「Cannot overwrite variable Host」。跟 PC2 當初找到的 $listPath 遮蔽
    # $ListPath 同一族（docs\踩過的坑.md）。
    $remoteHost = $null
    $remotePath = $null
    # scp-like：user@host:路徑
    if ($url -match '^[^/@\s]+@(?<host>[^:/\s]+):(?<path>[^\s]+)$') {
        $remoteHost = $Matches['host']; $remotePath = $Matches['path']
    }
    # ssh:// 或 https://
    elseif ($url -match '^(?:https?|ssh)://(?:[^@/\s]+@)?(?<host>[^:/\s]+)(?::\d+)?/(?<path>[^\s]+)$') {
        $remoteHost = $Matches['host']; $remotePath = $Matches['path']
    }
    else {
        # 本機路徑、bare repo 的檔案系統路徑（這個 repo 的測試套件大量使用這種
        # origin）——沒有 host/路徑 這個概念可以比對，回 $null。呼叫端會把它當成
        # 「無法比對」，不是「不符」。這一條沒有改。
        return $null
    }

    $remotePath = $remotePath.TrimEnd('/')
    if ($remotePath -match '(?i)\.git$') { $remotePath = $remotePath.Substring(0, $remotePath.Length - 4) }
    $segments = @($remotePath -split '/' | Where-Object { $_ })
    # 至少要 owner + repo 兩段。只有一段（`https://host/repo`）不是這個檢查認得的
    # 形狀，寧可回「無法比對」也不要猜一個空的 owner 出來。
    if ($segments.Count -lt 2) { return $null }

    return [pscustomobject]@{
        Host  = $remoteHost.ToLowerInvariant()
        # 中間所有層級都算進 owner。GitLab 的 group/subgroup、Azure 的
        # org/project/_git 都落在這裡，於是它們之間的差異抓得到了。
        Owner = ($segments[0..($segments.Count - 2)] -join '/')
        Repo  = $segments[-1]
    }
}

function Test-RemoteIdentityMismatch {
    # 兩個 remote URL 都解析得出 Host/Owner/Repo 時才比較；任一邊解析不出來
    # （本機路徑、bare repo——測試與離線情境常見）視為「無法比對」，回 $false
    # （不阻擋）——「不猜」的意思是不猜哪一個對，不是把「看不懂」當成「不符」。
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RemoteA,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RemoteB
    )
    $a = ConvertTo-RemoteIdentity -RemoteUrl $RemoteA
    $b = ConvertTo-RemoteIdentity -RemoteUrl $RemoteB
    if ((-not $a) -or (-not $b)) { return $false }
    return -not ($a.Host -eq $b.Host -and $a.Owner -eq $b.Owner -and $a.Repo -eq $b.Repo)
}

function Get-RefCommit {
    # ref 指向的 commit sha；ref 不存在回 $null。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Ref
    )
    $result = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('rev-parse', '--verify', '--quiet', $Ref)
    if ($result.ExitCode -ne 0 -or -not $result.Output) { return $null }
    return $result.Output
}

function Assert-DriveLinkIgnored {
    # 任何會 stage 整個工作區的動作，動手前都要先確認 _drive/ 真的被排除。
    # 這是 ADR-0001 的正確性要求：git 會直接穿透 junction，把整個雲端資料夾
    # 當成本機檔案收進歷史。寧可停下來，也不要事後才發現。
    #
    # （不能用 :(exclude) pathspec 擋——顯式點名一個被 gitignore 排除的路徑，
    # git 會報錯退出，等於這道保險只在它該生效的時候會炸。）
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $linkPath = Join-Path $ProjectRoot $script:DriveLinkName
    if (-not (Test-Path -LiteralPath $linkPath)) { return }

    $ignored = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('check-ignore', '-q', $script:DriveLinkName)
    if ($ignored.ExitCode -ne 0) {
        throw "$($script:DriveLinkName)/ 沒有被 .gitignore 排除，拒絕繼續——再跑下去會把整個 Drive 資料夾寫進 git 歷史（ADR-0001）。"
    }
}

function Assert-NoContentThroughJunction {
    # 【票 30 對抗審查 F5】上面那條守的是 `_drive/` 這一個 junction。但
    # **git 穿透 junction 這件事對每一個 junction 都成立**，而排除清單只寫死了那一個。
    #
    # 實測：在專案裡建一個指向外部資料夾的 junction（`mklink /J`，不需要提權），
    # 心跳照樣把那個資料夾底下的檔案收進 commit。心跳每 15 分鐘自動跑、自動推——
    # 使用者在專案裡建一個指向「圖片」的捷徑，就會靜靜地把它發佈到遠端。
    #
    # ADR-0001 那句「git 會直接穿透 junction、把雲端內容當成一般檔案收錄，所以排除它
    # 是正確性要求而不是慣例」本來就是通則，只是實作時只套用在自己建的那一個上。
    #
    # 這裡跟 Assert-DriveLinkIgnored 同一類：**正確性要求，不是政策**，所以不走
    # preflight（那條路可以 override），而是硬性中止。
    #
    # 成本：只看 git 認為「即將被收進來」的路徑，再往上檢查它們的祖先目錄是不是
    # reparse point。成本跟這一次的變更量成正比，不是跟整個 repo 的大小成正比——
    # 直接走檔案系統列舉會在大專案上每 15 分鐘掃一次整棵樹。
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $status = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('status', '--porcelain', '-z', '--untracked-files=all')
    if (-not $status.Output) { return }

    $checked = @{}
    $offenders = New-Object System.Collections.ArrayList

    foreach ($entry in ($status.Output -split "`0")) {
        if ([string]::IsNullOrEmpty($entry) -or $entry.Length -lt 4) { continue }
        $relative = $entry.Substring(3)
        $segments = @(($relative -replace '\\', '/') -split '/')
        if ($segments.Count -lt 2) { continue }   # 頂層檔案沒有祖先目錄可查

        # 只查目錄那幾段，最後一段是檔名。
        for ($i = 0; $i -lt $segments.Count - 1; $i++) {
            $dirRelative = ($segments[0..$i] -join '/')
            if ($checked.ContainsKey($dirRelative)) {
                if ($checked[$dirRelative]) { break }
                continue
            }
            $isJunction = $false
            if ($dirRelative -ne $script:DriveLinkName) {
                $full = Join-Path $ProjectRoot ($dirRelative -replace '/', '\')
                $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
                if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    $isJunction = $true
                }
            }
            $checked[$dirRelative] = $isJunction
            if ($isJunction) {
                if (-not ($offenders -contains $dirRelative)) { [void]$offenders.Add($dirRelative) }
                break
            }
        }
    }

    if ($offenders.Count -eq 0) { return }

    $list = ($offenders | ForEach-Object { "  $_/" }) -join "`n"
    throw @"
拒絕繼續：專案裡有 $($script:DriveLinkName)/ 以外的 junction（或符號連結），而且沒有被 .gitignore 排除。
$list

git 會直接穿透它們，把連結指向的內容當成這個專案的檔案收進歷史並推上遠端——
那些內容可能根本不屬於這個專案（ADR-0001 對 $($script:DriveLinkName)/ 講的是同一件事）。

三條路，選一條：
  * 那個位置本來就該同步 → 把內容真的放進專案，不要用連結
  * 只是自己用的捷徑 → 加進 .gitignore
  * 那是另一個 Drive 掛載點 → 加進 .gitignore，並確認它不該被這個專案追蹤
"@
}

function Test-TreeContainsDriveLink {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Tree
    )
    $top = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('ls-tree', '--name-only', $Tree)
    return (@($top.Output -split "`n" | ForEach-Object { $_.Trim('"') }) -contains $script:DriveLinkName)
}

function New-WorkTreeSnapshot {
    # 把目前工作區的內容寫成一個 git tree，**完全不碰使用者的 index 與工作區**。
    #
    # 這是心跳能在使用者工作到一半時安全執行的關鍵：走 GIT_INDEX_FILE 指到另一個
    # 暫存 index，git add 只會動那一份。使用者那邊什麼感覺都沒有——不會有檔案被
    # 暫存、不會有分支被切換、正在編輯的東西不受影響。
    #
    # 回傳 tree 的 sha。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$SeedRef
    )

    $indexPath = Join-Path (Join-Path $ProjectRoot '.git') 'heartbeat-index'
    if (Test-Path -LiteralPath $indexPath) { Remove-Item -LiteralPath $indexPath -Force }

    $previous = $env:GIT_INDEX_FILE
    $env:GIT_INDEX_FILE = $indexPath
    try {
        if ($SeedRef) {
            $read = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('read-tree', $SeedRef)
            if ($read.ExitCode -ne 0) { throw "read-tree $SeedRef 失敗" }
        }

        Assert-DriveLinkIgnored -ProjectRoot $ProjectRoot
        Assert-NoContentThroughJunction -ProjectRoot $ProjectRoot

        $add = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('add', '-A')
        if ($add.ExitCode -ne 0) { throw "add 失敗" }

        $tree = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('write-tree')
        if ($tree.ExitCode -ne 0) { throw "write-tree 失敗" }

        # 檢查結果而不只是宣告意圖：真的產生出來的 tree 裡不能有 _drive。
        if (Test-TreeContainsDriveLink -ProjectRoot $ProjectRoot -Tree $tree.Output) {
            throw "產生的 tree 裡出現了 $($script:DriveLinkName)，心跳中止，不提交。"
        }
        return $tree.Output
    }
    finally {
        if ($previous) { $env:GIT_INDEX_FILE = $previous }
        else { Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $indexPath) { Remove-Item -LiteralPath $indexPath -Force }
    }
}

function Get-TreeOfCommit {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Commit
    )
    $result = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('rev-parse', '--verify', '--quiet', "$Commit^{tree}")
    if ($result.ExitCode -ne 0) { return $null }
    return $result.Output
}

function New-CommitFromTree {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Tree,
        [string]$Parent,
        [Parameter(Mandatory)][string]$Message
    )
    $arguments = @('commit-tree', $Tree)
    if ($Parent) { $arguments += @('-p', $Parent) }
    $arguments += @('-m', $Message)

    $result = Invoke-Git -ProjectRoot $ProjectRoot -Arguments $arguments
    if ($result.ExitCode -ne 0) { throw "commit-tree 失敗" }
    return $result.Output
}

function Update-GitRef {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Ref,
        [Parameter(Mandatory)][string]$Commit
    )
    $result = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('update-ref', $Ref, $Commit)
    if ($result.ExitCode -ne 0) { throw "update-ref $Ref 失敗" }
}

function Get-HeartbeatWorkdirHash {
    # 同一台裝置（同一個 deviceId）上可能有這個專案的兩個 clone（ADR-0003）——
    # deviceId 分不出它們，所以再疊一個工作目錄路徑的雜湊前 8 碼（票 26；票 22
    # 設計分析拍板，見 .scratch/hybrid-workspace/issues/22-writable-lease-v2-design.md
    # 的「交辦端裁決的四項」第 2 項）。
    #
    # 用 SHA256 而不是 .NET 的 GetHashCode：後者不保證跨版本、跨行程穩定，這裡
    # 需要的是「同一個字串在任何時候、任何一次執行都算出同一個值」，不需要
    # 密碼學等級的碰撞強度，但 SHA256 免費附送這個穩定性保證。
    #
    # 先正規化再轉小寫：Windows 路徑不分大小寫，同一個實體目錄用不同大小寫字串
    # 傳進來（例如手動輸入 vs Resolve-Path 展開）不該算出兩個不同的雜湊。
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $normalised = (Get-NormalisedPath $ProjectRoot).ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalised)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $algorithm.ComputeHash($bytes)
    } finally {
        $algorithm.Dispose()
    }
    $hex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    return $hex.Substring(0, 8)
}

function Get-HeartbeatBranchName {
    # 扁平、不用斜線（避免 git 的 D/F 衝突，票面明寫）：
    # wip/<deviceId>-<工作目錄路徑雜湊前 8 碼>（票 26）。
    #
    # 不能只用 wip/<deviceId>：同一台裝置的兩個 clone 是同一個 deviceId，那個形狀
    # 修不了兩者共用分支的問題（票面明寫；票 22 設計分析拍板）。這是新寫入一律
    # 走的路徑——讀取既有租約記錄的 heartbeatRef 一律照字面用，不重算
    # （ADR-0006：持有者寫下的名字是唯一權威）。v1 相容的回退重算走
    # Get-LegacyHeartbeatBranchName，不是這支。
    param(
        [Parameter(Mandatory)][string]$DeviceId,
        [Parameter(Mandatory)][string]$ProjectRoot
    )
    return "wip/$DeviceId-$(Get-HeartbeatWorkdirHash -ProjectRoot $ProjectRoot)"
}

function Get-LegacyHeartbeatBranchName {
    # 票 26 之前的命名規則：只有裝置名，沒有雜湊。只給 v1 租約（沒有 heartbeatRef
    # 欄位）的心跳分支回退重算用——讀取端一律以租約記的 heartbeatRef 為準
    # （ADR-0006），這支不是給新寫入用的。
    param([Parameter(Mandatory)][string]$Device)
    return "wip/$Device"
}

function Get-HeartbeatBranchInfo {
    # 另一台裝置「留下了什麼」。這是使用者判斷要不要代理收工的依據，所以心跳沒跑過
    # 也要說得明白——那代表拿不回它的變更（ADR-0002 的降級情境）。
    #
    # 回傳 Found、Ref、LastCommit、AheadCount。
    #
    # -Ref：租約記錄的 heartbeatRef 給定時直接用它，不由 -Device 重算——心跳分支的
    # 命名規則已經變了（票 26），持有者寫下的名字是唯一權威（ADR-0006 段落 A）。
    # 租約沒有這個欄位（v1）才退回用 -Device 走 Get-LegacyHeartbeatBranchName 重算，
    # 既有呼叫端不傳 -Ref 時行為不變。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Device,
        [string]$Ref
    )
    $branch = if ($Ref) { $Ref } else { Get-LegacyHeartbeatBranchName -Device $Device }
    $found = $null
    foreach ($ref in @("refs/remotes/origin/$branch", "refs/heads/$branch")) {
        if ((Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('rev-parse', '--verify', '--quiet', $ref)).ExitCode -eq 0) {
            $found = $ref
            break
        }
    }
    if (-not $found) {
        return [pscustomobject]@{ Found = $false; Ref = $branch; LastCommit = $null; AheadCount = 0 }
    }

    $last = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('log', '-1', '--date=relative', '--format=%h %ad %s', $found)
    $ahead = 0
    $current = Get-CurrentBranch -ProjectRoot $ProjectRoot
    if ($current) {
        $count = Invoke-Git -ProjectRoot $ProjectRoot -Arguments @('rev-list', '--count', "$current..$found")
        if ($count.ExitCode -eq 0) { $ahead = [int]$count.Output }
    }
    return [pscustomobject]@{
        Found      = $true
        Ref        = $found
        LastCommit = $last.Output
        AheadCount = $ahead
    }
}
