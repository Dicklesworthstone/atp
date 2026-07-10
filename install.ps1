#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the native Windows x64 atp release binary.

.DESCRIPTION
    Downloads the exact x86_64-pc-windows-msvc release ZIP, verifies it against
    the release SHA256SUMS manifest, requires publisher authentication with
    minisign, validates the archive and executable, and replaces the installed
    binary without destroying a working prior install.

.EXAMPLE
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Dicklesworthstone/atp/main/install.ps1)))

.EXAMPLE
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Dicklesworthstone/atp/main/install.ps1))) -Version v0.3.8 -Verify
#>

[CmdletBinding()]
param(
    [string]$Version = "",
    [string]$Dest = "",
    [string]$Offline = "",
    [string]$Checksum = "",
    [switch]$EasyMode,
    [switch]$Verify,
    [switch]$NoVerify,
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
$script:AtpMinisignPublicKey = "RWTQGPeLsnm9G7VFdFWkkcRi3wJK/PqsYxWC+oLNN74W9IjBxRU1Xu70"
$script:AtpFirstSignedRelease = [Version]"0.3.8"
$script:AtpWebTimeoutSeconds = 30
$script:AtpExecutableTimeoutMilliseconds = 10000
$script:AtpMinisignTimeoutMilliseconds = 10000
$script:AtpPipeDrainTimeoutMilliseconds = 2000

function Initialize-AtpLongPathSupport {
    # Windows PowerShell 5.1 runs on .NET Framework, where these switches opt
    # System.IO into the modern path implementation. Extended paths below keep
    # filesystem calls deterministic even when the host lacks a longPathAware
    # application manifest.
    try { [AppContext]::SetSwitch("Switch.System.IO.UseLegacyPathHandling", $false) } catch { }
    try { [AppContext]::SetSwitch("Switch.System.IO.BlockLongPaths", $false) } catch { }
}

function Enable-AtpTls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
}

function Get-AtpFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path.StartsWith('\\?\', [StringComparison]::Ordinal)) { return $Path }
    return [IO.Path]::GetFullPath($Path)
}

function ConvertTo-AtpExtendedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = Get-AtpFullPath $Path
    if (-not (Test-AtpWindows) -or $full.StartsWith('\\?\', [StringComparison]::Ordinal)) {
        return $full
    }
    if ($full.StartsWith('\\', [StringComparison]::Ordinal)) {
        return "\\?\UNC\$($full.Substring(2))"
    }
    return "\\?\$full"
}

function Join-AtpPath {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Child
    )
    return [IO.Path]::Combine($Parent, $Child)
}

function Test-AtpFileExists {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.File]::Exists((ConvertTo-AtpExtendedPath $Path))
}

function Test-AtpDirectoryExists {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Directory]::Exists((ConvertTo-AtpExtendedPath $Path))
}

function Test-AtpPathEntryExists {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ((Test-AtpFileExists $Path) -or (Test-AtpDirectoryExists $Path)) { return $true }
    $full = Get-AtpFullPath $Path
    $parent = [IO.Path]::GetDirectoryName($full)
    $leaf = [IO.Path]::GetFileName($full)
    if ([string]::IsNullOrWhiteSpace($parent) -or [string]::IsNullOrWhiteSpace($leaf) -or
        -not (Test-AtpDirectoryExists $parent)) {
        return $false
    }

    foreach ($entry in [IO.Directory]::GetFileSystemEntries((ConvertTo-AtpExtendedPath $parent))) {
        if ([string]::Equals([IO.Path]::GetFileName($entry), $leaf, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-AtpFileAttributes {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.File]::GetAttributes((ConvertTo-AtpExtendedPath $Path))
}

function Set-AtpFileAttributes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][IO.FileAttributes]$Attributes
    )
    [IO.File]::SetAttributes((ConvertTo-AtpExtendedPath $Path), $Attributes)
}

function Clear-AtpReadOnly {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-AtpFileExists $Path) -and -not (Test-AtpDirectoryExists $Path)) { return }
    $attributes = Get-AtpFileAttributes $Path
    if (($attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
        Set-AtpFileAttributes -Path $Path -Attributes ($attributes -band (-bnot [IO.FileAttributes]::ReadOnly))
    }
}

