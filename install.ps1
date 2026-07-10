#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the native Windows x64 atp release binary.

.DESCRIPTION
    Downloads the exact x86_64-pc-windows-msvc release ZIP, verifies it against
    the release SHA256SUMS manifest, validates the archive and executable, and
    replaces the installed binary without destroying a working prior install.

.EXAMPLE
    irm https://raw.githubusercontent.com/Dicklesworthstone/atp/main/install.ps1 | iex

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Dicklesworthstone/atp/main/install.ps1))) -Version v0.3.8 -Verify
#>

[CmdletBinding()]
param(
    [string]$Version = "",
    [string]$Dest = "",
    [string]$Offline = "",
    [string]$Checksum = "",
    [switch]$EasyMode,
    [switch]$Verify,
    [switch]$Force,
    [switch]$Quiet,
    [switch]$Help,
    [switch]$LoadFunctionsOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:AtpQuiet = [bool]$Quiet
$script:AtpOwner = "Dicklesworthstone"
$script:AtpRepo = "atp"
$script:AtpAsset = "atp-x86_64-pc-windows-msvc.zip"
$script:AtpBinary = "atp.exe"
$script:AtpMaxArchiveEntryBytes = 134217728L
$script:AtpMaxArchiveTotalBytes = 135266304L

function Write-AtpInfo {
    param([string]$Message)
    if (-not $script:AtpQuiet) { Write-Host "[*] $Message" -ForegroundColor Cyan }
}

function Write-AtpOk {
    param([string]$Message)
    if (-not $script:AtpQuiet) { Write-Host "[+] $Message" -ForegroundColor Green }
}

function Write-AtpWarn {
    param([string]$Message)
    if (-not $script:AtpQuiet) { Write-Host "[!] $Message" -ForegroundColor Yellow }
}

function Write-AtpFailure {
    param([string]$Message)
    [Console]::Error.WriteLine("[-] $Message")
}

function Show-AtpUsage {
    @'
atp installer for native Windows x64

Usage:
  install.ps1 [-Version vX.Y.Z] [-Dest DIR] [-EasyMode] [-Verify] [-Force]
  install.ps1 -Offline ZIP [-Checksum SHA256] [-Version vX.Y.Z] [-Dest DIR]

Options:
  -Version TAG     Install a stable release tag (default: latest release)
  -Dest DIR        Install directory (default: %USERPROFILE%\.local\bin)
  -Offline ZIP     Install the exact Windows release ZIP without network access
  -Checksum HEX    Expected archive SHA-256 (required unless a sibling checksum exists)
  -EasyMode        Add the destination to the persistent User PATH
  -Verify          Run an additional post-install version and rq-keygen self-test
  -Force           Reinstall even when the requested version is already present
  -Quiet           Suppress non-error output
  -Help            Show this help

Only native Windows x64 is currently published. Windows ARM64 and 32-bit
Windows fail closed instead of installing an emulated or mismatched binary.
'@ | Write-Host
}

function Test-AtpWindows {
    return ($env:OS -eq "Windows_NT" -or $PSVersionTable.PSEdition -eq "Desktop" -or
        $PSVersionTable.Platform -eq "Win32NT")
}

function Get-AtpWindowsTarget {
    $arch = if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }

    if ($arch -match '^(?i:AMD64|x86_64)$') { return "x86_64-pc-windows-msvc" }
    if ([string]::IsNullOrWhiteSpace($arch)) { $arch = "unknown" }
    throw "Unsupported Windows architecture '$arch'; only native Windows x64 is published"
}

function Normalize-AtpVersionTag {
    param([Parameter(Mandatory = $true)][string]$RawVersion)

    $candidate = $RawVersion.Trim()
    if ($candidate -match '^v?([0-9]+\.[0-9]+\.[0-9]+)$') {
        return "v$($Matches[1])"
    }
    throw "Invalid release version '$RawVersion'; expected vX.Y.Z"
}

