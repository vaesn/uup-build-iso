#!/usr/bin/pwsh

param(
  [string]$windowsTargetName,
  [string]$destinationDirectory = (Join-Path $PSScriptRoot 'dist'),
  [ValidateSet("x64")] [string]$architecture = "x64",
  [ValidateSet("pro")] [string]$edition = "pro",
  [ValidateSet("en-us", "zh-cn", "zh-tw")]
  [string]$lang = "zh-cn",
  [switch]$esd,
  [switch]$netfx3,
  [string]$revision,
  [string]$autounattend
)

Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

$preview  = $false
$ringLower = $null

trap {
  Write-Host "ERROR: $_"
  @(($_.ScriptStackTrace -split '\r?\n') -replace '^(.*)$','ERROR: $1') | Write-Host
  @(($_.Exception.ToString() -split '\r?\n') -replace '^(.*)$','ERROR EXCEPTION: $1') | Write-Host
  Exit 1
}

# ------------------------------
# Log helpers + DISM bucketed progress (no aria2 parsing)
# ------------------------------
$script:reAnsi = [regex]'\x1B\[[0-9;]*[A-Za-z]'
$script:LastPrintedLine = $null
function Write-CleanLine([string]$text) {
  $clean = $script:reAnsi.Replace(($text ?? ''), '')
  if ($clean -eq $script:LastPrintedLine) { return }
  $script:LastPrintedLine = $clean
  Write-Host $clean
}

# DISM buckets (0/10/.../100)
$script:DismLastBucket = -1
$script:DismEveryPercent = 10
if ($env:DISM_PROGRESS_STEP) {
  $v = 0
  if ([int]::TryParse($env:DISM_PROGRESS_STEP, [ref]$v) -and $v -ge 1 -and $v -le 100) {
    $script:DismEveryPercent = $v
  }
}
$script:DismNormalizeOutput = if ($env:DISM_PROGRESS_RAW -eq '1') { $false } else { $true }

$script:reArchiving = [regex]'Archiving file data:\s+.*?\((\d+)%\)\s+done'
$script:reBracket   = [regex]'\[\s*[= \-]*\s*(\d+(?:[.,]\d+)?)%\s*[= \-]*\s*\]'
$script:reLoosePct  = [regex]'(^|\s)(\d{1,3})(?:[.,]\d+)?%(\s|$)'

function Get-PercentFromText([string]$text) {
  if ([string]::IsNullOrEmpty($text)) { return $null }
  $t = $script:reAnsi.Replace($text, '')

  $m = $script:reArchiving.Match($t)
  if ($m.Success) { return [int]$m.Groups[1].Value }

  $m = $script:reBracket.Match($t)
  if ($m.Success) {
    $pct = $m.Groups[1].Value -replace ',', '.'
    return [int][math]::Floor([double]$pct)
  }

  $m = $script:reLoosePct.Match($t)
  if ($m.Success) {
    $n = [int]$m.Groups[2].Value
    if ($n -ge 0 -and $n -le 100) { return $n }
  }
  return $null
}

function Reset-ProgressSession { $script:DismLastBucket = -1 }

function Emit-ProgressBucket([int]$pct) {
  $bucket = [int]([math]::Floor($pct / $script:DismEveryPercent) * $script:DismEveryPercent)
  if ($bucket -le $script:DismLastBucket) { return $false }
  $script:DismLastBucket = $bucket

  if ($script:DismNormalizeOutput) { Write-CleanLine ("[DISM] Progress: {0}%" -f $bucket) }
  else { Write-CleanLine ("Progress: {0}%" -f $bucket) }

  if ($bucket -ge 100) {
    Write-CleanLine "[DISM] Progress: 100% (done)"
    Reset-ProgressSession
  }
  return $true
}

function Process-ProgressLine([string]$line) {
  $pct = Get-PercentFromText $line
  if ($pct -eq $null) { return $false }
  if ($script:DismLastBucket -ge 0 -and $pct -lt $script:DismLastBucket) { Reset-ProgressSession }
  [void](Emit-ProgressBucket $pct)
  return $true
}

# ------------------------------
# Basic metadata helpers
# ------------------------------
$arch = if ($architecture -eq "x64") { "amd64" } else { "arm64" }