function Remove-AtpUnresolvedPathEntryStrict {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-AtpPathEntryExists $Path)) { return }
    $native = ConvertTo-AtpExtendedPath $Path
    $fileDeleteError = ""
    try {
        [IO.File]::Delete($native)
    } catch {
        $fileDeleteError = $_.Exception.Message
    }
    if (-not (Test-AtpPathEntryExists $Path)) { return }

    $directoryDeleteError = ""
    try {
        [IO.Directory]::Delete($native, $false)
    } catch {
        $directoryDeleteError = $_.Exception.Message
    }
    if (Test-AtpPathEntryExists $Path) {
        throw "Failed to remove unresolved installer path entry '$Path' without following it (file delete: $fileDeleteError; directory delete: $directoryDeleteError)"
    }
}

function Remove-AtpFileStrict {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-AtpFileExists $Path)) {
        if (Test-AtpPathEntryExists $Path) { Remove-AtpUnresolvedPathEntryStrict $Path }
        return
    }
    Clear-AtpReadOnly $Path
    [IO.File]::Delete((ConvertTo-AtpExtendedPath $Path))
    if (Test-AtpPathEntryExists $Path) { throw "Failed to remove installer file: $Path" }
}

function Remove-AtpDirectoryTreeStrict {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-AtpDirectoryExists $Path)) {
        if (Test-AtpPathEntryExists $Path) { Remove-AtpUnresolvedPathEntryStrict $Path }
        return
    }
    $native = ConvertTo-AtpExtendedPath $Path
    $rootAttributes = [IO.File]::GetAttributes($native)
    if (($rootAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        try {
            $null = [IO.Directory]::GetFileSystemEntries($native)
        } catch [IO.DirectoryNotFoundException] {
            Remove-AtpUnresolvedPathEntryStrict $Path
            return
        }
        throw "Refusing to recursively remove a reparse-point directory: $Path"
    }
    foreach ($entry in [IO.Directory]::GetFileSystemEntries($native)) {
        if (-not (Test-AtpFileExists $entry) -and -not (Test-AtpDirectoryExists $entry)) {
            Remove-AtpUnresolvedPathEntryStrict $entry
            continue
        }
        $attributes = [IO.File]::GetAttributes($entry)
        $isDirectory = ($attributes -band [IO.FileAttributes]::Directory) -ne 0
        $isReparsePoint = ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        if ($isDirectory -and -not $isReparsePoint) {
            Remove-AtpDirectoryTreeStrict $entry
        } elseif ($isDirectory) {
            Clear-AtpReadOnly $entry
            [IO.Directory]::Delete($entry, $false)
        } else {
            Remove-AtpFileStrict $entry
        }
    }
    Clear-AtpReadOnly $native
    [IO.Directory]::Delete($native, $false)
    if (Test-AtpPathEntryExists $Path) { throw "Failed to remove installer directory: $Path" }
}

function New-AtpDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $null = [IO.Directory]::CreateDirectory((ConvertTo-AtpExtendedPath $Path))
}

function Get-AtpFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::Open((ConvertTo-AtpExtendedPath $Path), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") }) -join '')
    } finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Get-AtpMinisignExecutable {
    $command = Get-Command "minisign.exe" -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) { return "" }
    return [string]$command.Source
}

function Get-AtpHttpStatusCodeFromException {
    param([Parameter(Mandatory = $true)][Exception]$Exception)

    $current = $Exception
    for ($depth = 0; $depth -lt 16 -and $null -ne $current; $depth++) {
        if ($current.Data.Contains("AtpHttpStatusCode")) {
            try { return [int]$current.Data["AtpHttpStatusCode"] } catch { }
        }

        $responseProperty = $current.PSObject.Properties["Response"]
        if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
            $statusProperty = $responseProperty.Value.PSObject.Properties["StatusCode"]
            if ($null -ne $statusProperty -and $null -ne $statusProperty.Value) {
                try { return [int]$statusProperty.Value } catch { }
            }
        }
        $current = $current.InnerException
    }
    return $null
}