function Get-AtpLatestVersionTag {
    $uri = "https://api.github.com/repos/$($script:AtpOwner)/$($script:AtpRepo)/releases/latest"
    Write-AtpInfo "Resolving the latest stable release"
    $response = Invoke-RestMethod -Uri $uri -Headers @{
        Accept = "application/vnd.github+json"
        "User-Agent" = "atp-install.ps1"
    }
    if ($null -eq $response -or [string]::IsNullOrWhiteSpace([string]$response.tag_name)) {
        throw "GitHub's latest-release response did not contain tag_name"
    }
    return Normalize-AtpVersionTag ([string]$response.tag_name)
}

function Get-AtpArtifactUrl {
    param([Parameter(Mandatory = $true)][string]$VersionTag)

    $tag = Normalize-AtpVersionTag $VersionTag
    return "https://github.com/$($script:AtpOwner)/$($script:AtpRepo)/releases/download/$tag/$($script:AtpAsset)"
}

function Test-AtpSha256Token {
    param([string]$Token)
    return (-not [string]::IsNullOrWhiteSpace($Token) -and $Token -match '^[0-9A-Fa-f]{64}$')
}

function Resolve-AtpManifestHash {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$AssetName
    )

    $matchingHashes = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Content -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^([0-9A-Fa-f]{64})[ \t]+\*?([^\r\n]+?)[ \t]*$') {
            $name = $Matches[2]
            if ([string]::Equals($name, $AssetName, [StringComparison]::Ordinal)) {
                $matchingHashes.Add($Matches[1].ToLowerInvariant())
            }
        }
    }

    if ($matchingHashes.Count -ne 1) {
        throw "Expected exactly one SHA256SUMS row for '$AssetName'; found $($matchingHashes.Count)"
    }
    return $matchingHashes[0]
}

function Resolve-AtpChecksumText {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$AssetName,
        [switch]$AllowBareHash
    )

    $trimmed = $Content.Trim()
    if ($AllowBareHash -and (Test-AtpSha256Token $trimmed)) {
        return $trimmed.ToLowerInvariant()
    }
    return Resolve-AtpManifestHash -Content $Content -AssetName $AssetName
}

function Invoke-AtpDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    Write-AtpInfo "Downloading $Uri"
    $oldProgress = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -Headers @{
            "User-Agent" = "atp-install.ps1"
        } | Out-Null
    } finally {
        $ProgressPreference = $oldProgress
    }
}

function Get-AtpRemoteText {
    param([Parameter(Mandatory = $true)][string]$Uri)

    $oldProgress = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    try {
        return [string](Invoke-WebRequest -Uri $Uri -UseBasicParsing -Headers @{
            "User-Agent" = "atp-install.ps1"
        }).Content
    } finally {
        $ProgressPreference = $oldProgress
    }
}

function Assert-AtpFileHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    if (-not (Test-AtpSha256Token $Expected)) {
        throw "Expected checksum must be exactly 64 hexadecimal characters"
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $wanted = $Expected.ToLowerInvariant()
    if ($actual -cne $wanted) {
        throw "Checksum verification failed for '$Path' (expected $wanted, got $actual)"
    }
    Write-AtpOk "Checksum verified: $($actual.Substring(0, 16))..."
}

