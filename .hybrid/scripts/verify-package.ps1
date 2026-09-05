<#
.SYNOPSIS
    比對開工包的實際內容與 _bootstrap\MANIFEST.json。

.DESCRIPTION
    開工包的傳遞路徑是隨身碟、Google Drive、聊天視窗——每一條都可能默默改動內容。
    最典型的是把 .ps1 的換行或編碼「順手修好」，而這個 repo 對 BOM 與 CRLF 有硬性
    要求（docs\踩過的坑.md）。被改過的包不會當場報錯，它會在幾步之後長得像
    「腳本壞了」，離現場最遠。

    這支腳本只回答一個問題：**我手上這一份，跟產包的時候是不是同一份。**
    它不判斷內容對不對，也不修任何東西。

    **這是損壞檢查，不是防篡改。** 清單跟這支驗證腳本住在同一個包裡——有人蓄意
    改內容的話，把清單一起改掉就過了。要防那個需要外部信任錨（數位簽章，或用
    另一個管道核對雜湊），這裡沒有。

    寫明這件事是因為「有驗過」很容易被當成「可以信任」，而那個誤會比沒有驗證更糟：
    它會讓人在一份被動過手腳的包上安心地往下做。
    （這一條是外部審查提出的，實作前沒想到。）

.PARAMETER PackageRoot
    要驗的開工包資料夾。預設是這支腳本的上一層（也就是被放在 _bootstrap\ 裡執行時
    的那個包）。

.OUTPUTS
    exit 0 = 完全一致；1 = 有出入或驗不了。出入會逐項列出，不只給總數——
    「有三個檔案不一樣」沒辦法讓人做任何決定。
#>
[CmdletBinding()]
param(
    [string]$PackageRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $OutputEncoding

if (-not $PackageRoot) { $PackageRoot = Split-Path -Parent $PSScriptRoot }
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path

$manifestPath = Join-Path $PackageRoot '_bootstrap\MANIFEST.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Host "驗不了：找不到清單 $manifestPath"
    Write-Host "  這一份可能是清單機制之前產的包，也可能傳遞過程中掉了檔案。"
    Write-Host "  重新產一份包比猜它少了什麼快。"
    exit 1
}

try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Host "驗不了：清單讀不動（$manifestPath）：$($_.Exception.Message)"
    exit 1
}

# 清單自己不在清單裡，所以比對時要把它排除，否則它永遠算「多出來的檔案」。
$actual = @{}
Get-ChildItem -LiteralPath $PackageRoot -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($PackageRoot.Length).TrimStart('\')
    if ($relative -ne '_bootstrap\MANIFEST.json') {
        $actual[$relative] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
}

$missing = @()
$changed = @()
foreach ($entry in $manifest.files) {
    if (-not $actual.ContainsKey($entry.path)) {
        $missing += $entry.path
        continue
    }
    if ($actual[$entry.path] -ne $entry.sha256) { $changed += $entry.path }
}

# 多出來的檔案也要講。多一個檔案通常無害，但「多出來」這件事本身說明這一份不是
# 產包時的那一份——而那正是這支腳本唯一要回答的問題。
$expected = @{}
foreach ($entry in $manifest.files) { $expected[$entry.path] = $true }
$extra = @($actual.Keys | Where-Object { -not $expected.ContainsKey($_) } | Sort-Object)

Write-Host "開工包內容比對"
Write-Host "  位置    ：$PackageRoot"
Write-Host "  清單版本：$($manifest.toolVersion)（產於 $($manifest.createdAt)）"
Write-Host "  應有    ：$($manifest.fileCount) 個檔案"

if ($missing.Count -eq 0 -and $changed.Count -eq 0 -and $extra.Count -eq 0) {
    Write-Host "  結果    ：一致"
    exit 0
}

Write-Host "  結果    ：有出入"
foreach ($p in $missing) { Write-Host "    少了  ：$p" }
foreach ($p in $changed) { Write-Host "    被改過：$p" }
foreach ($p in $extra)   { Write-Host "    多出來：$p" }
Write-Host ""
Write-Host "被改過的多半是傳遞過程造成的（編輯器改了編碼或換行、雲端同步只複製了一半）。"
Write-Host "不要在這一份上面繼續——重新取一份包，或重新解壓縮一次。"
exit 1