function Confirm-AtpMinisignSignature {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Signature,
        [AllowEmptyString()][string]$MinisignPath = "",
        [ValidateRange(1, 600000)][int]$TimeoutMilliseconds = $script:AtpMinisignTimeoutMilliseconds
    )

    if (-not $PSBoundParameters.ContainsKey("MinisignPath")) {
        $MinisignPath = Get-AtpMinisignExecutable
    }
    if ([string]::IsNullOrWhiteSpace($MinisignPath)) {
        throw "minisign.exe is required to authenticate atp release archives; install minisign or use -NoVerify only for controlled testing"
    }
    if (Test-AtpDirectoryExists $Signature) {
        throw "minisign signature must be a regular file: $Signature"
    }
    if (-not (Test-AtpFileExists $Signature)) {
        throw "Required minisign signature not found: $Signature"
    }
    $signatureAttributes = Get-AtpFileAttributes $Signature
    if (($signatureAttributes -band [IO.FileAttributes]::Directory) -ne 0 -or
        ($signatureAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "minisign signature must be a regular file: $Signature"
    }

    $result = Invoke-AtpProcessCapture `
        -Path $MinisignPath `
        -Arguments @("-Vm", $Archive, "-x", $Signature, "-P", $script:AtpMinisignPublicKey) `
        -TimeoutMilliseconds $TimeoutMilliseconds `
        -Operation "minisign signature verification"
    $output = $result.Output
    $minisignExit = $result.ExitCode
    if ($minisignExit -ne 0) {
        $detail = (($output | ForEach-Object { [string]$_ }) -join " ").Trim()
        if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) }
        throw "minisign signature verification FAILED for '$Archive' (exit $minisignExit): $detail"
    }
    Write-AtpOk "minisign signature verified"
    return $true
}

