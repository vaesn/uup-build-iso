[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SrcDir,
    [Parameter(Mandatory = $true)][string]$DistDir,
    [Parameter(Mandatory = $true)][string]$RevisionName,
    [int]$MaxVolMB = 1895,
    [int]$ReserveMB = 4
)

$ErrorActionPreference = 'Stop'
$sep = "=" * 40

New-Item -Path $DistDir -ItemType Directory -Force | Out-Null
$isoFile = Get-ChildItem -Path $SrcDir -Filter "*.ISO" -File | Select-Object -First 1
if (-not $isoFile) { throw "No ISO file found in $SrcDir" }

$isoBase = $isoFile.BaseName
$isoSize = $isoFile.Length
$isoPath = $isoFile.FullName
$revision = $isoBase.Split('-')[0]

$sha256     = (Get-FileHash -Path $isoPath -Algorithm SHA256).Hash.ToLower()
$shortHash  = $sha256.Substring($sha256.Length - 8)
$isoName    = "${isoBase}_${shortHash}.ISO"
Rename-Item -Path $isoPath -NewName $isoName -Force
$isoOutPath = Join-Path -Path $SrcDir -ChildPath $isoName

$sizeMB   = $isoSize / 1MB
$sizeGB   = $isoSize / 1GB

$totalMB       = [int][Math]::Ceiling($sizeMB)
$plannedVols   = [int][Math]::Ceiling($totalMB / ($MaxVolMB - $ReserveMB))
$volSizeMB     = [int][Math]::Ceiling($totalMB / $plannedVols) + $ReserveMB
$lastVolSizeMB = $totalMB - $volSizeMB * ($plannedVols - 1)
$volDiffMB     = $volSizeMB - $lastVolSizeMB
$volSizeArg    = "${volSizeMB}M"

@(
    "ISO_SIZEMB={0:N2} MB" -f $sizeMB
    "ISO_SIZEGB={0:N2} GB" -f $sizeGB
    "VOLUME_SIZE=$volSizeArg"
    "VOLUME_COUNT=$plannedVols"
    "VOLUME_LAST=${lastVolSizeMB}M"
    "VOLUME_DIFF=$volDiffMB"
    "ISO_NAME=$isoName"
    "ISO_PATH=$isoOutPath"
    "ISO_REVISION=$revision"
    "REVISION_NAME=$RevisionName"
    "SHA256=$sha256"
) | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append

Write-Host $sep -ForegroundColor Cyan
Write-Host "  ISO Processing Information" -ForegroundColor Cyan
Write-Host $sep -ForegroundColor Cyan
Write-Host "  Name  : $isoName"
Write-Host ("  Size  : {0:N2} MB / {1:N2} GB" -f $sizeMB, $sizeGB)
Write-Host "  Path  : $isoOutPath"
Write-Host "  Rev   : $revision"
Write-Host "  SHA256: $sha256"
Write-Host "  Vol   : -v$volSizeArg x $plannedVols (last ${lastVolSizeMB} MB, diff $volDiffMB MB)"
Write-Host $sep -ForegroundColor Cyan

$archiveName = "${RevisionName}-${revision}_${shortHash}.7z"
$archivePath = Join-Path -Path $DistDir -ChildPath $archiveName
Write-Host "7z a -t7z -v$volSizeArg -mx=0 $archivePath $isoOutPath"
& 7z a -t7z -v"$volSizeArg" -mx=0 "$archivePath" "$isoOutPath"
if ($LASTEXITCODE -ne 0) { throw "7z failed with exit code $LASTEXITCODE" }
Write-Host "Generated archive: $archivePath"

$volFiles = @(
    Get-ChildItem -Path $DistDir -File |
        Where-Object { $_.Name -match '\.7z\.\d+$' } |
        Sort-Object { [int]($_.Name -replace '^.*\.7z\.', '') }
)
if ($volFiles.Count -eq 0) { throw "No 7z volume files found in $DistDir" }

$maxVolMBActual = ($volFiles | Measure-Object Length -Maximum).Maximum / 1MB
$minVolMBActual = ($volFiles | Measure-Object Length -Minimum).Minimum / 1MB
Write-Host ("Volumes: max {0:N2} MB / min {1:N2} MB / diff {2:N2} MB" -f $maxVolMBActual, $minVolMBActual, ($maxVolMBActual - $minVolMBActual))

$repo      = $env:GITHUB_REPOSITORY
$tag       = $RevisionName
$baseUrl   = "https://v4.gh-proxy.org/https://github.com/$repo/releases/download/$tag"
$firstPart = $volFiles[0].Name
$lastPart  = $volFiles[-1].Name
$partCount = $volFiles.Count

$tableRows = ($volFiles | ForEach-Object {
    $volName = $_.Name
    $volUrl  = [uri]::EscapeDataString($volName)
    $idx     = [int]($volName -replace '^.*\.7z\.', '')
    $ext     = [regex]::Match($volName, '\.7z\.\d+$').Value
    "| $idx | ``$volName`` | [下载 $ext]($baseUrl/$volUrl) |"
}) -join "`n"
$downloadTable = @("| Volume | File | Link |", "| --- | --- | --- |", $tableRows) -join "`n"

@(
    "FIRST_PART=$firstPart"
    "LAST_PART=$lastPart"
    "PART_COUNT=$partCount"
    "DOWNLOAD_BASE_URL=$baseUrl"
    "DOWNLOAD_LINKS<<EOF"
    $downloadTable
    "EOF"
) | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append

Write-Host $sep -ForegroundColor Cyan
Write-Host "  Dynamic Download Links" -ForegroundColor Cyan
Write-Host $sep -ForegroundColor Cyan
Write-Host "  Base URL  : $baseUrl"
Write-Host "  First Vol : $firstPart"
Write-Host "  Last Vol  : $lastPart"
Write-Host "  Vol Count : $partCount"
Write-Host $downloadTable
Write-Host $sep -ForegroundColor Cyan