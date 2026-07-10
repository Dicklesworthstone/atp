#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:PassCount = 0
$script:LastExit = 0
$script:LastOutput = ""
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Installer = Join-Path $script:RepoRoot "install.ps1"
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("atp-ps-installer-tests-{0}" -f [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $script:TestRoot | Out-Null

function Complete-TestRun {
    if (Test-Path -LiteralPath $script:TestRoot) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
trap { Complete-TestRun; break }

function Fail-Test {
    param([string]$Message)
    throw "FAIL: $Message`n$($script:LastOutput)"
}

function Pass-Test {
    param([string]$Message)
    $script:PassCount++
    Write-Host ("ok {0:D2} - {1}" -f $script:PassCount, $Message)
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { Fail-Test $Message }
}

function Assert-Contains {
    param([string]$Needle, [string]$Haystack, [string]$Message)
    if ($Haystack.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -lt 0) { Fail-Test $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Contains, [string]$Message)
    try {
        & $Action
    } catch {
        if ([string]::IsNullOrWhiteSpace($Contains) -or $_.Exception.Message.IndexOf($Contains, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return
        }
        Fail-Test "$Message (wrong error: $($_.Exception.Message))"
    }
    Fail-Test "$Message (did not throw)"
}

function Get-CurrentPowerShellPath {
    if ($PSVersionTable.PSEdition -eq "Desktop") { return (Join-Path $PSHOME "powershell.exe") }
    return (Get-Process -Id $PID).Path
}

function Invoke-InstallerProcess {
    param([string[]]$Arguments)
    $engine = Get-CurrentPowerShellPath
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& $engine -NoProfile -ExecutionPolicy Bypass -File $script:Installer @Arguments 2>&1)
        $script:LastExit = $LASTEXITCODE
        $script:LastOutput = ($output | ForEach-Object { [string]$_ }) -join "`n"
    } finally {
        $ErrorActionPreference = $oldPreference
    }
}

function New-FixtureExecutable {
    param([string]$Path, [string]$Version, [int]$RqExit = 0)
    $className = "AtpFixture" + [Guid]::NewGuid().ToString("N")
    $source = @"
using System;
public static class $className {
    public static int Main(string[] args) {
        if (args.Length == 1 && args[0] == "--version") {
            Console.WriteLine("atp $Version");
            return 0;
        }
        if (args.Length == 1 && args[0] == "rq-keygen") {
            if ($RqExit == 0) Console.WriteLine("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
            return $RqExit;
        }
        return 0;
    }
}
"@
    $sourcePath = "$Path.cs"
    [IO.File]::WriteAllText($sourcePath, $source, (New-Object Text.UTF8Encoding($false)))
    $compiler = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
        throw "64-bit .NET Framework C# compiler not found: $compiler"
    }
    $compilerOutput = @(& $compiler /nologo /target:exe /platform:x64 "/out:$Path" $sourcePath 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "fixture C# compilation failed: $($compilerOutput -join "`n")"
    }
}

function New-ZipFixture {
    param([string]$Path, [object[]]$Members)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($member in $Members) {
            $entry = $zip.CreateEntry([string]$member.Name, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::Parse("2026-01-01T00:00:00Z")
            $stream = $entry.Open()
            try {
                if ($null -ne $member.Path) {
                    $input = [IO.File]::OpenRead([string]$member.Path)
                    try { $input.CopyTo($stream) } finally { $input.Dispose() }
                } else {
                    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$member.Text)
                    $stream.Write($bytes, 0, $bytes.Length)
                }
            } finally {
                $stream.Dispose()
            }
        }
    } finally {
        $zip.Dispose()
    }
}

function New-ValidZip {
    param([string]$Path, [string]$Executable)
    New-ZipFixture -Path $Path -Members @(
        [PSCustomObject]@{ Name = "atp.exe"; Path = $Executable; Text = $null },
        [PSCustomObject]@{ Name = "LICENSE"; Path = $null; Text = "fixture license" }
    )
}

. $script:Installer -LoadFunctionsOnly

Assert-True (Test-AtpWindows) "test suite must run on Windows"
Assert-True ((Get-AtpWindowsTarget) -ceq "x86_64-pc-windows-msvc") "x64 target detection failed"
$savedArch = $env:PROCESSOR_ARCHITECTURE
$savedWowArch = $env:PROCESSOR_ARCHITEW6432
try {
    $env:PROCESSOR_ARCHITEW6432 = ""
    $env:PROCESSOR_ARCHITECTURE = "ARM64"
    Assert-Throws { Get-AtpWindowsTarget } "only native Windows x64" "Windows ARM64 must fail closed"
} finally {
    $env:PROCESSOR_ARCHITECTURE = $savedArch
    $env:PROCESSOR_ARCHITEW6432 = $savedWowArch
}
Assert-True ((Normalize-AtpVersionTag "1.2.3") -ceq "v1.2.3") "bare version did not normalize"
Assert-True ((Normalize-AtpVersionTag "v1.2.3") -ceq "v1.2.3") "tagged version changed"
Assert-Throws { Normalize-AtpVersionTag "main" } "expected vX.Y.Z" "invalid versions must fail"
Assert-True ((Get-AtpArtifactUrl "v1.2.3") -ceq "https://github.com/Dicklesworthstone/atp/releases/download/v1.2.3/atp-x86_64-pc-windows-msvc.zip") "artifact URL mismatch"
Pass-Test "Windows x64, stable-version, and exact artifact URL contracts"

function Invoke-RestMethod {
    param([string]$Uri, [hashtable]$Headers)
    if ($Uri -notlike "*/releases/latest") { throw "unexpected mocked URI: $Uri" }
    return [PSCustomObject]@{ tag_name = "v1.2.3" }
}
try {
    Assert-True ((Get-AtpLatestVersionTag) -ceq "v1.2.3") "latest release tag did not resolve"
} finally {
    Remove-Item -LiteralPath Function:\Invoke-RestMethod
}
Pass-Test "latest-release resolution normalizes a stable GitHub API tag without network"

$hashA = "a" * 64
$hashB = "b" * 64
$manifest = "$hashB  other.zip`n$hashA  atp-x86_64-pc-windows-msvc.zip`n"
Assert-True ((Resolve-AtpManifestHash $manifest "atp-x86_64-pc-windows-msvc.zip") -ceq $hashA) "manifest selected the wrong row"
Assert-Throws { Resolve-AtpManifestHash "$manifest$hashA  atp-x86_64-pc-windows-msvc.zip`n" "atp-x86_64-pc-windows-msvc.zip" } "exactly one" "duplicate manifest rows must fail"
Assert-Throws { Resolve-AtpManifestHash "$hashA  nested/atp-x86_64-pc-windows-msvc.zip" "atp-x86_64-pc-windows-msvc.zip" } "found 0" "path-qualified checksum row must not match"
Assert-Throws { Resolve-AtpChecksumText "not-a-hash" "atp-x86_64-pc-windows-msvc.zip" -AllowBareHash } "found 0" "malformed bare checksum must fail"
Pass-Test "checksum parsing selects one exact asset row and rejects ambiguity"

$goodExe = Join-Path $script:TestRoot "good-atp.exe"
$badVersionExe = Join-Path $script:TestRoot "bad-version-atp.exe"
$badRqExe = Join-Path $script:TestRoot "bad-rq-atp.exe"
New-FixtureExecutable -Path $goodExe -Version "1.2.3"
New-FixtureExecutable -Path $badVersionExe -Version "9.9.9"
New-FixtureExecutable -Path $badRqExe -Version "1.2.3" -RqExit 42
$goodInfo = Test-AtpExecutable -Path $goodExe -ExpectedVersionTag "v1.2.3"
Assert-True ($goodInfo.Version -ceq "1.2.3") "fixture executable version validation failed"
Assert-Throws { Test-AtpExecutable -Path $badVersionExe -ExpectedVersionTag "v1.2.3" } "version mismatch" "wrong binary version must fail"
Assert-Throws { Test-AtpExecutable -Path $badRqExe -ExpectedVersionTag "v1.2.3" } "rq-keygen" "rq-keygen failure must fail"
$notPe = Join-Path $script:TestRoot "not-pe.exe"
[IO.File]::WriteAllText($notPe, "not a PE")
Assert-Throws { Test-AtpExecutable -Path $notPe } "not a PE" "non-PE executable must fail"
Pass-Test "x64 PE, exact version, and rq-keygen validation"

$validZip = Join-Path $script:TestRoot "atp-x86_64-pc-windows-msvc.zip"
New-ValidZip -Path $validZip -Executable $goodExe
$validExtract = Join-Path $script:TestRoot "extract-valid"
$extracted = Expand-AtpArchive -Archive $validZip -Destination $validExtract
Assert-True (Test-Path -LiteralPath $extracted -PathType Leaf) "valid archive did not extract atp.exe"
Assert-True (Test-Path -LiteralPath (Join-Path $validExtract "LICENSE") -PathType Leaf) "valid archive did not extract LICENSE"
Pass-Test "strict archive extraction accepts the exact two-member layout"

$checksumDir = Join-Path $script:TestRoot "offline-checksum-resolution"
New-Item -ItemType Directory -Path $checksumDir | Out-Null
$checksumArchive = Join-Path $checksumDir "atp-x86_64-pc-windows-msvc.zip"
[IO.File]::Copy($validZip, $checksumArchive)
$archiveHash = (Get-FileHash -LiteralPath $checksumArchive -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-Throws { Get-AtpOfflineChecksum -Archive $checksumArchive } "requires -Checksum" "offline install without checksum material must fail"
[IO.File]::WriteAllText("$checksumArchive.sha256", $archiveHash)
Assert-True ((Get-AtpOfflineChecksum -Archive $checksumArchive) -ceq $archiveHash) "offline sidecar checksum did not resolve"
[IO.File]::Delete("$checksumArchive.sha256")
[IO.File]::WriteAllText((Join-Path $checksumDir "SHA256SUMS"), "$hashB  other.zip`n$archiveHash  atp-x86_64-pc-windows-msvc.zip`n")
Assert-True ((Get-AtpOfflineChecksum -Archive $checksumArchive) -ceq $archiveHash) "offline aggregate checksum did not resolve"
Pass-Test "offline checksum resolution is fail-closed and supports exact sibling manifests"

$invalidCases = @(
    [PSCustomObject]@{ Label = "missing-license"; Members = @([PSCustomObject]@{ Name = "atp.exe"; Path = $goodExe; Text = $null }) },
    [PSCustomObject]@{ Label = "extra-member"; Members = @([PSCustomObject]@{ Name = "atp.exe"; Path = $goodExe; Text = $null }, [PSCustomObject]@{ Name = "LICENSE"; Path = $null; Text = "license" }, [PSCustomObject]@{ Name = "README"; Path = $null; Text = "extra" }) },
    [PSCustomObject]@{ Label = "nested-member"; Members = @([PSCustomObject]@{ Name = "bin/atp.exe"; Path = $goodExe; Text = $null }, [PSCustomObject]@{ Name = "LICENSE"; Path = $null; Text = "license" }) },
    [PSCustomObject]@{ Label = "traversal-member"; Members = @([PSCustomObject]@{ Name = "../atp.exe"; Path = $goodExe; Text = $null }, [PSCustomObject]@{ Name = "LICENSE"; Path = $null; Text = "license" }) },
    [PSCustomObject]@{ Label = "case-mismatch"; Members = @([PSCustomObject]@{ Name = "ATP.EXE"; Path = $goodExe; Text = $null }, [PSCustomObject]@{ Name = "LICENSE"; Path = $null; Text = "license" }) },
    [PSCustomObject]@{ Label = "duplicate-member"; Members = @([PSCustomObject]@{ Name = "atp.exe"; Path = $goodExe; Text = $null }, [PSCustomObject]@{ Name = "atp.exe"; Path = $goodExe; Text = $null }) }
)
foreach ($case in $invalidCases) {
    $zipPath = Join-Path $script:TestRoot ("$($case.Label).zip")
    New-ZipFixture -Path $zipPath -Members $case.Members
    $outPath = Join-Path $script:TestRoot ("extract-$($case.Label)")
    Assert-Throws { Expand-AtpArchive -Archive $zipPath -Destination $outPath } "" "$($case.Label) archive must fail"
}
$smallLimitExtract = Join-Path $script:TestRoot "extract-size-limit"
Assert-Throws { Expand-AtpArchive -Archive $validZip -Destination $smallLimitExtract -MaximumEntryBytes 8 -MaximumTotalBytes 16 } "expanded size" "archive size limit must fail"
Pass-Test "strict archive validation rejects missing, extra, nested, traversal, case, duplicate, and oversized members"

$validHash = (Get-FileHash -LiteralPath $validZip -Algorithm SHA256).Hash.ToLowerInvariant()
$installDest = Join-Path $script:TestRoot "installed"
Invoke-InstallerProcess @("-Offline", $validZip, "-Checksum", $validHash, "-Version", "v1.2.3", "-Dest", $installDest, "-Verify", "-Force", "-Quiet")
Assert-True ($script:LastExit -eq 0) "valid offline installer failed"
$installedExe = Join-Path $installDest "atp.exe"
Assert-True (Test-Path -LiteralPath $installedExe -PathType Leaf) "valid offline installer did not create atp.exe"
$null = Test-AtpExecutable -Path $installedExe -ExpectedVersionTag "v1.2.3"
Assert-True ([string]::IsNullOrWhiteSpace($script:LastOutput)) "quiet install emitted non-error output"
Pass-Test "offline checksum-verified install succeeds quietly and verifies"

$before = (Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash
Invoke-InstallerProcess @("-Offline", $validZip, "-Checksum", ("f" * 64), "-Version", "v1.2.3", "-Dest", $installDest, "-Force", "-Quiet")
Assert-True ($script:LastExit -ne 0) "wrong checksum unexpectedly succeeded"
Assert-Contains "Checksum verification failed" $script:LastOutput "wrong checksum error was not explicit"
Assert-True ((Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash -ceq $before) "wrong checksum changed the existing binary"
Pass-Test "wrong checksum fails closed and preserves the existing binary"

$badVersionZip = Join-Path $script:TestRoot "bad-version\atp-x86_64-pc-windows-msvc.zip"
New-Item -ItemType Directory -Path (Split-Path -Parent $badVersionZip) | Out-Null
New-ValidZip -Path $badVersionZip -Executable $badVersionExe
$badVersionHash = (Get-FileHash -LiteralPath $badVersionZip -Algorithm SHA256).Hash
Invoke-InstallerProcess @("-Offline", $badVersionZip, "-Checksum", $badVersionHash, "-Version", "v1.2.3", "-Dest", $installDest, "-Force", "-Quiet")
Assert-True ($script:LastExit -ne 0) "wrong-version archive unexpectedly succeeded"
Assert-Contains "version mismatch" $script:LastOutput "wrong-version error was not explicit"
Assert-True ((Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash -ceq $before) "wrong-version archive changed the existing binary"
Pass-Test "version mismatch fails before replacement and preserves the existing binary"

$badRqZip = Join-Path $script:TestRoot "bad-rq\atp-x86_64-pc-windows-msvc.zip"
New-Item -ItemType Directory -Path (Split-Path -Parent $badRqZip) | Out-Null
New-ValidZip -Path $badRqZip -Executable $badRqExe
$badRqHash = (Get-FileHash -LiteralPath $badRqZip -Algorithm SHA256).Hash
Invoke-InstallerProcess @("-Offline", $badRqZip, "-Checksum", $badRqHash, "-Version", "v1.2.3", "-Dest", $installDest, "-Force", "-Quiet")
Assert-True ($script:LastExit -ne 0) "rq-keygen-failing archive unexpectedly succeeded"
Assert-Contains "rq-keygen" $script:LastOutput "rq-keygen error was not explicit"
Assert-True ((Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash -ceq $before) "rq-keygen failure changed the existing binary"
Pass-Test "rq-keygen failure preserves the existing binary"

$missingArchive = Join-Path $script:TestRoot "missing\atp-x86_64-pc-windows-msvc.zip"
Invoke-InstallerProcess @("-Offline", $missingArchive, "-Version", "v1.2.3", "-Dest", $installDest, "-Verify", "-Quiet")
Assert-True ($script:LastExit -eq 0) "same-version install did not short-circuit before acquisition"
Assert-True ((Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash -ceq $before) "same-version short-circuit changed the existing binary"
Invoke-InstallerProcess @("-Offline", $missingArchive, "-Version", "v1.2.3", "-Dest", $installDest, "-Force", "-Quiet")
Assert-True ($script:LastExit -ne 0) "force did not reacquire the missing archive"
Assert-Contains "not found" $script:LastOutput "force failure did not report the missing archive"
Pass-Test "same-version skips acquisition but Force reacquires; Verify still runs"

$directoryDest = Join-Path $script:TestRoot "directory-target"
New-Item -ItemType Directory -Path (Join-Path $directoryDest "atp.exe") -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $directoryDest "atp.exe\sentinel"), "keep")
Invoke-InstallerProcess @("-Offline", $validZip, "-Checksum", $validHash, "-Version", "v1.2.3", "-Dest", $directoryDest, "-Force", "-Quiet")
Assert-True ($script:LastExit -ne 0) "directory install target unexpectedly succeeded"
Assert-Contains "directory" $script:LastOutput "directory-target error was not explicit"
Assert-True (Test-Path -LiteralPath (Join-Path $directoryDest "atp.exe\sentinel") -PathType Leaf) "directory target was mutated"
Pass-Test "directory install targets fail closed and are preserved"

$junctionRoot = Join-Path $script:TestRoot "junction-root"
$junctionTarget = Join-Path $script:TestRoot "junction-target"
New-Item -ItemType Directory -Path $junctionRoot | Out-Null
$junctionOutput = & cmd.exe /d /c "mklink /J `"$junctionTarget`" `"$junctionRoot`"" 2>&1
if ($LASTEXITCODE -eq 0) {
    Invoke-InstallerProcess @("-Offline", $validZip, "-Checksum", $validHash, "-Version", "v1.2.3", "-Dest", $junctionTarget, "-Force", "-Quiet")
    Assert-True ($script:LastExit -ne 0) "junction install destination unexpectedly succeeded"
    Assert-Contains "reparse point" $script:LastOutput "junction-destination error was not explicit"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $junctionRoot "atp.exe"))) "junction destination wrote through to its target"
    Pass-Test "junction install destinations fail closed without writing through"

    $junctionChild = Join-Path $junctionTarget "nested\bin"
    Invoke-InstallerProcess @("-Offline", $validZip, "-Checksum", $validHash, "-Version", "v1.2.3", "-Dest", $junctionChild, "-Force", "-Quiet")
    Assert-True ($script:LastExit -ne 0) "destination below a junction unexpectedly succeeded"
    Assert-Contains "crosses a reparse point" $script:LastOutput "junction-prefix error was not explicit"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $junctionRoot "nested\bin\atp.exe"))) "junction prefix wrote through to its target"
    Pass-Test "junction ancestors fail closed before destination creation"
} else {
    Write-Host "ok -- junction fixture unavailable on this Windows host: $junctionOutput"
}

$lockedDest = Join-Path $script:TestRoot "locked-target"
New-Item -ItemType Directory -Path $lockedDest | Out-Null
$lockedTarget = Join-Path $lockedDest "atp.exe"
[IO.File]::Copy($goodExe, $lockedTarget)
$lockedBefore = (Get-FileHash -LiteralPath $lockedTarget -Algorithm SHA256).Hash
$held = [IO.File]::Open($lockedTarget, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
try {
    Invoke-InstallerProcess @("-Offline", $validZip, "-Checksum", $validHash, "-Version", "v1.2.3", "-Dest", $lockedDest, "-Force", "-Quiet")
    Assert-True ($script:LastExit -ne 0) "replacement of a locked binary unexpectedly succeeded"
} finally {
    $held.Dispose()
}
Assert-True ((Get-FileHash -LiteralPath $lockedTarget -Algorithm SHA256).Hash -ceq $lockedBefore) "replacement failure changed the locked binary"
Pass-Test "replacement failure preserves the existing binary"

Assert-True (Test-AtpPathContains -PathValue "C:\Tools;C:\Users\Test\.local\bin" -Candidate "c:\users\test\.LOCAL\BIN\") "PATH matching was not case-insensitive and slash-stable"
Assert-True (-not (Test-AtpPathContains -PathValue "C:\Tools;C:\Other" -Candidate "C:\Users\Test\.local\bin")) "PATH helper reported a false match"
Invoke-InstallerProcess @("-Help")
Assert-True ($script:LastExit -eq 0) "Help exited non-zero"
Assert-Contains "native Windows x64" $script:LastOutput "Help output is missing the platform contract"
Pass-Test "EasyMode PATH matching is idempotent and Help is side-effect free"

Complete-TestRun
Write-Host "PASS: $($script:PassCount) PowerShell installer regression groups"