function Confirm-AtpReleaseAuthenticity {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Signature,
        [string]$ArtifactUrl = "",
        [string]$OfflineSignature = "",
        [string]$VersionTag = "",
        [switch]$OfflineMode,
        [switch]$NoVerify
    )

    if ($NoVerify) {
        Write-AtpWarn "WARNING: publisher signature verification disabled by explicit -NoVerify"
        return $false
    }

    if ($OfflineMode) {
        $minisignPath = Get-AtpMinisignExecutable
        if ([string]::IsNullOrWhiteSpace($minisignPath)) {
            throw "minisign.exe is required to authenticate offline atp release archives; install minisign or use -NoVerify only for controlled testing"
        }
        if ([string]::IsNullOrWhiteSpace($OfflineSignature)) {
            throw "Offline verified install requires a sibling '$($script:AtpAsset).minisig' signature"
        }
        if (Test-AtpDirectoryExists $OfflineSignature) {
            throw "Offline minisign signature must be a regular file: $OfflineSignature"
        }
        if (-not (Test-AtpFileExists $OfflineSignature)) {
            throw "Offline verified install requires sibling minisign signature: $OfflineSignature"
        }
        $offlineSignatureAttributes = Get-AtpFileAttributes $OfflineSignature
        if (($offlineSignatureAttributes -band [IO.FileAttributes]::Directory) -ne 0 -or
            ($offlineSignatureAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Offline minisign signature must be a regular non-reparse file: $OfflineSignature"
        }
        [IO.File]::Copy(
            (ConvertTo-AtpExtendedPath $OfflineSignature),
            (ConvertTo-AtpExtendedPath $Signature),
            $false
        )
    } else {
        if ([string]::IsNullOrWhiteSpace($ArtifactUrl)) {
            throw "Online minisign verification requires the release artifact URL"
        }
        if ([string]::IsNullOrWhiteSpace($VersionTag)) {
            throw "Online release authentication requires a concrete vX.Y.Z version"
        }
        $legacyUnsignedRelease = Test-AtpLegacyUnsignedRelease $VersionTag
        $normalizedVersion = Normalize-AtpVersionTag $VersionTag
        $signatureUrl = "$ArtifactUrl.minisig"
        try {
            Invoke-AtpDownload -Uri $signatureUrl -OutFile $Signature
        } catch {
            $downloadException = $_.Exception
            $statusCode = Get-AtpHttpStatusCodeFromException $downloadException
            try { Remove-AtpFileStrict $Signature } catch { }
            if ($legacyUnsignedRelease -and $statusCode -eq 404) {
                Write-AtpWarn "WARNING: UNAUTHENTICATED LEGACY RELEASE $normalizedVersion; mandatory SHA-256 passed, but the Minisign signature endpoint returned HTTP 404 and releases before v0.3.8 were not required to publish signatures"
                return $false
            }
            if ($legacyUnsignedRelease) {
                $reportedStatus = if ($null -eq $statusCode) { "unknown" } else { [string]$statusCode }
                throw "Could not confirm that the legacy Minisign signature is absent at '$signatureUrl' (HTTP $reportedStatus); only a confirmed HTTP 404 permits the legacy checksum-only exception: $($downloadException.Message)"
            }
            throw "Failed to download required minisign signature '$signatureUrl': $($downloadException.Message)"
        }
        if (-not (Test-AtpFileExists $Signature)) {
            throw "Required minisign signature download did not create a file: $signatureUrl"
        }
        $minisignPath = Get-AtpMinisignExecutable
        if ([string]::IsNullOrWhiteSpace($minisignPath)) {
            throw "minisign.exe is required to authenticate the published atp release signature; install minisign or use -NoVerify only for controlled testing"
        }
    }

    $verified = Confirm-AtpMinisignSignature `
        -Archive $Archive `
        -Signature $Signature `
        -MinisignPath $minisignPath
    if (-not $verified) {
        throw "minisign signature verification did not produce an authenticated result for '$Archive'"
    }
    return $true
}

Initialize-AtpLongPathSupport

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
  -NoVerify        TESTING ONLY: skip minisign authentication (SHA-256 stays mandatory)
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

function Test-AtpLegacyUnsignedRelease {
    param([Parameter(Mandatory = $true)][string]$VersionTag)

    $normalized = Normalize-AtpVersionTag $VersionTag
    try {
        $parsed = [Version]$normalized.Substring(1)
    } catch {
        throw "Invalid release version '$VersionTag'; expected vX.Y.Z with numeric components supported by Windows"
    }
    return ($parsed -lt $script:AtpFirstSignedRelease)
}

function Get-AtpWebResponseUri {
    param([Parameter(Mandatory = $true)]$Response)

    $baseProperty = $Response.PSObject.Properties['BaseResponse']
    if ($null -eq $baseProperty -or $null -eq $baseProperty.Value) {
        throw "GitHub's latest-release redirect response did not expose BaseResponse"
    }
    $baseResponse = $baseProperty.Value

    $responseUriProperty = $baseResponse.PSObject.Properties['ResponseUri']
    if ($null -ne $responseUriProperty -and $null -ne $responseUriProperty.Value) {
        return [Uri]$responseUriProperty.Value
    }

    $requestMessageProperty = $baseResponse.PSObject.Properties['RequestMessage']
    if ($null -ne $requestMessageProperty -and $null -ne $requestMessageProperty.Value) {
        $requestUriProperty = $requestMessageProperty.Value.PSObject.Properties['RequestUri']
        if ($null -ne $requestUriProperty -and $null -ne $requestUriProperty.Value) {
            return [Uri]$requestUriProperty.Value
        }
    }
    throw "GitHub's latest-release redirect response did not expose its final URI"
}

function Get-AtpLatestVersionTag {
    $apiUri = "https://api.github.com/repos/$($script:AtpOwner)/$($script:AtpRepo)/releases/latest"
    Write-AtpInfo "Resolving the latest stable release"
    $apiFailure = ""
    try {
        $response = Invoke-RestMethod -Uri $apiUri -TimeoutSec $script:AtpWebTimeoutSeconds -Headers @{
            Accept = "application/vnd.github+json"
            "User-Agent" = "atp-install.ps1"
        }
        if ($null -eq $response -or [string]::IsNullOrWhiteSpace([string]$response.tag_name)) {
            throw "GitHub's latest-release response did not contain tag_name"
        }
        return Normalize-AtpVersionTag ([string]$response.tag_name)
    } catch {
        $apiFailure = $_.Exception.Message
        Write-AtpWarn "GitHub API version resolution failed; trying the releases/latest redirect"
    }

    $redirectUri = "https://github.com/$($script:AtpOwner)/$($script:AtpRepo)/releases/latest"
    try {
        $oldProgress = $ProgressPreference
        $ProgressPreference = "SilentlyContinue"
        try {
            $redirectResponse = Invoke-WebRequest -Uri $redirectUri -UseBasicParsing -TimeoutSec $script:AtpWebTimeoutSeconds -Headers @{
                "User-Agent" = "atp-install.ps1"
            }
        } finally {
            $ProgressPreference = $oldProgress
        }
        $finalUri = Get-AtpWebResponseUri $redirectResponse
        $path = $finalUri.AbsolutePath.TrimEnd('/')
        $prefix = "/$($script:AtpOwner)/$($script:AtpRepo)/releases/tag/"
        if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unexpected latest-release redirect target: $($finalUri.AbsoluteUri)"
        }
        $encodedTag = $path.Substring($prefix.Length)
        if ([string]::IsNullOrWhiteSpace($encodedTag) -or $encodedTag.Contains('/')) {
            throw "Unexpected latest-release redirect target: $($finalUri.AbsoluteUri)"
        }
        $tag = Normalize-AtpVersionTag ([Uri]::UnescapeDataString($encodedTag))
        Write-AtpInfo "Resolved latest version via redirect: $tag"
        return $tag
    } catch {
        throw "Could not resolve the latest atp release (GitHub API: $apiFailure; redirect: $($_.Exception.Message)). Re-run with -Version vX.Y.Z"
    }
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
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec $script:AtpWebTimeoutSeconds -Headers @{
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
        return [string](Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $script:AtpWebTimeoutSeconds -Headers @{
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
    $actual = Get-AtpFileSha256 $Path
    $wanted = $Expected.ToLowerInvariant()
    if ($actual -cne $wanted) {
        throw "Checksum verification failed for '$Path' (expected $wanted, got $actual)"
    }
    Write-AtpOk "Checksum verified: $($actual.Substring(0, 16))..."
}

function Assert-AtpPeX64 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::Open((ConvertTo-AtpExtendedPath $Path), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
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

    if (-not (Test-AtpFileExists $Path)) {
        throw "atp executable is not a regular file: $Path"
    }
    $attributes = Get-AtpFileAttributes $Path
    if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
        throw "atp executable is not a regular file: $Path"
    }
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "atp executable must not be a reparse point: $Path"
    }
    Assert-AtpPeX64 $Path

    $versionResult = Invoke-AtpExecutableCapture -Path $Path -Arguments @("--version")
    $versionExit = $versionResult.ExitCode
    $versionLine = $versionResult.Output.Trim()
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

    $keyResult = Invoke-AtpExecutableCapture -Path $Path -Arguments @("rq-keygen")
    $keyExit = $keyResult.ExitCode
    $key = $keyResult.Output.Trim()
    if ($keyExit -ne 0 -or $key -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "atp rq-keygen self-test failed (exit $keyExit)"
    }

    return [PSCustomObject]@{
        Version = $binaryVersion
        VersionLine = $versionLine
    }
}

function ConvertTo-AtpProcessArgument {
    param([AllowEmptyString()][string]$Argument)

    if ($Argument.Length -eq 0) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }

    $builder = New-Object Text.StringBuilder
    $null = $builder.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]'\') {
            $backslashes++
            continue
        }
        if ($character -eq [char]'"') {
            for ($index = 0; $index -lt ((2 * $backslashes) + 1); $index++) {
                $null = $builder.Append('\')
            }
            $null = $builder.Append('"')
            $backslashes = 0
            continue
        }
        for ($index = 0; $index -lt $backslashes; $index++) { $null = $builder.Append('\') }
        $backslashes = 0
        $null = $builder.Append($character)
    }
    for ($index = 0; $index -lt (2 * $backslashes); $index++) { $null = $builder.Append('\') }
    $null = $builder.Append('"')
    return $builder.ToString()
}

function Invoke-AtpProcessCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [ValidateRange(1, 600000)][int]$TimeoutMilliseconds,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = ConvertTo-AtpExtendedPath $Path
    $startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-AtpProcessArgument $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $started = $false
    try {
        if (-not $process.Start()) { throw "Failed to start ${Operation}: $Path" }
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try {
                if (-not $process.HasExited) { $process.Kill() }
            } catch { }
            try { $null = $process.WaitForExit($script:AtpPipeDrainTimeoutMilliseconds) } catch { }
            try { $null = $stdoutTask.Wait($script:AtpPipeDrainTimeoutMilliseconds) } catch { }
            try { $null = $stderrTask.Wait($script:AtpPipeDrainTimeoutMilliseconds) } catch { }
            throw "$Operation timed out after $TimeoutMilliseconds ms: $Path"
        }
        $stdoutDrained = $stdoutTask.Wait($script:AtpPipeDrainTimeoutMilliseconds)
        $stderrDrained = $stderrTask.Wait($script:AtpPipeDrainTimeoutMilliseconds)
        if (-not $stdoutDrained -or -not $stderrDrained) {
            throw "$Operation output did not drain after process exit: $Path"
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $output = if ([string]::IsNullOrWhiteSpace($stderr)) { $stdout } elseif ([string]::IsNullOrWhiteSpace($stdout)) { $stderr } else { "$stdout`n$stderr" }
        return [PSCustomObject]@{ ExitCode = $process.ExitCode; Output = $output }
    } finally {
        if ($started) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill()
                    $null = $process.WaitForExit($script:AtpPipeDrainTimeoutMilliseconds)
                }
            } catch { }
        }
        $process.Dispose()
    }
}