if ($windowsTargetName -match 'beta|dev|wif|canary') {
  $preview = $true
  $ringLower = @('beta','dev','wif','canary').Where({$windowsTargetName -match $_})[0]
}


$dotSystemRevision = if ([string]::IsNullOrWhiteSpace($revision)) { '' } else { ".$revision" }
# $systemRevision = if ([string]::IsNullOrWhiteSpace($revision)) { '' } else { " $revision" }

$TARGETS = @{
  "win10-22h2" = @{ search="windows 10 19045$dotSystemRevision $arch"; edition="Professional" }
  "win11-25h2" = @{ search="windows 11 26200$dotSystemRevision $arch"; edition="Professional" }
  "win11-26h2" = @{ search="windows 11 26300$dotSystemRevision $arch"; edition="Professional" }
}

function New-QueryString([hashtable]$parameters) {
  @($parameters.GetEnumerator() | ForEach-Object { "$($_.Key)=$([System.Net.WebUtility]::UrlEncode([string]$_.Value))" }) -join '&'
}

function Invoke-UupDumpApi([string]$name, [hashtable]$body) {
  for ($n = 0; $n -lt 15; ++$n) {
    if ($n) {
      Write-CleanLine "Waiting a bit before retrying the uup-dump api ${name} request #$n"
      Start-Sleep -Seconds 10
      Write-CleanLine "Retrying the uup-dump api ${name} request #$n"
    }
    try {
      $qs = if ($body) { '?' + (New-QueryString $body) } else { '' }
      return Invoke-RestMethod -Method Get -Uri ("https://api.uupdump.net/{0}.php{1}" -f $name, $qs)
    } catch {
      Write-CleanLine "WARN: failed the uup-dump api $name request: $_"
    }
  }
  throw "timeout making the uup-dump api $name request"
}

function Get-UupDumpIso($name, $target) {
  Write-CleanLine "Getting the $name metadata"
  $result = Invoke-UupDumpApi listid @{ search = $target.search }

  $result.response.builds.PSObject.Properties
  | ForEach-Object {
      $id = $_.Value.uuid
      $uupDumpUrl = 'https://uupdump.net/selectlang.php?' + (New-QueryString @{ id = $id })
      Write-CleanLine "Processing $name $id ($uupDumpUrl)"
      $_
    }
  | Where-Object {
      if ($_.Value.title -match '\.NET Framework') {
            Write-CleanLine "Skipping, ignore .NET Framework update."
            return $false
        }
      if ($_.Value.title -match 'Windows CPC OS') {
            Write-CleanLine "Skipping, ignore Windows CPC OS."
            return $false
        }
      if (!$preview) {
        $ok = ($target.search -like '*preview*') -or ($_.Value.title -notlike '*preview*')
        if (-not $ok) {
          Write-CleanLine "Skipping.
L1: Expected preview=false.
L2: Got preview=true."
        }
        return $ok
      }
      $true
    }
  | ForEach-Object {
      $id = $_.Value.uuid
      Write-CleanLine "Getting the $name $id langs metadata"
      $result = Invoke-UupDumpApi listlangs @{ id = $id }
      if ($result.response.updateInfo.build -ne $_.Value.build) {
        throw 'for some reason listlangs returned an unexpected build'
      }
      $_.Value | Add-Member -NotePropertyMembers @{ langs = $result.response.langFancyNames; info = $result.response.updateInfo } -Force

      $langs = $_.Value.langs.PSObject.Properties.Name
      $eds = if ($langs -contains $lang) {
        Write-CleanLine "Getting the $name $id editions metadata"
        $result = Invoke-UupDumpApi listeditions @{ id = $id; lang = $lang }
        $result.response.editionFancyNames
      } else {
        Write-CleanLine "Skipping.
L3: Expected langs=$lang.
L4: Got langs=$($langs -join ',')."
        [PSCustomObject]@{}
      }
      $_.Value | Add-Member -NotePropertyMembers @{ editions = $eds } -Force
      $_
    }
  | Where-Object {
      $langs = $_.Value.langs.PSObject.Properties.Name
      $editions = $_.Value.editions.PSObject.Properties.Name
      $res = $true

      if ($ringLower) {
        $actual = ($_.Value.info.ring).ToUpper()
        $allowedRings = switch ($ringLower) {
          'canary' { 'CANARY', 'WIF' }
          'dev'    { 'DEV', 'WIF', 'WIS' }
          'beta'   { 'BETA', 'WIF', 'WIS' }
          default { $ringLower.ToUpper() }
        }

        if ($actual -notin $allowedRings) {
          Write-CleanLine "Skipping. Expected ring: $($allowedRings -join ', '). Got ring=$actual."
          $res = $false
        }
      }

      if ($langs -notcontains $lang) {
        Write-CleanLine "Skipping. Expected langs=$lang. Got langs=$($langs -join ',')."
        $res = $false
      }

      if ($editions -notcontains "Professional") {
        Write-CleanLine ("Skipping. Expected editions=Professional. Got editions={0}." -f ($editions -join ','))
        $res = $false
      }

      if (!$preview -and -not ($_.Value.title -match 'version')) {
        Write-CleanLine "Skipping. Unexpected title format: missing 'version'."
        $res = $false
      }
      $res
    }
  | Select-Object -First 1
  | ForEach-Object {
      $id = $_.Value.uuid
      [PSCustomObject]@{
        name               = $name
        title              = $_.Value.title
        build              = $_.Value.build
        id                 = $id
        edition            = $target.edition
        apiUrl             = 'https://api.uupdump.net/get.php?' + (New-QueryString @{ id = $id; lang = $lang; edition = "Professional" })
        downloadUrl        = 'https://uupdump.net/download.php?' + (New-QueryString @{ id = $id; pack = $lang; edition = "Professional" })
        downloadPackageUrl = 'https://uupdump.net/get.php?' + (New-QueryString @{ id = $id; pack = $lang; edition = "Professional" })
      }
    }
}