function Assert-AtpPeX64 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) {
            throw "'$Path' is not a PE executable"
        }
        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 64 -or ([int64]$peOffset + 6L) -gt $stream.Length) {
            throw "'$Path' has an invalid PE header offset"
        }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "'$Path' has an invalid PE signature"
        }
        $machine = $reader.ReadUInt16()
        if ($machine -ne 0x8664) {
            throw ("'$Path' is not an x64 PE executable (machine 0x{0:X4})" -f $machine)
        }
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Test-AtpExecutable {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ExpectedVersionTag = ""
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "atp executable is not a regular file: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "atp executable must not be a reparse point: $Path"
    }
    Assert-AtpPeX64 $Path

    $versionOutput = @(& $Path --version 2>&1)
    $versionExit = $LASTEXITCODE
    $versionLine = (($versionOutput | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ($versionExit -ne 0 -or $versionLine -notmatch '^atp ([0-9]+\.[0-9]+\.[0-9]+)$') {
        throw "atp --version failed or returned an invalid value: '$versionLine' (exit $versionExit)"
    }
    $binaryVersion = $Matches[1]
    if (-not [string]::IsNullOrWhiteSpace($ExpectedVersionTag)) {
        $expected = (Normalize-AtpVersionTag $ExpectedVersionTag).Substring(1)
        if ($binaryVersion -cne $expected) {
            throw "Downloaded binary version mismatch: expected atp $expected, got atp $binaryVersion"
        }
    }

    $keyOutput = @(& $Path rq-keygen 2>&1)
    $keyExit = $LASTEXITCODE
    $key = (($keyOutput | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ($keyExit -ne 0 -or $key -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "atp rq-keygen self-test failed (exit $keyExit)"
    }

    return [PSCustomObject]@{
        Version = $binaryVersion
        VersionLine = $versionLine
    }
}

function Copy-AtpZipEntry {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][int64]$MaximumBytes
    )

    $inputStream = $Entry.Open()
    $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $buffer = New-Object byte[] 65536
    $written = 0L
    try {
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $written += $read
            if ($written -gt $MaximumBytes) {
                throw "ZIP member '$($Entry.FullName)' exceeds the extraction limit"
            }
            $outputStream.Write($buffer, 0, $read)
        }
    } finally {
        $outputStream.Dispose()
        $inputStream.Dispose()
    }
    if ($written -ne $Entry.Length) {
        throw "ZIP member '$($Entry.FullName)' length changed during extraction"
    }
}

function Expand-AtpArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination,
        [int64]$MaximumEntryBytes = $script:AtpMaxArchiveEntryBytes,
        [int64]$MaximumTotalBytes = $script:AtpMaxArchiveTotalBytes
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Destination) {
        throw "Archive extraction destination already exists: $Destination"
    }
    New-Item -ItemType Directory -Path $Destination | Out-Null

    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $entries = @($zip.Entries)
        if ($entries.Count -ne 2) {
            throw "Windows release ZIP must contain exactly atp.exe and LICENSE; found $($entries.Count) members"
        }

        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $total = 0L
        foreach ($entry in $entries) {
            $name = [string]$entry.FullName
            if ($name -cne "atp.exe" -and $name -cne "LICENSE") {
                throw "Unexpected ZIP member '$name'; only root atp.exe and LICENSE are allowed"
            }
            if (-not $seen.Add($name)) {
                throw "Duplicate ZIP member '$name'"
            }
            if ($name.Contains('/') -or $name.Contains('\') -or $name.Contains('..')) {
                throw "Unsafe ZIP member path '$name'"
            }
            if (($entry.ExternalAttributes -band 0x10) -ne 0) {
                throw "ZIP member '$name' must not be a directory"
            }
            $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixType -ne 0 -and $unixType -ne 0x8000) {
                throw "ZIP member '$name' must be a regular file"
            }
            if ($entry.Length -le 0 -or $entry.Length -gt $MaximumEntryBytes) {
                throw "ZIP member '$name' has an invalid expanded size $($entry.Length)"
            }
            if ($entry.CompressedLength -eq 0 -and $entry.Length -gt 0) {
                throw "ZIP member '$name' has an invalid compressed size"
            }
            $total += $entry.Length
            if ($total -gt $MaximumTotalBytes) {
                throw "Windows release ZIP exceeds the expanded-size limit"
            }
        }
        if (-not $seen.Contains("atp.exe") -or -not $seen.Contains("LICENSE")) {
            throw "Windows release ZIP is missing atp.exe or LICENSE"
        }

        foreach ($entry in $entries) {
            Copy-AtpZipEntry -Entry $entry -Destination (Join-Path $Destination $entry.FullName) -MaximumBytes $MaximumEntryBytes
        }
    } finally {
        $zip.Dispose()
    }

    return (Join-Path $Destination "atp.exe")
}