function Invoke-AtpExecutableCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [ValidateRange(1, 600000)][int]$TimeoutMilliseconds = $script:AtpExecutableTimeoutMilliseconds
    )

    $executionPath = Get-AtpFullPath $Path
    $executionCopy = ""
    try {
        # .NET Framework's Process.Start performs a legacy MAX_PATH check even
        # when its System.IO layer accepts an extended path. Execute an exact,
        # hash-checked short copy so PowerShell 5.1 can verify long-path installs.
        if ((Test-AtpWindows) -and $executionPath.Length -ge 248) {
            $executionCopy = Join-AtpPath ([IO.Path]::GetTempPath()) ("atp-exec-{0}.exe" -f [Guid]::NewGuid().ToString("N"))
            if ((Get-AtpFullPath $executionCopy).Length -ge 248) {
                throw "PowerShell's temporary directory is too long to execute the atp self-test"
            }
            [IO.File]::Copy((ConvertTo-AtpExtendedPath $Path), (ConvertTo-AtpExtendedPath $executionCopy), $false)
            if ((Get-AtpFileSha256 $Path) -cne (Get-AtpFileSha256 $executionCopy)) {
                throw "Long-path atp self-test copy failed checksum verification"
            }
            $executionPath = $executionCopy
        }

        return Invoke-AtpProcessCapture `
            -Path $executionPath `
            -Arguments $Arguments `
            -TimeoutMilliseconds $TimeoutMilliseconds `
            -Operation "atp executable self-test"
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($executionCopy)) { Remove-AtpFileStrict $executionCopy }
    }
}