function Get-IsoWindowsImages($isoPath) {
  $isoPath = Resolve-Path $isoPath
  Write-CleanLine "Mounting $isoPath"
  $isoImage = Mount-DiskImage $isoPath -PassThru
  try {
    $driveLetter = $null
    for ($i = 0; $i -lt 10 -and -not $driveLetter; $i++) {
      if ($i -gt 0) { Start-Sleep -Milliseconds 500 }
      $driveLetter = (Get-Volume -DiskImage $isoImage -ErrorAction SilentlyContinue).DriveLetter
    }
    if (-not $driveLetter) { throw "Failed to determine drive letter for $isoPath" }

    $installPath = if ($esd) { "$($driveLetter):\sources\install.esd" } else { "$($driveLetter):\sources\install.wim" }
    Write-CleanLine "Getting Windows images from $installPath"
    Get-WindowsImage -ImagePath $installPath | ForEach-Object {
      $image = Get-WindowsImage -ImagePath $installPath -Index $_.ImageIndex
      [PSCustomObject]@{ index = $image.ImageIndex; name = $image.ImageName; version = $image.Version }
    }
  }
  finally {
    Write-CleanLine "Dismounting $isoPath"
    Dismount-DiskImage $isoPath | Out-Null
  }
}

function Patch-Aria2-Flags {
  param([string]$CmdPath)
  if (-not (Test-Path $CmdPath)) { return }

  Write-CleanLine "Patching aria2 flags in $CmdPath using PowerShell regex (UTF-16LE safe)."

  $bytes   = [System.IO.File]::ReadAllBytes($CmdPath)
  $content = [System.Text.Encoding]::Unicode.GetString($bytes)

  # 1) Remove conflicting flags
  $patternsToRemove = @(
    '\s--console-log-level=\w+\b',
    '\s--summary-interval=\d+\b',
    '\s--download-result=\w+\b',
    '\s--enable-color=\w+\b',
    '\s-(?:q|quiet(?:=\w+)?)\b'
  )
  foreach ($re in $patternsToRemove) {
    $content = [regex]::Replace($content, $re, '', 'IgnoreCase, CultureInvariant')
  }

  # 2) Inject quiet flags right after "%aria2%"
  $inject = '--quiet=true --console-log-level=error --summary-interval=0 --download-result=hide --enable-color=false '
  $content = [regex]::Replace($content, '("%aria2%"\s+)', ('$1' + $inject), 'IgnoreCase, CultureInvariant')

  # 3) Write back as UTF-16LE
  $newBytes = [System.Text.Encoding]::Unicode.GetBytes($content)
  [System.IO.File]::WriteAllBytes($CmdPath, $newBytes)
}

