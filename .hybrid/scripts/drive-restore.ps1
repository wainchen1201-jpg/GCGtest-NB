<#
.SYNOPSIS
    Dry-run：依目前的素材 manifest 與第二備份清單，說明一次真正的還原「會做什麼」。

.DESCRIPTION
    這支腳本**不會複製、覆寫或刪除任何檔案**——它只讀 integrity\assets-manifest.json
    （drive-verify.ps1 -Generate 產生的基準線）與 integrity\backups.json（第二備份清單，
    見下方格式），算出「基準線記得、但現在的素材資料夾裡缺少或內容不同」的檔案，並
    對照備份清單說明一次真正的還原理論上會從哪裡、把哪些檔案複製回來。

    這個 repo 沒有備份系統，backups.json 完全由使用者或外部工具維護；這支腳本只讀，
    不寫。真正的複製動作永遠是手動的，或未來另一支工具的事——這一票的範圍是定義接口
    與 dry-run（票面原文），不是做一個會動手改 Drive 的還原程式。

    backups.json 格式：
        {
          "schemaVersion": 1,
          "projectId": "<專案 ID，供人核對用，不強制比對>",
          "backups": [
            {
              "id": "任意不重複的字串，例如 2026-08-01-manual",
              "createdAt": "ISO 8601 時間戳",
              "location": "備份放在哪裡；本工具不解讀這個字串，純粹顯示給人看",
              "coversAssetsSnapshotOf": "assets-manifest.json 的 manifestId，可留空",
              "notes": "任意說明，可留空"
            }
          ]
        }

    「缺少」在這裡分不出「使用者刪除」跟「Google Drive 還沒同步下來」——兩者要求相反
    的動作。所以不論帶不帶 -BackupId，這支腳本永遠只列出「如果要動手，理論上該做什
    麼」，並且在每一次列出候選還原的檔案時重申這個限制；它從不建議、也不提供任何自動
    執行還原的路徑。

.PARAMETER ProjectRoot
    專案在本機的位置。預設為目前目錄。

.PARAMETER DriveRoot
    Drive 端的根目錄。省略時依「本機設定檔 → 自動偵測」的順序解析。

.PARAMETER BackupId
    要規劃還原時參考的備份清單項目 id。省略時只列出所有可用的備份項目與目前的落差，
    不挑定其中一個。

.OUTPUTS
    exit 0 = dry-run 完成且沒有落差需要處理；1 = 失敗；2 = 停下來了，需要你判斷
    （沒有備份清單、沒有 manifest 基準線、指定的 -BackupId 找不到、或算出來的落差
    非空——任何一種都需要人決定下一步，這支腳本本身不會動手）。
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$DriveRoot,
    [string]$BackupId
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $OutputEncoding

. (Join-Path $PSScriptRoot 'lib\paths.ps1')
. (Join-Path $PSScriptRoot 'lib\integrity.ps1')

function Write-FileList {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Items, [Parameter(Mandatory)][scriptblock]$Format)
    foreach ($item in $Items) { Write-Host "  * $(& $Format $item)" }
}