function Copy-AtpZipEntry {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][int64]$MaximumBytes
    )

    $inputStream = $Entry.Open()
    $outputStream = [IO.File]::Open((ConvertTo-AtpExtendedPath $Destination), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
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
    if ((Test-AtpFileExists $Destination) -or (Test-AtpDirectoryExists $Destination)) {
        throw "Archive extraction destination already exists: $Destination"
    }
    New-AtpDirectory $Destination

    $zip = [IO.Compression.ZipFile]::OpenRead((ConvertTo-AtpExtendedPath $Archive))
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
            Copy-AtpZipEntry -Entry $entry -Destination (Join-AtpPath $Destination $entry.FullName) -MaximumBytes $MaximumEntryBytes
        }
    } finally {
        $zip.Dispose()
    }

    return (Join-AtpPath $Destination "atp.exe")
}

function Get-AtpNormalizedPathEntry {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = Get-AtpFullPath $Path
    $root = [IO.Path]::GetPathRoot($full)
    $trimmed = $full.TrimEnd([char]'\', [char]'/')
    if (-not [string]::IsNullOrWhiteSpace($root)) {
        $trimmedRoot = $root.TrimEnd([char]'\', [char]'/')
        if ([string]::Equals($trimmed, $trimmedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            return $root
        }
    }
    return $trimmed
}

function Test-AtpPathContains {
    param(
        [string]$PathValue,
        [Parameter(Mandatory = $true)][string]$Candidate
    )

    $candidateFull = Get-AtpNormalizedPathEntry $Candidate
    foreach ($entry in ([string]$PathValue -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        try {
            $expanded = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"'))
            $entryFull = Get-AtpNormalizedPathEntry $expanded
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

    $full = Get-AtpNormalizedPathEntry $Directory
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    if (Test-AtpPathContains -PathValue $current -Candidate $full) {
        Write-AtpInfo "$full is already present in the User PATH"
        return
    }
    $next = if ([string]::IsNullOrWhiteSpace($current)) { $full } else { "$current;$full" }
    if ($next.Length -gt 32767) { throw "User PATH would exceed the Windows environment-variable limit" }
    [Environment]::SetEnvironmentVariable("Path", $next, "User")
    if (-not (Test-AtpPathContains -PathValue $env:Path -Candidate $full)) {
        $env:Path = if ([string]::IsNullOrWhiteSpace($env:Path)) { $full } else { "$($env:Path);$full" }
    }
    Write-AtpOk "Added $full to the User PATH; open a new terminal to use it"
}

function Open-AtpInstallLock {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $lockPath = Join-AtpPath $Directory ".atp-install.lock"
    if (Test-AtpPathEntryExists $lockPath) {
        throw "Another atp installer is running for '$Directory', or its lock already exists"
    }
    try {
        return [IO.FileStream]::new(
            (ConvertTo-AtpExtendedPath $lockPath),
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::DeleteOnClose
        )
    } catch {
        throw "Another atp installer is running for '$Directory', or its lock cannot be created"
    }
}

function Assert-AtpNoReparsePathPrefix {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = Get-AtpFullPath $Path
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "Install destination has no filesystem root: $full"
    }

    $current = $root
    $relative = $full.Substring($root.Length)
    foreach ($component in ($relative -split '[\\/]' | Where-Object { $_.Length -gt 0 })) {
        $current = Join-AtpPath $current $component
        if (-not (Test-AtpFileExists $current) -and -not (Test-AtpDirectoryExists $current)) { continue }
        $attributes = Get-AtpFileAttributes $current
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Install destination crosses a reparse point: $current"
        }
    }
}

function Assert-AtpInstallTarget {
    param([Parameter(Mandatory = $true)][string]$Target)

    if ((Test-AtpFileExists $Target) -or (Test-AtpDirectoryExists $Target)) {
        $attributes = Get-AtpFileAttributes $Target
        if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { throw "Install target is a directory: $Target" }
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
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
    $directory = [IO.Path]::GetDirectoryName((Get-AtpFullPath $Target))
    $stage = Join-AtpPath $directory (".atp-install-{0}.exe" -f [Guid]::NewGuid().ToString("N"))
    $backup = Join-AtpPath $directory (".atp-backup-{0}.exe" -f [Guid]::NewGuid().ToString("N"))
    $hadExisting = Test-AtpFileExists $Target
    $installed = $false
    $existingAttributes = $null

    try {
        [IO.File]::Copy((ConvertTo-AtpExtendedPath $Source), (ConvertTo-AtpExtendedPath $stage), $false)
        Clear-AtpReadOnly $stage
        try { Unblock-File -LiteralPath $stage -ErrorAction SilentlyContinue } catch { }
        $null = Test-AtpExecutable -Path $stage -ExpectedVersionTag $ExpectedVersionTag

        Assert-AtpInstallTarget $Target
        if ($hadExisting) {
            $existingAttributes = Get-AtpFileAttributes $Target
            Clear-AtpReadOnly $Target
            try {
                [IO.File]::Replace(
                    (ConvertTo-AtpExtendedPath $stage),
                    (ConvertTo-AtpExtendedPath $Target),
                    (ConvertTo-AtpExtendedPath $backup),
                    $true
                )
                $installed = $true
            } catch {
                if (Test-AtpFileExists $Target) {
                    Set-AtpFileAttributes -Path $Target -Attributes $existingAttributes
                }
                throw
            }
            if (Test-AtpFileExists $backup) {
                Set-AtpFileAttributes -Path $backup -Attributes $existingAttributes
            }
        } else {
            [IO.File]::Move((ConvertTo-AtpExtendedPath $stage), (ConvertTo-AtpExtendedPath $Target))
            $installed = $true
        }
        Clear-AtpReadOnly $Target
        $null = Test-AtpExecutable -Path $Target -ExpectedVersionTag $ExpectedVersionTag
        Remove-AtpFileStrict $backup
    } catch {
        $originalError = $_
        if ($installed -and $hadExisting -and (Test-AtpFileExists $backup)) {
            try {
                Clear-AtpReadOnly $backup
                if (Test-AtpFileExists $Target) {
                    Clear-AtpReadOnly $Target
                    $failed = Join-AtpPath $directory (".atp-failed-{0}.exe" -f [Guid]::NewGuid().ToString("N"))
                    [IO.File]::Replace(
                        (ConvertTo-AtpExtendedPath $backup),
                        (ConvertTo-AtpExtendedPath $Target),
                        (ConvertTo-AtpExtendedPath $failed),
                        $true
                    )
                    Set-AtpFileAttributes -Path $Target -Attributes $existingAttributes
                    Remove-AtpFileStrict $failed
                } else {
                    [IO.File]::Move((ConvertTo-AtpExtendedPath $backup), (ConvertTo-AtpExtendedPath $Target))
                    Set-AtpFileAttributes -Path $Target -Attributes $existingAttributes
                }
            } catch {
                throw "Install failed and rollback also failed; backup remains at '$backup'. Original error: $($originalError.Exception.Message)"
            }
        } elseif ($installed -and -not $hadExisting -and (Test-AtpFileExists $Target)) {
            Remove-AtpFileStrict $Target
        } elseif ($hadExisting -and $null -ne $existingAttributes -and (Test-AtpFileExists $Target)) {
            Set-AtpFileAttributes -Path $Target -Attributes $existingAttributes
        }
        throw $originalError
    } finally {
        Remove-AtpFileStrict $stage
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
    if (Test-AtpFileExists $sidecar) {
        return Resolve-AtpChecksumText -Content ([IO.File]::ReadAllText((ConvertTo-AtpExtendedPath $sidecar))) -AssetName $script:AtpAsset -AllowBareHash
    }
    $manifest = Join-AtpPath ([IO.Path]::GetDirectoryName((Get-AtpFullPath $Archive))) "SHA256SUMS"
    if (Test-AtpFileExists $manifest) {
        return Resolve-AtpManifestHash -Content ([IO.File]::ReadAllText((ConvertTo-AtpExtendedPath $manifest))) -AssetName $script:AtpAsset
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
        Join-AtpPath $profile ".local\bin"
    } else {
        $Dest
    }
    $destination = Get-AtpFullPath $destinationInput
    Assert-AtpNoReparsePathPrefix $destination
    if ((Test-AtpFileExists $destination) -or (Test-AtpDirectoryExists $destination)) {
        $destinationAttributes = Get-AtpFileAttributes $destination
        if (($destinationAttributes -band [IO.FileAttributes]::Directory) -eq 0) {
            throw "Install destination is a file: $destination"
        }
        if (($destinationAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Install destination must not be a reparse point: $destination"
        }
    } else {
        New-AtpDirectory $destination
    }
    Assert-AtpNoReparsePathPrefix $destination
    $targetPath = Join-AtpPath $destination $script:AtpBinary
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
    $tempRoot = ""
    try {
        if (-not $Force -and -not [string]::IsNullOrWhiteSpace($versionTag) -and (Test-AtpFileExists $targetPath)) {
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

        $tempRoot = Join-AtpPath ([IO.Path]::GetTempPath()) ("atp-install-{0}" -f [Guid]::NewGuid().ToString("N"))
        New-AtpDirectory $tempRoot
        $archivePath = Join-AtpPath $tempRoot $script:AtpAsset
        $expectedHash = ""
        $artifactUrl = ""
        $offlineSignature = ""

        if ($offlineMode) {
            $offlinePath = Get-AtpFullPath $Offline
            if (-not (Test-AtpFileExists $offlinePath)) {
                throw "Offline archive not found: $offlinePath"
            }
            if (-not [string]::Equals([IO.Path]::GetFileName($offlinePath), $script:AtpAsset, [StringComparison]::Ordinal)) {
                throw "Offline archive must be named '$($script:AtpAsset)'"
            }
            $expectedHash = Get-AtpOfflineChecksum -Archive $offlinePath -ExplicitChecksum $Checksum
            [IO.File]::Copy((ConvertTo-AtpExtendedPath $offlinePath), (ConvertTo-AtpExtendedPath $archivePath), $false)
            $offlineSignature = "$offlinePath.minisig"
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
        $signaturePath = Join-AtpPath $tempRoot "$($script:AtpAsset).minisig"
        $null = Confirm-AtpReleaseAuthenticity `
            -Archive $archivePath `
            -Signature $signaturePath `
            -ArtifactUrl $artifactUrl `
            -OfflineSignature $offlineSignature `
            -VersionTag $versionTag `
            -OfflineMode:$offlineMode `
            -NoVerify:$NoVerify
        $extractPath = Join-AtpPath $tempRoot "extract"
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
        $cleanupFailures = New-Object System.Collections.Generic.List[string]
        if (-not [string]::IsNullOrWhiteSpace($tempRoot)) {
            try { Remove-AtpDirectoryTreeStrict $tempRoot } catch { $cleanupFailures.Add($_.Exception.Message) }
        }
        if ($null -ne $lock) {
            try { $lock.Dispose() } catch { $cleanupFailures.Add($_.Exception.Message) }
        }
        if ($cleanupFailures.Count -gt 0) {
            throw "Installer cleanup failed: $($cleanupFailures -join '; ')"
        }
    }
}

if ($LoadFunctionsOnly) { return }
if ($Help) { Show-AtpUsage; return }

try {
    # This secures installer-owned downloads. The documented bootstrap enables
    # TLS 1.2 before Invoke-RestMethod downloads this script on PowerShell 5.1.
    Enable-AtpTls12
    Invoke-AtpInstaller
} catch {
    Write-AtpFailure $_.Exception.Message
    throw
}