function Get-WindowsIso($name, $destinationDirectory) {
  $iso = Get-UupDumpIso $name $TARGETS.$name
  if (-not $iso) { throw "Can't find UUP for $name ($($TARGETS.$name.search)), lang=$lang." }

  if (!$preview) {
    if ($iso.title -match 'version') {
      $parts = $iso.title -split '(?i)version\s*'
      if ($parts.Count -lt 2) { throw "Unexpected title format, split resulted in less than 2 parts: $($parts -join '|')" }
      $verbuild = $parts[1] -split '[\s\(]' | Select-Object -First 1
    } else {
      Write-CleanLine "WARN: Unexpected title format: missing 'version'. Using build number fallback."
      $verbuild = $iso.build
    }
  } else {
    $verbuild = $ringLower.ToUpper()
  }

  $buildDirectory               = Join-Path $destinationDirectory $name
  $destinationIsoPath           = "$buildDirectory.iso"
  $destinationIsoMetadataPath   = "$destinationIsoPath.json"
  $destinationIsoChecksumPath   = "$destinationIsoPath.sha256.txt"
  
  $destinationIsoPath         = [System.IO.Path]::GetFullPath($destinationIsoPath)
  $destinationIsoMetadataPath = [System.IO.Path]::GetFullPath($destinationIsoMetadataPath)
  $destinationIsoChecksumPath = [System.IO.Path]::GetFullPath($destinationIsoChecksumPath)

  if (Test-Path $buildDirectory) { Remove-Item -Force -Recurse $buildDirectory | Out-Null }
  New-Item -ItemType Directory -Force $buildDirectory | Out-Null
  
  $edn = "Professional"
  Write-CleanLine $edn
  $title = "$name $edn $($iso.build)"
  Write-CleanLine "Downloading the UUP dump download package for $title from $($iso.downloadPackageUrl)"
  $downloadPackageBody = @{ autodl=2; updates=1; cleanup=1 }
  
  for ($i = 0; $i -lt 3; $i++) {
    try { Invoke-WebRequest -Method Post -Uri $iso.downloadPackageUrl -Body $downloadPackageBody -OutFile "$buildDirectory.zip" | Out-Null; break }
    catch { if ($i -eq 2) { throw }; Start-Sleep -Seconds 5 }
  }
  
  Expand-Archive "$buildDirectory.zip" $buildDirectory

  $convertConfigPath = Join-Path $buildDirectory 'ConvertConfig.ini'
  $convertConfig = (Get-Content $convertConfigPath) `
    -replace '^(AutoExit\s*)=.*','$1=1' `
    -replace '^(ResetBase\s*)=.*','$1=1' `
    -replace '^(LCUwinre\s*)=.*','$1=1' `
    -replace '^(UpdtBootFiles\s*)=.*','$1=1' `
    -replace '^(StubAppsFull\s*)=.*','$1=1' `
    -replace '^(Cleanup\s*)=.*','$1=1'

  $tag = ""
  if ($esd) { $convertConfig = $convertConfig -replace '^(wim2esd\s*)=.*', '$1=1'; $tag += ".E" }

  if ($netfx3) { $convertConfig = $convertConfig -replace '^(NetFx3\s*)=.*', '$1=1'; $tag += ".N" }

  Set-Content -Encoding ascii -Path $convertConfigPath -Value $convertConfig

  Write-CleanLine "Creating the $title iso file inside the $buildDirectory directory"
  
  $reDismStage = '^\s*(Mounting image|Saving image|Applying image|Exporting image|Unmounting image|Deployment Image Servicing and Management tool|===)'
  Push-Location $buildDirectory
  try {
    Patch-Aria2-Flags -CmdPath (Join-Path $buildDirectory 'uup_download_windows.cmd')
    $rawLogDir = $env:RUNNER_TEMP ?? $env:TEMP ?? [System.IO.Path]::GetTempPath()
    $rawLog = Join-Path $rawLogDir 'uup_dism_aria2_raw.log'
    
    if (Get-Command choco -ErrorAction SilentlyContinue) {
      choco install aria2 /y *> $null
      if ($LASTEXITCODE -ne 0) { Write-CleanLine "WARN: choco install aria2 失败（exit $LASTEXITCODE），确认 aria2c 在 PATH" }
    }
    
    & {
       powershell cmd /c uup_download_windows.cmd 2>&1 |
        Tee-Object -FilePath $rawLog |
        ForEach-Object {
          $raw = [string]$_
          if ([string]::IsNullOrEmpty($raw)) { return }
          foreach ($crChunk in ($raw -split "`r")) {
            foreach ($line in ($crChunk -split "`n")) {
              if ($line -eq $null) { continue }
              # DISM progress buckets; aria2 is not parsed here
              if (-not (Process-ProgressLine $line)) {
                if ($line -match $reDismStage) {
                 Reset-ProgressSession
               }
               Write-CleanLine $line
             }
           }
         }
       }
   }
   
   if ($LASTEXITCODE) {
     Write-Host "::warning title=Build failed::Dumping last 1500 raw log lines"
     Get-Content $rawLog -Tail 1500 -ErrorAction SilentlyContinue | Write-Host
     throw "uup_download_windows.cmd failed with exit code $LASTEXITCODE"
    }

  } 
  finally {
    Pop-Location -ErrorAction SilentlyContinue
  }

  $isoFiles = @(Get-ChildItem -LiteralPath $buildDirectory -File | Where-Object { $_.Extension -eq '.iso' })
  if ($isoFiles.Count -ne 1) { throw "Expected exactly 1 ISO in $buildDirectory, found $($isoFiles.Count)" }
  $sourceIsoPath = $isoFiles[0].FullName
  $IsoName = $isoFiles[0].Name

  if ($autounattend -and (Test-Path -LiteralPath $autounattend)) {
    Write-CleanLine "Cleaning build directory (keeping only .iso files)..."
    Get-ChildItem -LiteralPath $buildDirectory -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.PSIsContainer -or $_.Extension -ne '.iso' } |
      ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
      }
    Write-CleanLine "Injecting Autounattend.xml into $sourceIsoPath"

    $oscdimg = Join-Path $PSScriptRoot 'oscdimg\oscdimg.exe'
    if (-not (Test-Path -LiteralPath $oscdimg)) { throw "oscdimg.exe not found: $oscdimg" }

    $isoTempDir = Join-Path $buildDirectory 'ISOFIX'
    if (Test-Path $isoTempDir) { Remove-Item -Force -Recurse $isoTempDir }
    New-Item -ItemType Directory -Force $isoTempDir | Out-Null

    $mounted = Mount-DiskImage $sourceIsoPath -PassThru
    try {
      $dl = $null
      for ($i = 0; $i -lt 20 -and -not $dl; $i++) {
        if ($i -gt 0) { Start-Sleep -Milliseconds 500 }
        $dl = (Get-Volume -DiskImage $mounted -ErrorAction SilentlyContinue).DriveLetter
      }
      if (-not $dl) { throw "Failed to mount ISO: $sourceIsoPath" }
      
      $label = (Get-Volume -DriveLetter $dl).FileSystemLabel
      if (-not $label) { $label = [System.IO.Path]::GetFileNameWithoutExtension($IsoName) }
      if ($label.Length -gt 32) { $label = $label.Substring(0, 32) }
      Write-CleanLine "ISO label from source: $label"
      
      robocopy "$($dl):\" $isoTempDir /E /COPY:DAT /DCOPY:T /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
      if ($LASTEXITCODE -ge 8) { throw "robocopy failed: $LASTEXITCODE" }
    } finally {
      if ($mounted) { Dismount-DiskImage $sourceIsoPath -ErrorAction SilentlyContinue | Out-Null }
    }

    Copy-Item -LiteralPath $autounattend -Destination (Join-Path $isoTempDir 'Autounattend.xml') -Force
    
    $tmpIso = Join-Path $buildDirectory 'rebuilt.iso'
    if (Test-Path $tmpIso) { Remove-Item -Force $tmpIso }

    $stamp = (Get-Item $sourceIsoPath).LastWriteTime.ToString(
      'MM/dd/yyyy,HH:mm:ss',
      [System.Globalization.CultureInfo]::InvariantCulture
    )

    $etfsboot = Join-Path $isoTempDir 'boot\etfsboot.com'
    $efisys   = Join-Path $isoTempDir 'efi\Microsoft\boot\efisys.bin'
    if (-not (Test-Path -LiteralPath $etfsboot)) { throw "BIOS boot file not found: $etfsboot" }
    if (-not (Test-Path -LiteralPath $efisys))   { throw "UEFI boot file not found: $efisys" }

    $bootdata = "2#p0,e,b`"$etfsboot`"#pEF,e,b`"$efisys`""
    $oscdimgArgs = (@(
      '-m', '-o', '-u2', '-udfver102',
      "-t`"$stamp`"",
      "-l`"$label`"",
      "-bootdata:$bootdata",
      "`"$isoTempDir`"",
      "`"$tmpIso`""
    ) -join ' ')

    Write-CleanLine "oscdimg $oscdimgArgs"

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $oscdimg
    $psi.Arguments              = $oscdimgArgs
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    $proc = [System.Diagnostics.Process]::Start($psi)

    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result

    if ($stdout) { Write-CleanLine $stdout.TrimEnd() }
    if ($stderr) { Write-CleanLine $stderr.TrimEnd() }
    if ($proc.ExitCode -ne 0) { throw "oscdimg failed: exit code $($proc.ExitCode)" }

    if (-not (Test-Path -LiteralPath $tmpIso)) {
      throw "oscdimg reported success but output not found: $tmpIso"
    }
   
    $backupIso = "$sourceIsoPath.bak"
    if (Test-Path -LiteralPath $backupIso) { Remove-Item -Force $backupIso }
    Move-Item -Force $sourceIsoPath $backupIso
    try { Move-Item -Force $tmpIso $sourceIsoPath }
    catch {
      if (-not (Test-Path -LiteralPath $sourceIsoPath)) {
        Move-Item -Force $backupIso $sourceIsoPath -ErrorAction SilentlyContinue
      }
      throw
    }
    Remove-Item -Force $backupIso -ErrorAction SilentlyContinue

    Remove-Item -Force -Recurse $isoTempDir -ErrorAction SilentlyContinue
    Write-CleanLine "Autounattend.xml injected into ISO root."
  }

  Write-CleanLine "Getting the $sourceIsoPath checksum"
  $isoChecksum = (Get-FileHash -Algorithm SHA256 $sourceIsoPath).Hash.ToLowerInvariant()
  Set-Content -Encoding ascii -NoNewline -Path $destinationIsoChecksumPath -Value $isoChecksum

  $windowsImages = Get-IsoWindowsImages $sourceIsoPath
  Set-Content -Path $destinationIsoMetadataPath -Value (
    ([PSCustomObject]@{
      name    = $name
      title   = $iso.title
      build   = $iso.build
      version = $verbuild
      tags    = $tag
      checksum = $isoChecksum
      images  = @($windowsImages)
      uupDump = @{
        id                 = $iso.id
        apiUrl             = $iso.apiUrl
        downloadUrl        = $iso.downloadUrl
        downloadPackageUrl = $iso.downloadPackageUrl
      }
    } | ConvertTo-Json -Depth 99) -replace '\\u0026','&'
  ) -Encoding utf8

  $finalIsoPath = Join-Path $destinationDirectory $IsoName
  Write-CleanLine "Moving the created $sourceIsoPath to $finalIsoPath"
  Move-Item -Force $sourceIsoPath $finalIsoPath
  
  Write-CleanLine "ISO_METADATA (normalized) = $destinationIsoMetadataPath"
  if ($env:GITHUB_ENV) {
    Write-Output "ISO_NAME=$IsoName" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    Write-Output "ISO_METADATA=$destinationIsoMetadataPath" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    Write-Output "ISO_BUILD=$($iso.build)" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    Write-Output "ISO_CHECKSUM=$isoChecksum" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    
  }

  if (Test-Path -LiteralPath $buildDirectory) {
    Write-CleanLine "Removing build directory: $buildDirectory"
    Remove-Item -Force -Recurse $buildDirectory -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath "$buildDirectory.zip" -ErrorAction SilentlyContinue
  Write-CleanLine 'All Done.'
}

Get-WindowsIso $windowsTargetName $destinationDirectory