function Test-AtpPathContains {
    param(
        [string]$PathValue,
        [Parameter(Mandatory = $true)][string]$Candidate
    )

    $candidateFull = [IO.Path]::GetFullPath($Candidate).TrimEnd([char]'\', [char]'/')
    foreach ($entry in ([string]$PathValue -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        try {
            $expanded = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"'))
            $entryFull = [IO.Path]::GetFullPath($expanded).TrimEnd([char]'\', [char]'/')
            if ([string]::Equals($entryFull, $candidateFull, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        } catch {
            # Preserve malformed pre-existing PATH entries, but do not match them.
        }
    }
    return $false
}

function Add-AtpToUserPath {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $full = [IO.Path]::GetFullPath($Directory).TrimEnd([char]'\', [char]'/')
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    if (Test-AtpPathContains -PathValue $current -Candidate $full) {
        Write-AtpInfo "$full is already present in the User PATH"
        return
    }
    $next = if ([string]::IsNullOrWhiteSpace($current)) { $full } else { "$current;$full" }
    if ($next.Length -gt 32767) { throw "User PATH would exceed the Windows environment-variable limit" }
    [Environment]::SetEnvironmentVariable("Path", $next, "User")
    if (-not (Test-AtpPathContains -PathValue $env:Path -Candidate $full)) {
        $env:Path = "$($env:Path);$full"
    }
    Write-AtpOk "Added $full to the User PATH; open a new terminal to use it"
}

function Open-AtpInstallLock {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $lockPath = Join-Path $Directory ".atp-install.lock"
    if (Test-Path -LiteralPath $lockPath) {
        $lockItem = Get-Item -LiteralPath $lockPath -Force
        if (($lockItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $lockItem.PSIsContainer) {
            throw "Installer lock path is not a regular file: $lockPath"
        }
    }
    try {
        return [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        throw "Another atp installer is running for '$Directory', or its lock cannot be opened"
    }
}

function Assert-AtpNoReparsePathPrefix {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "Install destination has no filesystem root: $full"
    }

    $current = $root
    $relative = $full.Substring($root.Length)
    foreach ($component in ($relative -split '[\\/]' | Where-Object { $_.Length -gt 0 })) {
        $current = Join-Path $current $component
        if (-not (Test-Path -LiteralPath $current)) { continue }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Install destination crosses a reparse point: $current"
        }
    }
}

function Assert-AtpInstallTarget {
    param([Parameter(Mandatory = $true)][string]$Target)

    if (Test-Path -LiteralPath $Target) {
        $item = Get-Item -LiteralPath $Target -Force
        if ($item.PSIsContainer) { throw "Install target is a directory: $Target" }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Install target must not be a reparse point: $Target"
        }
    }
}

function Install-AtpAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Target,
        [string]$ExpectedVersionTag = ""
    )

    Assert-AtpInstallTarget $Target
    $directory = Split-Path -Parent $Target
    $stage = Join-Path $directory (".atp-install-{0}.exe" -f [Guid]::NewGuid().ToString("N"))
    $backup = Join-Path $directory (".atp-backup-{0}.exe" -f [Guid]::NewGuid().ToString("N"))
    $hadExisting = Test-Path -LiteralPath $Target -PathType Leaf
    $installed = $false

    try {
        [IO.File]::Copy($Source, $stage, $false)
        try { Unblock-File -LiteralPath $stage -ErrorAction SilentlyContinue } catch { }
        $null = Test-AtpExecutable -Path $stage -ExpectedVersionTag $ExpectedVersionTag

        Assert-AtpInstallTarget $Target
        if ($hadExisting) {
            [IO.File]::Replace($stage, $Target, $backup, $true)
        } else {
            [IO.File]::Move($stage, $Target)
        }
        $installed = $true
        $null = Test-AtpExecutable -Path $Target -ExpectedVersionTag $ExpectedVersionTag
        if (Test-Path -LiteralPath $backup -PathType Leaf) {
            [IO.File]::Delete($backup)
        }
    } catch {
        $originalError = $_
        if ($installed -and $hadExisting -and (Test-Path -LiteralPath $backup -PathType Leaf)) {
            try {
                if (Test-Path -LiteralPath $Target -PathType Leaf) {
                    $failed = Join-Path $directory (".atp-failed-{0}.exe" -f [Guid]::NewGuid().ToString("N"))
                    [IO.File]::Replace($backup, $Target, $failed, $true)
                    if (Test-Path -LiteralPath $failed -PathType Leaf) { [IO.File]::Delete($failed) }
                } else {
                    [IO.File]::Move($backup, $Target)
                }
            } catch {
                throw "Install failed and rollback also failed; backup remains at '$backup'. Original error: $($originalError.Exception.Message)"
            }
        } elseif ($installed -and -not $hadExisting -and (Test-Path -LiteralPath $Target -PathType Leaf)) {
            [IO.File]::Delete($Target)
        }
        throw $originalError
    } finally {
        if (Test-Path -LiteralPath $stage -PathType Leaf) { [IO.File]::Delete($stage) }
        if ((Test-Path -LiteralPath $backup -PathType Leaf) -and -not $installed) { [IO.File]::Delete($backup) }
    }
}

function Get-AtpOfflineChecksum {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [string]$ExplicitChecksum = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitChecksum)) {
        if (-not (Test-AtpSha256Token $ExplicitChecksum)) {
            throw "-Checksum must be exactly 64 hexadecimal characters"
        }
        return $ExplicitChecksum.ToLowerInvariant()
    }

    $sidecar = "$Archive.sha256"
    if (Test-Path -LiteralPath $sidecar -PathType Leaf) {
        return Resolve-AtpChecksumText -Content (Get-Content -LiteralPath $sidecar -Raw) -AssetName $script:AtpAsset -AllowBareHash
    }
    $manifest = Join-Path (Split-Path -Parent $Archive) "SHA256SUMS"
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        return Resolve-AtpManifestHash -Content (Get-Content -LiteralPath $manifest -Raw) -AssetName $script:AtpAsset
    }
    throw "Offline install requires -Checksum, '$sidecar', or a sibling SHA256SUMS"
}