try {
    $ProjectRoot = Resolve-ExistingProjectRoot -ProjectRoot $ProjectRoot

    $manifest = Read-ProjectManifest -ProjectRoot $ProjectRoot
    if (Test-Unreadable $manifest) {
        Write-Host "$(Get-ProjectManifestPath -ProjectRoot $ProjectRoot) 存在但無法解析（讀不動），可能還在同步中、暫時讀不到，也可能是內容損毀。"
        Write-Host "確認檔案內容之後再重跑。"
        exit $script:ExitNeedsYou
    }
    if (-not $manifest) {
        Write-Host "$ProjectRoot 還不是 hybrid workspace 專案（找不到 .hybrid\project.json）。"
        exit $script:ExitFailed
    }
    $projectId = [string]$manifest.projectId
    $assetsDirName = Get-PropertyOrDefault -InputObject $manifest -Name 'assetsDir' -Default $script:AssetsDirName

    $resolved = Resolve-DriveRoot -ProjectRoot $ProjectRoot -DriveRoot $DriveRoot
    if (Test-Unreadable $resolved) {
        Write-Host "$(Get-LocalConfigPath -ProjectRoot $ProjectRoot) 存在但無法解析（讀不動）。"
        Write-Host "確認檔案內容之後再重跑，或以 -DriveRoot 明確指定。"
        exit $script:ExitNeedsYou
    }
    if (-not $resolved) {
        Write-Host "找不到 Google Drive 的掛載點。請以 -DriveRoot 指定，或確認 Google Drive 已經登入。"
        exit $script:ExitNeedsYou
    }
    if (-not (Test-Path -LiteralPath $resolved.Path -PathType Container)) {
        Write-Host "Drive 端路徑不存在：$($resolved.Path)（來源：$($resolved.Source)）"
        exit $script:ExitNeedsYou
    }

    $projectDrivePath = Get-ProjectDrivePath -DriveRoot $resolved.Path -ProjectId $projectId
    if (-not (Test-Path -LiteralPath $projectDrivePath -PathType Container)) {
        Write-Host "停下來了：Drive 端找不到這個專案的資料夾：$projectDrivePath"
        Write-Host "「不在」分不出「還沒同步」跟「被刪掉」——不會替你猜。等同步完成或確認之後再重跑。"
        exit $script:ExitNeedsYou
    }
    $assetsPath = Join-Path $projectDrivePath $assetsDirName

    # --- 讀 manifest 基準線 ---------------------------------------------------
    $existingManifest = Read-AssetsManifest -ProjectDrivePath $projectDrivePath
    if (Test-Unreadable $existingManifest) {
        Write-Host "停下來了：manifest 存在但無法解析（讀不動）：$(Get-AssetsManifestPath -ProjectDrivePath $projectDrivePath)"
        Write-Host "確認內容之後再重跑，不會拿一份讀不動的基準線去規劃還原。"
        exit $script:ExitNeedsYou
    }
    if (-not $existingManifest) {
        Write-Host "沒有 manifest 基準線，無法判斷有哪些檔案需要還原。"
        Write-Host "先執行 drive-verify.ps1 -Generate 建立基準線。"
        exit $script:ExitNeedsYou
    }
    $manifestFiles = @($existingManifest.files | ForEach-Object {
        [pscustomobject]@{ Path = [string]$_.path; Sha256 = [string]$_.sha256; Size = [int64]$_.size }
    })
    $currentManifestId = Get-PropertyOrDefault -InputObject $existingManifest -Name 'manifestId' -Default ''

    # --- 算現在的落差（沿用跟 drive-verify 一樣的比對邏輯） --------------------
    $diff = $null
    if (Test-Path -LiteralPath $assetsPath -PathType Container) {
        $scan = Get-AssetFileScan -AssetsPath $assetsPath
        $diff = Compare-AssetManifest -ManifestFiles $manifestFiles -CurrentFiles $scan.Files -CurrentUnreadable $scan.Unreadable
    } else {
        Write-Host "素材資料夾現在不存在：$assetsPath"
        Write-Host "分不出「還沒同步」跟「被刪掉」——當成整批都可能需要還原來處理，"
        Write-Host "但也可能只是還沒同步，請先確認再繼續。"
        Write-Host ""
    }

    $restoreCandidates = New-Object System.Collections.ArrayList
    if ($diff) {
        Write-Host "跟基準線相比，現在的落差："
        Write-Host "  新增：$($diff.Added.Count)（不是還原對象——這些是基準線裡沒有的新檔案）"
        Write-Host "  遺失：$($diff.Missing.Count)"
        Write-Host "  內容變更：$($diff.Changed.Count)"
        Write-Host "  讀不到：$($diff.Unreadable.Count)（無法判斷，不納入還原候選）"
        Write-Host ""
        foreach ($m in $diff.Missing) { [void]$restoreCandidates.Add([pscustomobject]@{ Path = $m.Path; Kind = '遺失' }) }
        foreach ($c in $diff.Changed) { [void]$restoreCandidates.Add([pscustomobject]@{ Path = $c.Path; Kind = '內容變更' }) }
    }
    $restoreCandidates = @($restoreCandidates | Sort-Object -Property Path)

    if ($restoreCandidates.Count -eq 0) {
        Write-Host "跟基準線比對後，沒有檔案需要還原。"
        Write-Host ""
        Write-Host "本工具只做 dry-run，不論結果如何都不會複製、覆寫或刪除任何檔案。"
        exit $script:ExitOk
    }

    Write-Host "候選還原對象（$($restoreCandidates.Count) 個）："
    Write-FileList -Items $restoreCandidates -Format { param($i) "$($i.Path)（$($i.Kind)）" }
    Write-Host ""
    Write-Host "重要：「遺失」跟「Google Drive 還沒同步下來」在這裡分不出來，兩者要求相反的"
    Write-Host "動作。如果懷疑是還沒同步，不要現在就規劃還原——等 Drive 同步完成，重跑一次"
    Write-Host "drive-verify.ps1 確認落差還在，才考慮還原。"
    Write-Host ""

    # --- 讀備份清單（第二備份接口，本工具只讀不寫） ---------------------------
    $backupList = Read-BackupList -ProjectDrivePath $projectDrivePath
    if (Test-Unreadable $backupList) {
        Write-Host "停下來了：備份清單存在但無法解析（讀不動）：$(Get-BackupListPath -ProjectDrivePath $projectDrivePath)"
        Write-Host "確認內容之後再重跑，不會拿一份讀不動的備份清單去規劃還原。"
        exit $script:ExitNeedsYou
    }
    if (-not $backupList) {
        Write-Host "沒有設定第二備份清單：$(Get-BackupListPath -ProjectDrivePath $projectDrivePath)"
        Write-Host ""
        Write-Host "這一票的範圍是定義備份清單的接口與 dry-run，不包含建置備份系統本身"
        Write-Host "（票 27：真正的還原來源是第二備份，這個 repo 目前沒有）。"
        Write-Host "要讓 drive-restore.ps1 規劃還原，請先按照上面 -Generate 的說明或"
        Write-Host "scripts\drive-restore.ps1 的 SYNOPSIS 建立一份 integrity\backups.json。"
        Write-Host "在那之前，上面列出的候選對象只能靠別的管道找回：別台裝置的本機副本、"
        Write-Host "Google Drive 網頁版的版本歷史或垃圾桶。"
        exit $script:ExitNeedsYou
    }

    $backups = @($backupList.backups)
    if ($backups.Count -eq 0) {
        Write-Host "備份清單存在，但裡面沒有任何項目：$(Get-BackupListPath -ProjectDrivePath $projectDrivePath)"
        exit $script:ExitNeedsYou
    }

    if (-not $BackupId) {
        Write-Host "可用的備份項目（用 -BackupId 指定其中一個，才會列出詳細還原計畫）："
        foreach ($b in $backups) {
            $id = Get-PropertyOrDefault -InputObject $b -Name 'id' -Default '（未命名）'
            $createdAt = Get-PropertyOrDefault -InputObject $b -Name 'createdAt' -Default '（未記錄）'
            $location = Get-PropertyOrDefault -InputObject $b -Name 'location' -Default '（未記錄）'
            Write-Host "  * $id —— 建立於 $createdAt，位置：$location"
        }
        exit $script:ExitNeedsYou
    }

    $selected = @($backups | Where-Object { (Get-PropertyOrDefault -InputObject $_ -Name 'id' -Default '') -eq $BackupId })
    if ($selected.Count -eq 0) {
        Write-Host "備份清單裡找不到 id 為「$BackupId」的項目。可用的 id："
        foreach ($b in $backups) { Write-Host "  * $(Get-PropertyOrDefault -InputObject $b -Name 'id' -Default '（未命名）')" }
        exit $script:ExitNeedsYou
    }
    $backup = $selected[0]
    $backupLocation = Get-PropertyOrDefault -InputObject $backup -Name 'location' -Default '（未記錄）'
    $backupCovers = Get-PropertyOrDefault -InputObject $backup -Name 'coversAssetsSnapshotOf' -Default ''

    Write-Host "選定備份：$BackupId"
    Write-Host "  位置：$backupLocation"
    if ($backupCovers -and $currentManifestId -and $backupCovers -eq $currentManifestId) {
        Write-Host "  manifestId 相符——這份備份對應目前的基準線。"
    } elseif ($backupCovers) {
        Write-Host "  manifestId 不相符（備份記錄：$backupCovers；目前基準線：$currentManifestId）——"
        Write-Host "  不保證這份備份涵蓋現在列出的落差，動手前請自行確認備份內容的版本。"
    } else {
        Write-Host "  這份備份沒有記錄 coversAssetsSnapshotOf，無法自動核對版本，動手前請自行確認。"
    }
    Write-Host ""
    Write-Host "如果要真的還原，理論上會把下面這些檔案從「$backupLocation」複製回"
    Write-Host "「$assetsPath」，覆蓋現在（或補回遺失）的版本："
    Write-FileList -Items $restoreCandidates -Format { param($i) "$($i.Path)（$($i.Kind)）" }
    Write-Host ""
    Write-Host "本工具只做 dry-run，上面沒有任何檔案被複製、覆寫或刪除。真正的複製動作需要"
    Write-Host "你手動執行，或交給未來另一支工具——這支腳本不會、也不打算自己動手（ADR-0007"
    Write-Host "不變量 3：本套工具的任何路徑都不刪）。"

    exit $script:ExitNeedsYou
}
catch {
    Write-Host "drive-restore 失敗：$($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    exit $script:ExitFailed
}
