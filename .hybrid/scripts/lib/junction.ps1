# junction 管理：建立、驗證、修正 _drive/ 的掛載。
#
# junction 用絕對路徑，進不了版控，所以每台裝置都得自己重建——這是「開工」存在的
# 主要理由（ADR-0001）。
#
# 這個模組唯一的危險動作是「移除」。git 與大部分遞迴刪除都會直接穿透 junction，
# 把 Drive 上的真實資料當成本機檔案處理。移除一律只拆連結本身，見 Remove-Junction。

Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'paths.ps1')

function Get-JunctionTarget {
    # 回傳 junction 記下的目標路徑；不是 junction 就回 $null。
    # 注意：目標已經消失時這裡「仍然」讀得到路徑——reparse point 存的是字串，
    # 不是指標。要判斷目標在不在，得另外去 Test-Path 那個目標。
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    if (-not $item.PSObject.Properties['Target']) { return $null }

    $target = @($item.Target) | Select-Object -First 1
    if (-not $target) { return $null }

    # 部分 reparse point 會帶 \??\ 前綴。
    return ($target -replace '^\\\?\?\\', '')
}

function Test-IsJunction {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint)
}

function New-Junction {
    # 不需要系統管理員權限（不像 symlink）。
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target
    )
    New-Item -ItemType Junction -Path $Path -Value $Target | Out-Null
}

function Remove-Junction {
    # 只拆掉連結本身。[IO.Directory]::Delete($path, $false) 呼叫的是 Win32
    # RemoveDirectory，與 rmdir 同一個語義：連結消失、目標一個位元組都沒動，
    # 而且不要求目標為空。
    #
    # 絕對不可以改成 Remove-Item -Recurse——它會穿透 junction 把 Drive 上的
    # 真實資料刪掉（ADR-0001）。這條有測試守著。
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-IsJunction -Path $Path)) {
        throw "拒絕移除 $Path：它不是 junction。"
    }
    [System.IO.Directory]::Delete($Path, $false)
}

function Test-DriveLinkMounted {
    # 收工／代理收工判斷「_drive/ 現在能不能用」要靠這個，不能只靠 Test-Path。
    #
    # `Test-Path` 對斷掉的 junction（目標消失、Drive 沒掛載、磁碟機代號變了）仍然
    # 回 `True`——reparse point 這個目錄項本身還在，只是它記的目標路徑解析不出東西
    # （唯讀審查第三輪第 1 條，實測重現）。這裡額外驗證 junction 記錄的目標路徑
    # 現在真的存在，才算「掛載著」。
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-IsJunction -Path $Path)) { return $false }
    $target = Get-JunctionTarget -Path $Path
    return [bool]($target -and (Test-Path -LiteralPath $target -PathType Container))
}

function Get-MountState {
    # 把 _drive/ 目前的狀況歸成一種狀態，先分類再動作。回傳 State 與 Target。
    #
    #   missing          不存在
    #   correct          是 junction，指向正確，目標在
    #   broken           是 junction，指向正確，但目標消失了
    #   wrong-target     是 junction，指向別的地方
    #   plain-directory  是一般資料夾——使用者的資料，不能碰
    #   plain-file       是檔案——同上
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedTarget
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ State = 'missing'; Target = $null }
    }

    if (-not (Test-IsJunction -Path $Path)) {
        $item = Get-Item -LiteralPath $Path -Force
        $state = if ($item.PSIsContainer) { 'plain-directory' } else { 'plain-file' }
        return [pscustomobject]@{ State = $state; Target = $null }
    }

    $target = Get-JunctionTarget -Path $Path
    if ($target -and ((Get-NormalisedPath $target) -eq (Get-NormalisedPath $ExpectedTarget))) {
        if (Test-Path -LiteralPath $target -PathType Container) {
            return [pscustomobject]@{ State = 'correct'; Target = $target }
        }
        return [pscustomobject]@{ State = 'broken'; Target = $target }
    }
    return [pscustomobject]@{ State = 'wrong-target'; Target = $target }
}
