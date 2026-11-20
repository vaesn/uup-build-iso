[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Marker,
    [int]$MaxRetry = 5
)

$ErrorActionPreference = 'Stop'

$time   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
$file   = $env:ISO_NAME
$repo   = $env:GITHUB_REPOSITORY
$branch = $env:DEFAULT_BRANCH
$url    = "https://github.com/$repo/releases/tag/$env:REVISION_NAME"
$link   = "[$file]($url)"
$block  = "<!-- $Marker -->`n$link`n`n($time UTC)`n<!-- /$Marker -->"
$pattern = "(?s)(<!-- $Marker -->).*?(<!-- /$Marker -->)"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

for ($i = 0; $i -lt $MaxRetry; $i++) {
    git fetch origin $branch
    git reset --hard "origin/$branch"
    $old     = Get-Content README.md -Raw -Encoding utf8
    $updated = [regex]::Replace($old, $pattern, { $block })
    if ($updated -eq $old) { break }
    [IO.File]::WriteAllText("$PWD/README.md", $updated, [Text.UTF8Encoding]::new($false))
    git add README.md
    git commit -m "update"
    git push
    if ($LASTEXITCODE -eq 0) { break }
}