function Invoke-AtpInstaller {
    if (-not (Test-AtpWindows)) { throw "install.ps1 is for native Windows; use install.sh on Linux, macOS, or WSL" }
    $targetTriple = Get-AtpWindowsTarget
    if ($targetTriple -cne "x86_64-pc-windows-msvc") { throw "Unsupported release target: $targetTriple" }

    $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($profile)) { $profile = $HOME }
    $destinationInput = if ([string]::IsNullOrWhiteSpace($Dest)) {
        Join-Path $profile ".local\bin"
    } else {
        $Dest
    }
    $destination = [IO.Path]::GetFullPath($destinationInput)
    Assert-AtpNoReparsePathPrefix $destination
    if (Test-Path -LiteralPath $destination) {
        $destinationItem = Get-Item -LiteralPath $destination -Force
        if (-not $destinationItem.PSIsContainer) {
            throw "Install destination is a file: $destination"
        }
        if (($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Install destination must not be a reparse point: $destination"
        }
    } else {
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
    }
    Assert-AtpNoReparsePathPrefix $destination
    $targetPath = Join-Path $destination $script:AtpBinary
    Assert-AtpInstallTarget $targetPath

    $offlineMode = -not [string]::IsNullOrWhiteSpace($Offline)
    if ($offlineMode -and [string]::Equals($Version, "latest", [StringComparison]::OrdinalIgnoreCase)) {
        throw "-Version latest is not valid with -Offline; provide a concrete tag or omit -Version"
    }
    $versionTag = ""
    if (-not [string]::IsNullOrWhiteSpace($Version) -and -not [string]::Equals($Version, "latest", [StringComparison]::OrdinalIgnoreCase)) {
        $versionTag = Normalize-AtpVersionTag $Version
    } elseif (-not $offlineMode) {
        $versionTag = Get-AtpLatestVersionTag
    }

    $lock = Open-AtpInstallLock $destination
    $lockPath = Join-Path $destination ".atp-install.lock"
    $tempRoot = ""
    try {
        if (-not $Force -and -not [string]::IsNullOrWhiteSpace($versionTag) -and (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            try {
                $existing = Test-AtpExecutable -Path $targetPath -ExpectedVersionTag $versionTag
                Write-AtpOk "$($existing.VersionLine) is already installed at $targetPath"
                if ($EasyMode) { Add-AtpToUserPath $destination }
                if ($Verify) {
                    $null = Test-AtpExecutable -Path $targetPath -ExpectedVersionTag $versionTag
                    Write-AtpOk "Post-install self-test passed"
                }
                return
            } catch {
                Write-AtpWarn "Existing atp is not the requested healthy version; reinstalling"
            }
        }

        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("atp-install-{0}" -f [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tempRoot | Out-Null
        $archivePath = Join-Path $tempRoot $script:AtpAsset
        $expectedHash = ""

        if ($offlineMode) {
            $offlinePath = [IO.Path]::GetFullPath($Offline)
            if (-not (Test-Path -LiteralPath $offlinePath -PathType Leaf)) {
                throw "Offline archive not found: $offlinePath"
            }
            if (-not [string]::Equals([IO.Path]::GetFileName($offlinePath), $script:AtpAsset, [StringComparison]::Ordinal)) {
                throw "Offline archive must be named '$($script:AtpAsset)'"
            }
            $expectedHash = Get-AtpOfflineChecksum -Archive $offlinePath -ExplicitChecksum $Checksum
            [IO.File]::Copy($offlinePath, $archivePath, $false)
            Write-AtpInfo "Installing from offline archive $offlinePath"
        } else {
            if (-not [string]::IsNullOrWhiteSpace($Checksum)) {
                throw "-Checksum is only accepted with -Offline"
            }
            $artifactUrl = Get-AtpArtifactUrl $versionTag
            Invoke-AtpDownload -Uri $artifactUrl -OutFile $archivePath
            $manifestUrl = "https://github.com/$($script:AtpOwner)/$($script:AtpRepo)/releases/download/$versionTag/SHA256SUMS"
            $manifestText = Get-AtpRemoteText -Uri $manifestUrl
            $expectedHash = Resolve-AtpManifestHash -Content $manifestText -AssetName $script:AtpAsset
        }

        Assert-AtpFileHash -Path $archivePath -Expected $expectedHash
        $extractPath = Join-Path $tempRoot "extract"
        $binaryPath = Expand-AtpArchive -Archive $archivePath -Destination $extractPath
        $validated = Test-AtpExecutable -Path $binaryPath -ExpectedVersionTag $versionTag
        Install-AtpAtomically -Source $binaryPath -Target $targetPath -ExpectedVersionTag $versionTag
        Write-AtpOk "Installed $($validated.VersionLine) to $targetPath"

        if ($EasyMode) { Add-AtpToUserPath $destination }
        elseif (-not (Test-AtpPathContains -PathValue $env:Path -Candidate $destination)) {
            Write-AtpWarn "Add '$destination' to PATH, or rerun with -EasyMode"
        }
        if ($Verify) {
            $null = Test-AtpExecutable -Path $targetPath -ExpectedVersionTag $versionTag
            Write-AtpOk "Post-install self-test passed"
        }
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($tempRoot) -and (Test-Path -LiteralPath $tempRoot)) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $lock) { $lock.Dispose() }
        if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($LoadFunctionsOnly) { return }
if ($Help) { Show-AtpUsage; return }

try {
    # GitHub requires TLS 1.2. Windows PowerShell 5.1 may otherwise negotiate an
    # obsolete protocol; this is harmless on PowerShell 7.
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    Invoke-AtpInstaller
} catch {
    Write-AtpFailure $_.Exception.Message
    exit 1
}
