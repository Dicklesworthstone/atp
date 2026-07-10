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
    if (Get-Command Remove-AtpDirectoryTreeStrict -ErrorAction SilentlyContinue) {
        Remove-AtpDirectoryTreeStrict $script:TestRoot
    } elseif (Test-Path -LiteralPath $script:TestRoot) {
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

function Assert-NotContains {
    param([string]$Needle, [string]$Haystack, [string]$Message)
    if ($Haystack.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { Fail-Test $Message }
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

function Get-AtpTempInstallRoots {
    $temp = [IO.Path]::GetTempPath()
    if (-not [IO.Directory]::Exists($temp)) { return @() }
    return @([IO.Directory]::GetDirectories($temp, "atp-install-*", [IO.SearchOption]::TopDirectoryOnly))
}

function Get-AtpTempExecutionCopies {
    $temp = [IO.Path]::GetTempPath()
    if (-not [IO.Directory]::Exists($temp)) { return @() }
    return @([IO.Directory]::GetFiles($temp, "atp-exec-*.exe", [IO.SearchOption]::TopDirectoryOnly))
}

function Invoke-InstallerProcess {
    param(
        [string[]]$Arguments,
        [string]$Engine = ""
    )
    $enginePath = if ([string]::IsNullOrWhiteSpace($Engine)) { Get-CurrentPowerShellPath } else { $Engine }
    $beforeTempRoots = @(Get-AtpTempInstallRoots)
    $beforeExecutionCopies = @(Get-AtpTempExecutionCopies)
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& $enginePath -NoProfile -ExecutionPolicy Bypass -File $script:Installer @Arguments 2>&1)
        $script:LastExit = $LASTEXITCODE
        $script:LastOutput = ($output | ForEach-Object { [string]$_ }) -join "`n"
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    $newTempRoots = @(Get-AtpTempInstallRoots | Where-Object { $beforeTempRoots -notcontains $_ })
    if ($newTempRoots.Count -ne 0) {
        Fail-Test "installer left temporary roots behind: $($newTempRoots -join ', ')"
    }
    $newExecutionCopies = @(Get-AtpTempExecutionCopies | Where-Object { $beforeExecutionCopies -notcontains $_ })
    if ($newExecutionCopies.Count -ne 0) {
        Fail-Test "installer left long-path execution copies behind: $($newExecutionCopies -join ', ')"
    }
}

function Get-TestPowerShellEngines {
    $engines = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $current = Get-CurrentPowerShellPath
    $engines[$current] = "current"
    $windowsPowerShell = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) { $engines[$windowsPowerShell] = "powershell-5.1" }
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($null -ne $pwsh) { $engines[$pwsh.Source] = "pwsh" }
    return $engines
}

function Invoke-EncodedPowerShell {
    param([string]$Engine, [string]$Script)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& $Engine -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1)
        return [PSCustomObject]@{
            ExitCode = $LASTEXITCODE
            Output = (($output | ForEach-Object { [string]$_ }) -join "`n")
        }
    } finally {
        $ErrorActionPreference = $oldPreference
    }
}

function Invoke-PowerShellFile {
    param([string]$Engine, [string]$Path)
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& $Engine -NoProfile -ExecutionPolicy Bypass -File $Path 2>&1)
        return [PSCustomObject]@{
            ExitCode = $LASTEXITCODE
            Output = (($output | ForEach-Object { [string]$_ }) -join "`n")
        }
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

function New-TestCSharpExecutable {
    param([string]$Path, [string]$Source)
    $sourcePath = "$Path.cs"
    [IO.File]::WriteAllText($sourcePath, $Source, (New-Object Text.UTF8Encoding($false)))
    $compiler = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
        throw "64-bit .NET Framework C# compiler not found: $compiler"
    }
    $compilerOutput = @(& $compiler /nologo /target:exe /platform:x64 "/out:$Path" $sourcePath 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "fixture C# compilation failed: $($compilerOutput -join "`n")"
    }
}

function New-MinisignFixtureExecutable {
    param([string]$Path)
    $className = "MinisignFixture" + [Guid]::NewGuid().ToString("N")
    $source = @"
using System;
using System.IO;
using System.Security.Cryptography;
using System.Threading;
public static class $className {
    private static string Sha256Hex(string path) {
        using (FileStream stream = File.OpenRead(path))
        using (SHA256 sha = SHA256.Create()) {
            byte[] digest = sha.ComputeHash(stream);
            return BitConverter.ToString(digest).Replace("-", "").ToLowerInvariant();
        }
    }

    public static int Main(string[] args) {
        string archive = null;
        string signature = null;
        string publicKey = null;
        for (int i = 0; i + 1 < args.Length; i++) {
            if (args[i] == "-Vm") archive = args[++i];
            else if (args[i] == "-x") signature = args[++i];
            else if (args[i] == "-P") publicKey = args[++i];
        }
        bool validInputs = archive != null && File.Exists(archive) &&
            signature != null && File.Exists(signature) &&
            publicKey == "RWTQGPeLsnm9G7VFdFWkkcRi3wJK/PqsYxWC+oLNN74W9IjBxRU1Xu70";
        if (validInputs) {
            string mode = File.ReadAllText(signature).Trim();
            if (mode == "hang") {
                Console.Out.Write("MINISIGN_HANG_STDOUT");
                Console.Error.Write("MINISIGN_HANG_STDERR");
                Console.Out.Flush();
                Console.Error.Flush();
                Thread.Sleep(60000);
                return 0;
            }
            string archiveHash = Sha256Hex(archive);
            if (mode == "flood-valid:" + archiveHash) {
                string stdoutChunk = new string('o', 4096);
                string stderrChunk = new string('e', 4096);
                for (int i = 0; i < 512; i++) Console.Out.Write(stdoutChunk);
                Console.Out.Write("MINISIGN_STDOUT_END");
                for (int i = 0; i < 512; i++) Console.Error.Write(stderrChunk);
                Console.Error.Write("MINISIGN_STDERR_END");
                return 0;
            }
            if (mode == "valid:" + archiveHash) return 0;
        }
        Console.Error.WriteLine("fixture signature rejected");
        return 42;
    }
}
"@
    New-TestCSharpExecutable -Path $Path -Source $source
}

function Write-MinisignFixtureSignature {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Archive,
        [ValidateSet("valid", "flood-valid")][string]$Mode = "valid"
    )
    $archiveHash = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($Path, "$Mode`:$archiveHash", (New-Object Text.UTF8Encoding($false)))
}

function New-PostReplaceFailureFixtureExecutable {
    param([string]$Path)
    $className = "PostReplaceFailureFixture" + [Guid]::NewGuid().ToString("N")
    $source = @"
using System;
using System.IO;
using System.Reflection;
public static class $className {
    public static int Main(string[] args) {
        string name = Path.GetFileName(Assembly.GetExecutingAssembly().Location);
        bool staged = name.StartsWith(".atp-install-", StringComparison.Ordinal);
        if (args.Length == 1 && args[0] == "--version") {
            if (staged) { Console.WriteLine("atp 1.2.3"); return 0; }
            Console.Error.WriteLine("post-replace validation failure");
            return 41;
        }
        if (args.Length == 1 && args[0] == "rq-keygen" && staged) {
            Console.WriteLine("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
            return 0;
        }
        return 42;
    }
}
"@
    New-TestCSharpExecutable -Path $Path -Source $source
}

function New-ProcessIoFixtureExecutable {
    param([string]$Path)
    $className = "ProcessIoFixture" + [Guid]::NewGuid().ToString("N")
    $source = @"
using System;
using System.Threading;
public static class $className {
    public static int Main(string[] args) {
        if (args.Length != 1) return 2;
        if (args[0] == "hang") {
            Thread.Sleep(60000);
            return 0;
        }
        if (args[0] == "flood") {
            string stdoutChunk = new string('o', 4096);
            string stderrChunk = new string('e', 4096);
            for (int i = 0; i < 512; i++) Console.Out.Write(stdoutChunk);
            Console.Out.Write("ATP_STDOUT_END");
            for (int i = 0; i < 512; i++) Console.Error.Write(stderrChunk);
            Console.Error.Write("ATP_STDERR_END");
            return 0;
        }
        return 3;
    }
}
"@
    New-TestCSharpExecutable -Path $Path -Source $source
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

function Assert-NoInstallerResidue {
    param([string]$Directory, [string]$Message)
    if (-not (Test-AtpDirectoryExists $Directory)) { return }
    $residue = @([IO.Directory]::GetFiles(
        (ConvertTo-AtpExtendedPath $Directory),
        ".atp-*",
        [IO.SearchOption]::TopDirectoryOnly
    ) | Where-Object {
        $name = [IO.Path]::GetFileName($_)
        $name -eq ".atp-install.lock" -or
            $name -like ".atp-install-*.exe" -or
            $name -like ".atp-backup-*.exe" -or
            $name -like ".atp-failed-*.exe"
    })
    Assert-True ($residue.Count -eq 0) "$Message (residue: $($residue -join ', '))"
}

function New-LongTestPath {
    param([string]$Root, [string]$Leaf)
    $path = Join-AtpPath $Root $Leaf
    $index = 0
    while ($path.Length -lt 285) {
        $path = Join-AtpPath $path ("segment-{0:D2}-{1}" -f $index, ("x" * 30))
        $index++
    }
    return $path
}

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
Assert-True (Test-AtpLegacyUnsignedRelease "v0.3.7") "v0.3.7 was not classified as a legacy unsigned release"
Assert-True (Test-AtpLegacyUnsignedRelease "0.3.0") "bare legacy version was not classified correctly"
Assert-True (-not (Test-AtpLegacyUnsignedRelease "v0.3.8")) "v0.3.8 must be inside the fail-closed signed-release policy"
Assert-True (-not (Test-AtpLegacyUnsignedRelease "v1.0.0")) "future major releases must be inside the signed-release policy"
Assert-Throws { Test-AtpLegacyUnsignedRelease "v0.3.7-beta" } "expected vX.Y.Z" "prerelease syntax must not enter the legacy exception"
Assert-Throws { Test-AtpLegacyUnsignedRelease "v2147483648.0.0" } "numeric components supported by Windows" "unrepresentable versions must fail closed"
Assert-True ((Get-AtpArtifactUrl "v1.2.3") -ceq "https://github.com/Dicklesworthstone/atp/releases/download/v1.2.3/atp-x86_64-pc-windows-msvc.zip") "artifact URL mismatch"
Pass-Test "Windows x64, signed-release threshold, malformed-version, and exact artifact URL contracts"

$lockHandoffDirectory = Join-Path $script:TestRoot "lock-handoff"
New-AtpDirectory $lockHandoffDirectory
$lockHandoffPath = Join-AtpPath $lockHandoffDirectory ".atp-install.lock"
$firstLock = $null
$secondLock = $null
try {
    $firstLock = Open-AtpInstallLock $lockHandoffDirectory
    Assert-True (Test-AtpPathEntryExists $lockHandoffPath) "first installer lock was not visible while owned"
    Assert-Throws {
        $unexpectedLock = $null
        try { $unexpectedLock = Open-AtpInstallLock $lockHandoffDirectory } finally {
            if ($null -ne $unexpectedLock) { $unexpectedLock.Dispose() }
        }
    } "Another atp installer" "a competing installer acquired an owned lock"
    $firstLock.Dispose()
    $firstLock = $null
    Assert-True (-not (Test-AtpPathEntryExists $lockHandoffPath)) "delete-on-close did not remove the first owner's lock"

    $secondLock = Open-AtpInstallLock $lockHandoffDirectory
    Assert-True (Test-AtpPathEntryExists $lockHandoffPath) "second installer did not acquire the lock after handoff"
    $secondLock.Dispose()
    $secondLock = $null
} finally {
    if ($null -ne $secondLock) { $secondLock.Dispose() }
    if ($null -ne $firstLock) { $firstLock.Dispose() }
}
Assert-True (-not (Test-AtpPathEntryExists $lockHandoffPath)) "lock handoff left a stale lock path"
Pass-Test "installer lock ownership is exclusive, delete-on-close, and immediately reusable after handoff"

$savedProtocol = [Net.ServicePointManager]::SecurityProtocol
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::SystemDefault
    Enable-AtpTls12
    Assert-True (([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12) -ne 0) "TLS 1.2 was not enabled"
} finally {
    [Net.ServicePointManager]::SecurityProtocol = $savedProtocol
}
$readmeText = [IO.File]::ReadAllText((Join-Path $script:RepoRoot "README.md"))
Assert-Contains "Tls12; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Dicklesworthstone/atp/main/install.ps1)))" $readmeText "README bootstrap does not enable TLS 1.2 before fetching install.ps1 in a child scope"
Pass-Test "PowerShell 5.1 bootstrap enables TLS 1.2 before fetching the installer"

$engineMap = Get-TestPowerShellEngines
$installerLiteral = $script:Installer.Replace("'", "''")
$scriptBlockWrapper = Join-Path $script:TestRoot "scriptblock-wrapper.ps1"
$scriptBlockWrapperText = @"
`$ErrorActionPreference = 'Stop'
`$env:PROCESSOR_ARCHITEW6432 = ''
`$env:PROCESSOR_ARCHITECTURE = 'ARM64'
try {
    `$content = [IO.File]::ReadAllText('$installerLiteral')
    & ([scriptblock]::Create(`$content))
    Write-Output 'ATP_UNEXPECTED_SUCCESS'
    exit 91
} catch {
    Write-Output ('ATP_CAUGHT:' + `$_.Exception.Message)
}
Write-Output 'ATP_HOST_SURVIVED'
exit 0
"@
[IO.File]::WriteAllText($scriptBlockWrapper, $scriptBlockWrapperText, (New-Object Text.UTF8Encoding($false)))
foreach ($entry in $engineMap.GetEnumerator()) {
    $hostSafetyScript = @"
`$ErrorActionPreference = 'Stop'
`$env:PROCESSOR_ARCHITEW6432 = ''
`$env:PROCESSOR_ARCHITECTURE = 'ARM64'
try {
    Get-Content -LiteralPath '$installerLiteral' -Raw | Invoke-Expression
    Write-Output 'ATP_UNEXPECTED_SUCCESS'
    exit 91
} catch {
    Write-Output ('ATP_CAUGHT:' + `$_.Exception.Message)
}
Write-Output 'ATP_HOST_SURVIVED'
exit 0
"@
    $hostSafety = Invoke-EncodedPowerShell -Engine $entry.Key -Script $hostSafetyScript
    Assert-True ($hostSafety.ExitCode -eq 0) "$($entry.Value) host was terminated by an irm|iex installer failure"
    Assert-Contains "ATP_CAUGHT:" $hostSafety.Output "$($entry.Value) did not surface the installer failure as a catchable error"
    Assert-Contains "Unsupported Windows architecture 'ARM64'" $hostSafety.Output "$($entry.Value) irm|iex failed before architecture validation"
    Assert-Contains "ATP_HOST_SURVIVED" $hostSafety.Output "$($entry.Value) did not continue after a caught installer failure"
    Assert-True ($hostSafety.Output.IndexOf("ATP_UNEXPECTED_SUCCESS", [StringComparison]::Ordinal) -lt 0) "$($entry.Value) invalid architecture unexpectedly succeeded"

    $wrapperSafety = Invoke-PowerShellFile -Engine $entry.Key -Path $scriptBlockWrapper
    Assert-True ($wrapperSafety.ExitCode -eq 0) "$($entry.Value) wrapper host was terminated by a dynamically invoked installer failure"
    Assert-Contains "ATP_CAUGHT:" $wrapperSafety.Output "$($entry.Value) wrapper did not receive a catchable installer error"
    Assert-Contains "Unsupported Windows architecture 'ARM64'" $wrapperSafety.Output "$($entry.Value) dynamic invocation failed before architecture validation"
    Assert-Contains "ATP_HOST_SURVIVED" $wrapperSafety.Output "$($entry.Value) wrapper did not continue after the installer failure"
    Assert-True ($wrapperSafety.Output.IndexOf("ATP_UNEXPECTED_SUCCESS", [StringComparison]::Ordinal) -lt 0) "$($entry.Value) wrapper invalid architecture unexpectedly succeeded"

    $savedFileSafetyScript = @"
`$ErrorActionPreference = 'Stop'
`$env:PROCESSOR_ARCHITEW6432 = ''
`$env:PROCESSOR_ARCHITECTURE = 'ARM64'
try {
    & '$installerLiteral'
    Write-Output 'ATP_UNEXPECTED_SUCCESS'
    exit 91
} catch {
    Write-Output ('ATP_CAUGHT:' + `$_.Exception.Message)
}
Write-Output 'ATP_SAVED_FILE_HOST_SURVIVED'
exit 0
"@
    $savedFileSafety = Invoke-EncodedPowerShell -Engine $entry.Key -Script $savedFileSafetyScript
    Assert-True ($savedFileSafety.ExitCode -eq 0) "$($entry.Value) saved-file invocation terminated its PowerShell host"
    Assert-Contains "ATP_CAUGHT:" $savedFileSafety.Output "$($entry.Value) saved-file invocation did not surface a catchable error"
    Assert-Contains "Unsupported Windows architecture 'ARM64'" $savedFileSafety.Output "$($entry.Value) saved-file invocation failed before architecture validation"
    Assert-Contains "ATP_SAVED_FILE_HOST_SURVIVED" $savedFileSafety.Output "$($entry.Value) saved-file host did not continue after a caught installer failure"
    Assert-True ($savedFileSafety.Output.IndexOf("ATP_UNEXPECTED_SUCCESS", [StringComparison]::Ordinal) -lt 0) "$($entry.Value) saved-file invalid architecture unexpectedly succeeded"

    $loadOnlyScript = @"
`$ErrorActionPreference = 'Stop'
`$content = [IO.File]::ReadAllText('$installerLiteral')
& ([scriptblock]::Create(`$content)) -LoadFunctionsOnly
Write-Output 'ATP_LOAD_ONLY_SUCCESS'
"@
    $loadOnly = Invoke-EncodedPowerShell -Engine $entry.Key -Script $loadOnlyScript
    Assert-True ($loadOnly.ExitCode -eq 0) "$($entry.Value) dynamic load-only invocation failed"
    Assert-Contains "ATP_LOAD_ONLY_SUCCESS" $loadOnly.Output "$($entry.Value) dynamic load-only invocation did not complete"

    $scopeSafetyScript = @"
`$ErrorActionPreference = 'Continue'
Set-StrictMode -Off
`$env:PROCESSOR_ARCHITEW6432 = ''
`$env:PROCESSOR_ARCHITECTURE = 'ARM64'
try {
    `$content = [IO.File]::ReadAllText('$installerLiteral')
    & ([scriptblock]::Create(`$content))
    throw 'ATP_UNEXPECTED_SUCCESS'
} catch {
    if (`$_.Exception.Message.IndexOf("Unsupported Windows architecture 'ARM64'", [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw
    }
}
if (`$ErrorActionPreference -cne 'Continue') { throw 'ATP_ERROR_PREFERENCE_LEAKED' }
try { `$null = `$AtpUndefinedStrictModeProbe } catch { throw 'ATP_STRICT_MODE_LEAKED' }
if (`$null -ne (Get-Command Invoke-AtpInstaller -ErrorAction SilentlyContinue)) { throw 'ATP_COMMAND_LEAKED' }
Write-Output 'ATP_CHILD_SCOPE_CLEAN'
"@
    $scopeSafety = Invoke-EncodedPowerShell -Engine $entry.Key -Script $scopeSafetyScript
    Assert-True ($scopeSafety.ExitCode -eq 0) "$($entry.Value) recommended child-scope invocation changed caller state"
    Assert-Contains "ATP_CHILD_SCOPE_CLEAN" $scopeSafety.Output "$($entry.Value) recommended child-scope invocation leaked state"
}
Pass-Test "installer failures are catchable and the recommended child scope preserves PowerShell host state"

function Invoke-RestMethod {
    param([string]$Uri, [int]$TimeoutSec, [hashtable]$Headers)
    if ($Uri -notlike "https://api.github.com/*/releases/latest") { throw "unexpected mocked URI: $Uri" }
    Assert-True ($TimeoutSec -eq $script:AtpWebTimeoutSeconds) "GitHub API call omitted the bounded timeout"
    return [PSCustomObject]@{ tag_name = "v1.2.3" }
}
try {
    Assert-True ((Get-AtpLatestVersionTag) -ceq "v1.2.3") "latest release tag did not resolve"
} finally {
    Remove-Item -LiteralPath Function:\Invoke-RestMethod
}

function Invoke-RestMethod {
    param([string]$Uri, [int]$TimeoutSec, [hashtable]$Headers)
    Assert-True ($TimeoutSec -eq $script:AtpWebTimeoutSeconds) "GitHub API fallback call omitted the bounded timeout"
    throw "fixture API rate limit"
}
function Invoke-WebRequest {
    param([string]$Uri, [switch]$UseBasicParsing, [int]$TimeoutSec, [hashtable]$Headers)
    if ($Uri -cne "https://github.com/Dicklesworthstone/atp/releases/latest") {
        throw "unexpected mocked redirect URI: $Uri"
    }
    Assert-True ($TimeoutSec -eq $script:AtpWebTimeoutSeconds) "GitHub redirect call omitted the bounded timeout"
    return [PSCustomObject]@{
        BaseResponse = [PSCustomObject]@{
            ResponseUri = [Uri]"https://github.com/Dicklesworthstone/atp/releases/tag/v2.3.4"
        }
    }
}
try {
    Assert-True ((Get-AtpLatestVersionTag) -ceq "v2.3.4") "latest release redirect fallback did not resolve"
} finally {
    Remove-Item -LiteralPath Function:\Invoke-RestMethod
    Remove-Item -LiteralPath Function:\Invoke-WebRequest
}
Pass-Test "latest-release resolution uses the API first and a stable redirect fallback on API failure"

$script:MockedWebTimeouts = New-Object System.Collections.Generic.List[int]
$script:MockedWebUris = New-Object System.Collections.Generic.List[string]
function Invoke-WebRequest {
    param(
        [string]$Uri,
        [string]$OutFile,
        [switch]$UseBasicParsing,
        [int]$TimeoutSec,
        [hashtable]$Headers
    )
    $script:MockedWebTimeouts.Add($TimeoutSec)
    $script:MockedWebUris.Add($Uri)
    if ($PSBoundParameters.ContainsKey("OutFile")) {
        [IO.File]::WriteAllText($OutFile, "download fixture")
        return [PSCustomObject]@{}
    }
    return [PSCustomObject]@{ Content = "manifest fixture" }
}
try {
    $mockArchive = Join-Path $script:TestRoot "mock-archive.zip"
    $mockSignature = Join-Path $script:TestRoot "mock-archive.zip.minisig"
    $artifactUri = "https://github.com/Dicklesworthstone/atp/releases/download/v1.2.3/atp-x86_64-pc-windows-msvc.zip"
    $manifestUri = "https://github.com/Dicklesworthstone/atp/releases/download/v1.2.3/SHA256SUMS"
    Invoke-AtpDownload -Uri $artifactUri -OutFile $mockArchive
    Invoke-AtpDownload -Uri "$artifactUri.minisig" -OutFile $mockSignature
    $mockManifest = Get-AtpRemoteText -Uri $manifestUri
    Assert-True (([IO.File]::ReadAllText($mockArchive)) -ceq "download fixture") "mock archive download did not complete"
    Assert-True (([IO.File]::ReadAllText($mockSignature)) -ceq "download fixture") "mock signature download did not complete"
    Assert-True ($mockManifest -ceq "manifest fixture") "mock manifest download did not return content"
    Assert-True ($script:MockedWebTimeouts.Count -eq 3) "release web timeout test did not observe all expected calls"
    Assert-True (@($script:MockedWebTimeouts | Where-Object { $_ -ne $script:AtpWebTimeoutSeconds }).Count -eq 0) "a release web call omitted the bounded timeout"
    Assert-True ($script:MockedWebUris.Contains($artifactUri)) "archive release call was not observed"
    Assert-True ($script:MockedWebUris.Contains("$artifactUri.minisig")) "signature release call was not observed"
    Assert-True ($script:MockedWebUris.Contains($manifestUri)) "manifest release call was not observed"
} finally {
    Remove-Item -LiteralPath Function:\Invoke-WebRequest
}
Pass-Test "archive, signature, and manifest web calls all use bounded timeouts"

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

$processIoExe = Join-Path $script:TestRoot "process-io-atp.exe"
New-ProcessIoFixtureExecutable -Path $processIoExe
$ioClock = [Diagnostics.Stopwatch]::StartNew()
$floodResult = Invoke-AtpExecutableCapture -Path $processIoExe -Arguments @("flood") -TimeoutMilliseconds 10000
$ioClock.Stop()
Assert-True ($floodResult.ExitCode -eq 0) "concurrent stdout/stderr fixture exited non-zero"
Assert-Contains "ATP_STDOUT_END" $floodResult.Output "concurrent output capture lost stdout"
Assert-Contains "ATP_STDERR_END" $floodResult.Output "concurrent output capture lost stderr"
Assert-True ($ioClock.ElapsedMilliseconds -lt 10000) "concurrent output capture exceeded its deadline"

$ioClock.Restart()
Assert-Throws {
    Invoke-AtpExecutableCapture -Path $processIoExe -Arguments @("hang") -TimeoutMilliseconds 250
} "timed out after 250 ms" "hung executable self-test must time out"
$ioClock.Stop()
Assert-True ($ioClock.ElapsedMilliseconds -lt 7000) "hung executable timeout did not remain bounded"
Start-Sleep -Milliseconds 100
$remainingIoProcesses = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($processIoExe)) -ErrorAction SilentlyContinue)
Assert-True ($remainingIoProcesses.Count -eq 0) "timed-out executable fixture was not terminated"
Pass-Test "executable self-tests drain stdout and stderr concurrently, time out, and terminate hung children"

$validZip = Join-Path $script:TestRoot "atp-x86_64-pc-windows-msvc.zip"
New-ValidZip -Path $validZip -Executable $goodExe
$minisignFixtureDir = Join-Path $script:TestRoot "minisign-fixture"
New-Item -ItemType Directory -Path $minisignFixtureDir | Out-Null
$minisignFixture = Join-Path $minisignFixtureDir "atp-test-minisign.exe"
$installerMinisignFixture = Join-Path $minisignFixtureDir "minisign.exe"
New-MinisignFixtureExecutable -Path $minisignFixture
[IO.File]::Copy($minisignFixture, $installerMinisignFixture)
$validSignature = Join-Path $script:TestRoot "valid.minisig"
$invalidSignature = Join-Path $script:TestRoot "invalid.minisig"
$floodSignature = Join-Path $script:TestRoot "flood-valid.minisig"
$hungSignature = Join-Path $script:TestRoot "hung.minisig"
Write-MinisignFixtureSignature -Path $validSignature -Archive $validZip
[IO.File]::WriteAllText($invalidSignature, "invalid")
Write-MinisignFixtureSignature -Path $floodSignature -Archive $validZip -Mode "flood-valid"
[IO.File]::WriteAllText($hungSignature, "hang")
Assert-True (Confirm-AtpMinisignSignature -Archive $validZip -Signature $validSignature -MinisignPath $minisignFixture) "valid minisign fixture was rejected"
Assert-Throws { Confirm-AtpMinisignSignature -Archive $validZip -Signature $invalidSignature -MinisignPath $minisignFixture } "verification FAILED" "invalid minisign fixture must fail closed"
$minisignClock = [Diagnostics.Stopwatch]::StartNew()
Assert-True (Confirm-AtpMinisignSignature -Archive $validZip -Signature $floodSignature -MinisignPath $minisignFixture -TimeoutMilliseconds 10000) "high-output minisign fixture was rejected or blocked on redirected pipes"
Assert-True ($minisignClock.ElapsedMilliseconds -lt 10000) "high-output minisign verification exceeded its deadline"
$minisignClock.Restart()
Assert-Throws {
    Confirm-AtpMinisignSignature -Archive $validZip -Signature $hungSignature -MinisignPath $minisignFixture -TimeoutMilliseconds 250
} "minisign signature verification timed out after 250 ms" "hung minisign verification must time out"
$minisignClock.Stop()
Assert-True ($minisignClock.ElapsedMilliseconds -lt 7000) "hung minisign timeout did not remain bounded"
Start-Sleep -Milliseconds 100
$remainingMinisignProcesses = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($minisignFixture)) -ErrorAction SilentlyContinue)
Assert-True ($remainingMinisignProcesses.Count -eq 0) "timed-out minisign fixture was not terminated"
$signatureDirectory = Join-Path $script:TestRoot "signature-directory"
New-Item -ItemType Directory -Path $signatureDirectory | Out-Null
Assert-Throws { Confirm-AtpMinisignSignature -Archive $validZip -Signature $signatureDirectory -MinisignPath $minisignFixture } "regular file" "signature directories must fail closed"
Assert-Throws { Confirm-AtpMinisignSignature -Archive $validZip -Signature $validSignature -MinisignPath "" } "minisign.exe is required" "missing minisign.exe must fail closed"
Assert-Throws { Confirm-AtpMinisignSignature -Archive $validZip -Signature (Join-Path $script:TestRoot "missing.minisig") -MinisignPath $minisignFixture } "signature not found" "missing minisign signature must fail closed"
Pass-Test "minisign uses the embedded release key, drains both pipes, rejects invalid signatures, and terminates hung verification"

$onlineSignature = Join-Path $script:TestRoot "online.minisig"
$modernOnlineVersion = "v0.3.8"
$legacyOnlineVersion = "v0.3.7"
$modernOnlineArtifactUrl = Get-AtpArtifactUrl $modernOnlineVersion
$legacyOnlineArtifactUrl = Get-AtpArtifactUrl $legacyOnlineVersion
$tamperedOnlineZip = Join-Path $script:TestRoot "tampered-online-atp-x86_64-pc-windows-msvc.zip"
[IO.File]::Copy($validZip, $tamperedOnlineZip)
$tamperedStream = [IO.File]::Open($tamperedOnlineZip, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $tamperedStream.WriteByte(0x42) } finally { $tamperedStream.Dispose() }
$tamperedOnlineHash = Get-AtpFileSha256 $tamperedOnlineZip
Assert-AtpFileHash -Path $tamperedOnlineZip -Expected $tamperedOnlineHash

$script:OriginalInvokeAtpDownload = (Get-Item Function:\Invoke-AtpDownload).ScriptBlock
$script:OnlineArtifactUrl = $modernOnlineArtifactUrl
$script:OnlineSignatureMode = "valid"
$script:OnlineSignedArchive = $validZip
$script:OnlineDownloadCount = 0
function Invoke-AtpDownload {
    param([string]$Uri, [string]$OutFile)
    $script:OnlineDownloadCount++
    if ($Uri -cne "$($script:OnlineArtifactUrl).minisig") { throw "unexpected online signature URI: $Uri" }
    switch ($script:OnlineSignatureMode) {
        "valid" { Write-MinisignFixtureSignature -Path $OutFile -Archive $script:OnlineSignedArchive; return }
        "invalid" { [IO.File]::WriteAllText($OutFile, "invalid"); return }
        "missing" {
            $missing = New-Object Exception("fixture signature download returned HTTP 404")
            $missing.Data["AtpHttpStatusCode"] = 404
            throw $missing
        }
        "server-error" {
            [IO.File]::WriteAllText($OutFile, "partial")
            $failure = New-Object Exception("fixture signature download returned HTTP 503")
            $failure.Data["AtpHttpStatusCode"] = 503
            throw $failure
        }
        "inconclusive" {
            [IO.File]::WriteAllText($OutFile, "partial")
            throw "fixture signature download failed without an HTTP response"
        }
        default { throw "unexpected online signature mode: $($script:OnlineSignatureMode)" }
    }
}
$savedOnlinePath = $env:Path
try {
    $env:Path = "$minisignFixtureDir;$savedOnlinePath"
    $onlineSuccessOutput = @(& {
        $verified = Confirm-AtpReleaseAuthenticity -Archive $validZip -Signature $onlineSignature -ArtifactUrl $modernOnlineArtifactUrl -VersionTag $modernOnlineVersion
        if (-not $verified) { throw "online signature success did not authenticate" }
    } 6>&1) | ForEach-Object { [string]$_ }
    Assert-Contains "minisign signature verified" ($onlineSuccessOutput -join "`n") "online success emitted no real minisign marker"
    Assert-NotContains "UNAUTHENTICATED LEGACY RELEASE" ($onlineSuccessOutput -join "`n") "authenticated modern release emitted a legacy downgrade warning"
    Pass-Test "modern online release downloads and verifies its required signature"

    if (Test-AtpFileExists $onlineSignature) { Remove-AtpFileStrict $onlineSignature }
    $script:OnlineArtifactUrl = $legacyOnlineArtifactUrl
    $legacySignedOutput = @(& {
        $verified = Confirm-AtpReleaseAuthenticity -Archive $validZip -Signature $onlineSignature -ArtifactUrl $legacyOnlineArtifactUrl -VersionTag $legacyOnlineVersion
        if (-not $verified) { throw "signed legacy release did not authenticate" }
    } 6>&1) | ForEach-Object { [string]$_ }
    $legacySignedText = $legacySignedOutput -join "`n"
    Assert-Contains "minisign signature verified" $legacySignedText "signed legacy release emitted no real verification marker"
    Assert-NotContains "UNAUTHENTICATED LEGACY RELEASE" $legacySignedText "signed legacy release emitted an unauthenticated warning"
    Pass-Test "available legacy signature is verified and emits only the real success marker"

    if (Test-AtpFileExists $onlineSignature) { Remove-AtpFileStrict $onlineSignature }
    $env:Path = "$env:SystemRoot\System32;$env:SystemRoot"
    $downloadsBeforeLegacyMissingTool = $script:OnlineDownloadCount
    Assert-Throws {
        Confirm-AtpReleaseAuthenticity -Archive $validZip -Signature $onlineSignature -ArtifactUrl $legacyOnlineArtifactUrl -VersionTag $legacyOnlineVersion
    } "minisign.exe is required" "a published legacy signature without a verifier must fail closed"
    Assert-True ($script:OnlineDownloadCount -eq ($downloadsBeforeLegacyMissingTool + 1)) "legacy missing-tool path did not check for a published signature first"
    Assert-True (Test-AtpFileExists $onlineSignature) "legacy missing-tool path did not retain evidence that a signature was published"
    Remove-AtpFileStrict $onlineSignature
    Pass-Test "published legacy signature requires a verifier and cannot downgrade"

    $script:OnlineSignatureMode = "missing"
    $legacyMissingSignatureOutput = @(& {
        $verified = Confirm-AtpReleaseAuthenticity -Archive $validZip -Signature $onlineSignature -ArtifactUrl $legacyOnlineArtifactUrl -VersionTag $legacyOnlineVersion
        if ($verified) { throw "legacy missing-signature path reported authentication" }
    } 6>&1) | ForEach-Object { [string]$_ }
    $legacyMissingSignatureText = $legacyMissingSignatureOutput -join "`n"
    Assert-Contains "UNAUTHENTICATED LEGACY RELEASE v0.3.7" $legacyMissingSignatureText "legacy missing-signature path emitted no explicit unauthenticated warning"
    Assert-Contains "returned HTTP 404" $legacyMissingSignatureText "legacy missing-signature warning omitted its confirmed HTTP status"
    Assert-NotContains "minisign signature verified" $legacyMissingSignatureText "legacy missing-signature path emitted a false verification marker"
    Assert-True (-not (Test-AtpFileExists $onlineSignature)) "legacy missing-signature path left a partial file"
    Pass-Test "legacy online release permits checksum-only installation only after a confirmed signature 404"

    $script:OnlineSignatureMode = "server-error"
    Assert-Throws {
        Confirm-AtpReleaseAuthenticity -Archive $validZip -Signature $onlineSignature -ArtifactUrl $legacyOnlineArtifactUrl -VersionTag $legacyOnlineVersion
    } "HTTP 503" "a legacy signature server error must fail closed"
    Assert-True (-not (Test-AtpFileExists $onlineSignature)) "legacy HTTP 503 failure left a partial signature"

    $script:OnlineSignatureMode = "inconclusive"
    Assert-Throws {
        Confirm-AtpReleaseAuthenticity -Archive $validZip -Signature $onlineSignature -ArtifactUrl $legacyOnlineArtifactUrl -VersionTag $legacyOnlineVersion
    } "HTTP unknown" "an inconclusive legacy signature failure must fail closed"
    Assert-True (-not (Test-AtpFileExists $onlineSignature)) "inconclusive legacy failure left a partial signature"
    Pass-Test "legacy non-404 and inconclusive signature failures cannot downgrade"

    $env:Path = "$minisignFixtureDir;$savedOnlinePath"
    $script:OnlineSignatureMode = "invalid"
    Assert-Throws {
        Confirm-AtpReleaseAuthenticity -Archive $validZip -Signature $onlineSignature -ArtifactUrl $legacyOnlineArtifactUrl -VersionTag $legacyOnlineVersion
    } "verification FAILED" "an available invalid legacy signature must fail closed"
    Pass-Test "available invalid legacy signature cannot downgrade to checksum-only installation"

    if (Test-AtpFileExists $onlineSignature) { Remove-AtpFileStrict $onlineSignature }
    $script:OnlineArtifactUrl = $modernOnlineArtifactUrl
    $script:OnlineSignatureMode = "valid"
    $env:Path = "$env:SystemRoot\System32;$env:SystemRoot"
    $downloadsBeforeModernMissingTool = $script:OnlineDownloadCount
    Assert-Throws {
        Confirm-AtpReleaseAuthenticity -Archive $validZip -Signature $onlineSignature -ArtifactUrl $modernOnlineArtifactUrl -VersionTag $modernOnlineVersion
    } "minisign.exe is required" "modern online install without minisign.exe must fail closed"
    Assert-True ($script:OnlineDownloadCount -eq ($downloadsBeforeModernMissingTool + 1)) "modern missing-tool path did not retrieve the required signature"
    Assert-True (Test-AtpFileExists $onlineSignature) "modern missing-tool path did not prove that a signature was published"
    Remove-AtpFileStrict $onlineSignature
    Pass-Test "v0.3.8 boundary requires a verifier for its published signature"

    $env:Path = "$minisignFixtureDir;$savedOnlinePath"
    $script:OnlineSignatureMode = "missing"
    Assert-Throws {
        Confirm-AtpReleaseAuthenticity -Archive $validZip -Signature $onlineSignature -ArtifactUrl $modernOnlineArtifactUrl -VersionTag $modernOnlineVersion
    } "Failed to download required minisign signature" "missing modern online signature must fail closed"
    Assert-True (-not (Test-AtpFileExists $onlineSignature)) "failed signature download left a partial file"
    Pass-Test "modern online install fails closed when the required signature cannot be downloaded"

    $script:OnlineSignatureMode = "valid"
    $script:OnlineSignedArchive = $validZip
    Assert-Throws {
        Confirm-AtpReleaseAuthenticity -Archive $tamperedOnlineZip -Signature $onlineSignature -ArtifactUrl $modernOnlineArtifactUrl -VersionTag $modernOnlineVersion
    } "verification FAILED" "tampered archive with its matching SHA-256 must still fail publisher authentication"
    Pass-Test "online publisher authentication rejects a tampered archive even with a matching checksum"

    if (Test-AtpFileExists $onlineSignature) { Remove-AtpFileStrict $onlineSignature }
    $script:OnlineSignatureMode = "invalid"
    Assert-Throws {
        Confirm-AtpReleaseAuthenticity -Archive $validZip -Signature $onlineSignature -ArtifactUrl $modernOnlineArtifactUrl -VersionTag $modernOnlineVersion
    } "verification FAILED" "tampered online signature must fail closed"
    Pass-Test "online publisher authentication rejects a tampered signature"

    if (Test-AtpFileExists $onlineSignature) { Remove-AtpFileStrict $onlineSignature }
    $env:Path = "$env:SystemRoot\System32;$env:SystemRoot"
    $downloadsBeforeBypass = $script:OnlineDownloadCount
    $onlineBypassOutput = @(& {
        $verified = Confirm-AtpReleaseAuthenticity -Archive $validZip -Signature $onlineSignature -ArtifactUrl $modernOnlineArtifactUrl -VersionTag $modernOnlineVersion -NoVerify
        if ($verified) { throw "explicit bypass reported an authenticated result" }
    } 6>&1) | ForEach-Object { [string]$_ }
    $onlineBypassText = $onlineBypassOutput -join "`n"
    Assert-Contains "explicit -NoVerify" $onlineBypassText "online bypass did not emit an explicit warning"
    Assert-NotContains "minisign signature verified" $onlineBypassText "online bypass emitted a false signature success marker"
    Assert-True ($script:OnlineDownloadCount -eq $downloadsBeforeBypass) "online bypass downloaded a signature"
    Pass-Test "explicit online -NoVerify bypass skips only publisher authentication and emits no success marker"
} finally {
    $env:Path = $savedOnlinePath
    Set-Item -LiteralPath Function:\Invoke-AtpDownload -Value $script:OriginalInvokeAtpDownload
    if (Test-AtpFileExists $onlineSignature) { Remove-AtpFileStrict $onlineSignature }
}

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
Invoke-InstallerProcess @("-Offline", $validZip, "-Checksum", $validHash, "-Version", "v1.2.3", "-Dest", $installDest, "-Verify", "-NoVerify", "-Force", "-Quiet")
Assert-True ($script:LastExit -eq 0) "explicitly bypassed offline installer failed"
$installedExe = Join-Path $installDest "atp.exe"
Assert-True (Test-Path -LiteralPath $installedExe -PathType Leaf) "explicitly bypassed offline installer did not create atp.exe"
$null = Test-AtpExecutable -Path $installedExe -ExpectedVersionTag "v1.2.3"
Assert-True ([string]::IsNullOrWhiteSpace($script:LastOutput)) "quiet install emitted non-error output"
Assert-NoInstallerResidue -Directory $installDest -Message "successful install left transactional files behind"
Pass-Test "explicit offline -NoVerify bypass keeps SHA-256 mandatory and succeeds quietly"

$missingChecksumDest = Join-Path $script:TestRoot "missing-checksum-bypass"
Invoke-InstallerProcess @("-Offline", $validZip, "-Version", "v1.2.3", "-Dest", $missingChecksumDest, "-NoVerify", "-Force", "-Quiet")
Assert-True ($script:LastExit -ne 0) "-NoVerify bypass allowed an offline install without SHA-256 material"
Assert-Contains "Offline install requires -Checksum" $script:LastOutput "bypass did not preserve mandatory SHA-256 diagnostics"
Assert-True (-not (Test-AtpFileExists (Join-Path $missingChecksumDest "atp.exe"))) "missing-checksum bypass installed a binary"
Pass-Test "offline -NoVerify bypass never bypasses mandatory SHA-256 verification"

$offlineSignature = "$validZip.minisig"
$savedPath = $env:Path
try {
    $env:Path = "$minisignFixtureDir;$savedPath"
    $missingSignatureDest = Join-Path $script:TestRoot "missing-offline-signature"
    Invoke-InstallerProcess @("-Offline", $validZip, "-Checksum", $validHash, "-Version", "v0.3.7", "-Dest", $missingSignatureDest, "-Verify", "-Force", "-Quiet")
    Assert-True ($script:LastExit -ne 0) "legacy-version offline verified install without a sibling signature unexpectedly succeeded"
    Assert-Contains "requires sibling minisign signature" $script:LastOutput "missing offline signature error was not explicit"
    Assert-True (-not (Test-AtpFileExists (Join-Path $missingSignatureDest "atp.exe"))) "missing offline signature installed a binary"
    Assert-NoInstallerResidue -Directory $missingSignatureDest -Message "missing-signature failure left installer residue"
} finally {
    $env:Path = $savedPath
}
Pass-Test "offline verified install requires a sibling minisign signature even for legacy versions"

Write-MinisignFixtureSignature -Path $offlineSignature -Archive $validZip
try {
    $env:Path = "$env:SystemRoot\System32;$env:SystemRoot"
    $missingToolDest = Join-Path $script:TestRoot "missing-offline-minisign"
    Invoke-InstallerProcess @("-Offline", $validZip, "-Checksum", $validHash, "-Version", "v0.3.7", "-Dest", $missingToolDest, "-Verify", "-Force", "-Quiet")
    Assert-True ($script:LastExit -ne 0) "legacy-version offline verified install without minisign.exe unexpectedly succeeded"
    Assert-Contains "minisign.exe is required" $script:LastOutput "missing minisign.exe error was not explicit"
    Assert-True (-not (Test-AtpFileExists (Join-Path $missingToolDest "atp.exe"))) "missing minisign.exe installed a binary"
    Assert-NoInstallerResidue -Directory $missingToolDest -Message "missing-minisign failure left installer residue"
} finally {
    $env:Path = $savedPath
    if (Test-AtpFileExists $offlineSignature) { Remove-AtpFileStrict $offlineSignature }
}
Pass-Test "offline verified install requires minisign.exe even for legacy versions"

$offlineBypassDest = Join-Path $script:TestRoot "explicit-offline-bypass"
try {
    $env:Path = "$env:SystemRoot\System32;$env:SystemRoot"
    Invoke-InstallerProcess @("-Offline", $validZip, "-Checksum", $validHash, "-Version", "v1.2.3", "-Dest", $offlineBypassDest, "-Verify", "-NoVerify", "-Force")
    Assert-True ($script:LastExit -eq 0) "explicit offline -NoVerify bypass failed"
    Assert-Contains "explicit -NoVerify" $script:LastOutput "offline bypass did not emit an explicit warning"
    Assert-NotContains "minisign signature verified" $script:LastOutput "offline bypass emitted a false signature success marker"
    Assert-True (Test-AtpFileExists (Join-Path $offlineBypassDest "atp.exe")) "offline bypass did not install the checksum-verified binary"
} finally {
    $env:Path = $savedPath
}
Pass-Test "explicit offline -NoVerify bypass is visible and never claims signature success"

$signedDest = Join-Path $script:TestRoot "signed-install"
try {
    $env:Path = "$minisignFixtureDir;$savedPath"
    Write-MinisignFixtureSignature -Path $offlineSignature -Archive $validZip
    Invoke-InstallerProcess @("-Offline", $validZip, "-Checksum", $validHash, "-Version", "v1.2.3", "-Dest", $signedDest, "-Verify", "-Force")
    Assert-True ($script:LastExit -eq 0) "offline install with a valid minisign signature failed"
    Assert-Contains "minisign signature verified" $script:LastOutput "offline signature success emitted no real verification marker"
    $signedInstalled = Join-Path $signedDest "atp.exe"
    $signedBefore = Get-AtpFileSha256 $signedInstalled

    [IO.File]::WriteAllText($offlineSignature, "invalid")
    Invoke-InstallerProcess @("-Offline", $validZip, "-Checksum", $validHash, "-Version", "v1.2.3", "-Dest", $signedDest, "-Verify", "-Force", "-Quiet")
    Assert-True ($script:LastExit -ne 0) "offline install with an invalid minisign signature unexpectedly succeeded"
    Assert-Contains "minisign signature verification FAILED" $script:LastOutput "invalid minisign error was not explicit"
    Assert-True ((Get-AtpFileSha256 $signedInstalled) -ceq $signedBefore) "invalid minisign signature changed the existing binary"
    Assert-NoInstallerResidue -Directory $signedDest -Message "minisign verification failure left installer residue"
} finally {
    $env:Path = $savedPath
    if (Test-Path -LiteralPath $offlineSignature -PathType Leaf) { [IO.File]::Delete($offlineSignature) }
}
Pass-Test "offline minisign verification is deterministic and preserves installs on signature failure"

$tamperedOfflineDir = Join-Path $script:TestRoot "tampered-offline"
New-AtpDirectory $tamperedOfflineDir
$tamperedOfflineZip = Join-AtpPath $tamperedOfflineDir "atp-x86_64-pc-windows-msvc.zip"
[IO.File]::Copy($validZip, $tamperedOfflineZip)
$tamperedOfflineStream = [IO.File]::Open($tamperedOfflineZip, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $tamperedOfflineStream.WriteByte(0x24) } finally { $tamperedOfflineStream.Dispose() }
$tamperedOfflineHash = Get-AtpFileSha256 $tamperedOfflineZip
Write-MinisignFixtureSignature -Path "$tamperedOfflineZip.minisig" -Archive $validZip
try {
    $env:Path = "$minisignFixtureDir;$savedPath"
    $tamperedOfflineDest = Join-Path $script:TestRoot "tampered-offline-dest"
    Invoke-InstallerProcess @("-Offline", $tamperedOfflineZip, "-Checksum", $tamperedOfflineHash, "-Version", "v1.2.3", "-Dest", $tamperedOfflineDest, "-Verify", "-Force", "-Quiet")
    Assert-True ($script:LastExit -ne 0) "tampered offline archive with matching SHA-256 unexpectedly succeeded"
    Assert-Contains "minisign signature verification FAILED" $script:LastOutput "tampered offline archive did not fail publisher authentication"
    Assert-True (-not (Test-AtpFileExists (Join-Path $tamperedOfflineDest "atp.exe"))) "tampered offline archive installed a binary"
    Assert-NoInstallerResidue -Directory $tamperedOfflineDest -Message "tampered archive failure left installer residue"
} finally {
    $env:Path = $savedPath
}
Pass-Test "offline publisher authentication rejects a tampered archive even with a matching checksum"

$replacementExe = Join-Path $script:TestRoot "replacement-atp.exe"
New-FixtureExecutable -Path $replacementExe -Version "1.2.3"
$replacementZip = Join-Path $script:TestRoot "replacement\atp-x86_64-pc-windows-msvc.zip"
New-Item -ItemType Directory -Path (Split-Path -Parent $replacementZip) | Out-Null
New-ValidZip -Path $replacementZip -Executable $replacementExe
$replacementHash = (Get-FileHash -LiteralPath $replacementZip -Algorithm SHA256).Hash
[IO.File]::SetAttributes($installedExe, ([IO.File]::GetAttributes($installedExe) -bor [IO.FileAttributes]::ReadOnly))
Invoke-InstallerProcess @("-Offline", $replacementZip, "-Checksum", $replacementHash, "-Version", "v1.2.3", "-Dest", $installDest, "-Verify", "-NoVerify", "-Force", "-Quiet")
Assert-True ($script:LastExit -eq 0) "upgrade over a readonly atp.exe failed"
Assert-True ((Get-AtpFileSha256 $installedExe) -ceq (Get-AtpFileSha256 $replacementExe)) "readonly upgrade did not install the replacement bytes"
Assert-True (((Get-AtpFileAttributes $installedExe) -band [IO.FileAttributes]::ReadOnly) -eq 0) "replacement atp.exe remained readonly"
Assert-NoInstallerResidue -Directory $installDest -Message "readonly upgrade left backup, stage, failed, or lock files behind"
Pass-Test "atomic upgrade replaces readonly atp.exe and strictly removes its readonly backup"

$rollbackDest = Join-Path $script:TestRoot "post-replace-rollback"
New-Item -ItemType Directory -Path $rollbackDest | Out-Null
$rollbackTarget = Join-Path $rollbackDest "atp.exe"
[IO.File]::Copy($goodExe, $rollbackTarget)
[IO.File]::SetAttributes($rollbackTarget, ([IO.File]::GetAttributes($rollbackTarget) -bor [IO.FileAttributes]::ReadOnly))
$rollbackBeforeHash = Get-AtpFileSha256 $rollbackTarget
$rollbackBeforeAttributes = Get-AtpFileAttributes $rollbackTarget
$postReplaceFailure = Join-Path $script:TestRoot "post-replace-failure.exe"
New-PostReplaceFailureFixtureExecutable -Path $postReplaceFailure
Assert-Throws {
    Install-AtpAtomically -Source $postReplaceFailure -Target $rollbackTarget -ExpectedVersionTag "v1.2.3"
} "invalid value" "post-File.Replace validation failure must roll back"
Assert-True ((Get-AtpFileSha256 $rollbackTarget) -ceq $rollbackBeforeHash) "post-replace rollback did not restore the original bytes"
Assert-True ((Get-AtpFileAttributes $rollbackTarget) -eq $rollbackBeforeAttributes) "post-replace rollback did not restore readonly attributes"
Assert-NoInstallerResidue -Directory $rollbackDest -Message "post-replace rollback left backup, stage, or failed files behind"
Pass-Test "post-File.Replace validation failure restores original bytes, readonly attributes, and zero residue"

$backupMetadataDest = Join-Path $script:TestRoot "backup-metadata-rollback"
New-Item -ItemType Directory -Path $backupMetadataDest | Out-Null
$backupMetadataTarget = Join-Path $backupMetadataDest "atp.exe"
[IO.File]::Copy($goodExe, $backupMetadataTarget)
[IO.File]::SetAttributes($backupMetadataTarget, ([IO.File]::GetAttributes($backupMetadataTarget) -bor [IO.FileAttributes]::ReadOnly))
$backupMetadataBeforeHash = Get-AtpFileSha256 $backupMetadataTarget
$backupMetadataBeforeAttributes = Get-AtpFileAttributes $backupMetadataTarget
$script:OriginalSetAtpFileAttributes = (Get-Item Function:\Set-AtpFileAttributes).ScriptBlock
$script:InjectBackupMetadataFailure = $true
function Set-AtpFileAttributes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][IO.FileAttributes]$Attributes
    )
    if ($script:InjectBackupMetadataFailure -and
        [IO.Path]::GetFileName($Path) -like ".atp-backup-*.exe") {
        $script:InjectBackupMetadataFailure = $false
        throw "injected backup metadata failure"
    }
    & $script:OriginalSetAtpFileAttributes -Path $Path -Attributes $Attributes
}
try {
    Assert-Throws {
        Install-AtpAtomically -Source $replacementExe -Target $backupMetadataTarget -ExpectedVersionTag "v1.2.3"
    } "injected backup metadata failure" "post-replace backup metadata failure must roll back"
} finally {
    Set-Item -LiteralPath Function:\Set-AtpFileAttributes -Value $script:OriginalSetAtpFileAttributes
}
Assert-True (-not $script:InjectBackupMetadataFailure) "backup metadata fault injection did not execute"
Assert-True ((Get-AtpFileSha256 $backupMetadataTarget) -ceq $backupMetadataBeforeHash) "backup metadata failure did not restore original bytes"
Assert-True ((Get-AtpFileAttributes $backupMetadataTarget) -eq $backupMetadataBeforeAttributes) "backup metadata failure did not restore original attributes"
Assert-NoInstallerResidue -Directory $backupMetadataDest -Message "backup metadata rollback left stage, backup, or failed files behind"
Pass-Test "post-File.Replace backup metadata failures restore original bytes, attributes, and zero residue"

foreach ($entry in $engineMap.GetEnumerator()) {
    $longRoot = New-LongTestPath -Root $script:TestRoot -Leaf ("long-path-{0}" -f $entry.Value)
    New-AtpDirectory $longRoot
    $longArchive = Join-AtpPath $longRoot "atp-x86_64-pc-windows-msvc.zip"
    [IO.File]::Copy((ConvertTo-AtpExtendedPath $validZip), (ConvertTo-AtpExtendedPath $longArchive), $false)
    [IO.File]::WriteAllText((ConvertTo-AtpExtendedPath "$longArchive.sha256"), $validHash, (New-Object Text.UTF8Encoding($false)))
    $longDest = Join-AtpPath $longRoot "destination\nested\bin"
    Invoke-InstallerProcess -Arguments @("-Offline", $longArchive, "-Version", "v1.2.3", "-Dest", $longDest, "-Verify", "-NoVerify", "-Force", "-Quiet") -Engine $entry.Key
    Assert-True ($script:LastExit -eq 0) "$($entry.Value) failed to install from and to paths longer than 260 characters"
    $longInstalled = Join-AtpPath $longDest "atp.exe"
    Assert-True (Test-AtpFileExists $longInstalled) "$($entry.Value) long-path install did not create atp.exe"
    $null = Test-AtpExecutable -Path $longInstalled -ExpectedVersionTag "v1.2.3"
    Assert-True (@(Get-AtpTempExecutionCopies).Count -eq 0) "$($entry.Value) long-path verification left execution copies behind"
    Assert-NoInstallerResidue -Directory $longDest -Message "$($entry.Value) long-path install left transactional files behind"
}
Pass-Test "PowerShell 5.1 and pwsh support verified long archive and destination paths"

$before = (Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash
Invoke-InstallerProcess @("-Offline", $validZip, "-Checksum", ("f" * 64), "-Version", "v1.2.3", "-Dest", $installDest, "-Force", "-Quiet")
Assert-True ($script:LastExit -ne 0) "wrong checksum unexpectedly succeeded"
Assert-Contains "Checksum verification failed" $script:LastOutput "wrong checksum error was not explicit"
Assert-True ((Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash -ceq $before) "wrong checksum changed the existing binary"
Assert-NoInstallerResidue -Directory $installDest -Message "checksum failure left installer residue"
Pass-Test "wrong checksum fails closed and preserves the existing binary"

$badVersionZip = Join-Path $script:TestRoot "bad-version\atp-x86_64-pc-windows-msvc.zip"
New-Item -ItemType Directory -Path (Split-Path -Parent $badVersionZip) | Out-Null
New-ValidZip -Path $badVersionZip -Executable $badVersionExe
$badVersionHash = (Get-FileHash -LiteralPath $badVersionZip -Algorithm SHA256).Hash
Invoke-InstallerProcess @("-Offline", $badVersionZip, "-Checksum", $badVersionHash, "-Version", "v1.2.3", "-Dest", $installDest, "-NoVerify", "-Force", "-Quiet")
Assert-True ($script:LastExit -ne 0) "wrong-version archive unexpectedly succeeded"
Assert-Contains "version mismatch" $script:LastOutput "wrong-version error was not explicit"
Assert-True ((Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash -ceq $before) "wrong-version archive changed the existing binary"
Assert-NoInstallerResidue -Directory $installDest -Message "version mismatch left installer residue"
Pass-Test "version mismatch fails before replacement and preserves the existing binary"

$badRqZip = Join-Path $script:TestRoot "bad-rq\atp-x86_64-pc-windows-msvc.zip"
New-Item -ItemType Directory -Path (Split-Path -Parent $badRqZip) | Out-Null
New-ValidZip -Path $badRqZip -Executable $badRqExe
$badRqHash = (Get-FileHash -LiteralPath $badRqZip -Algorithm SHA256).Hash
Invoke-InstallerProcess @("-Offline", $badRqZip, "-Checksum", $badRqHash, "-Version", "v1.2.3", "-Dest", $installDest, "-NoVerify", "-Force", "-Quiet")
Assert-True ($script:LastExit -ne 0) "rq-keygen-failing archive unexpectedly succeeded"
Assert-Contains "rq-keygen" $script:LastOutput "rq-keygen error was not explicit"
Assert-True ((Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash -ceq $before) "rq-keygen failure changed the existing binary"
Assert-NoInstallerResidue -Directory $installDest -Message "rq-keygen failure left installer residue"
Pass-Test "rq-keygen failure preserves the existing binary"

$missingArchive = Join-Path $script:TestRoot "missing\atp-x86_64-pc-windows-msvc.zip"
Invoke-InstallerProcess @("-Offline", $missingArchive, "-Version", "v1.2.3", "-Dest", $installDest, "-Verify", "-Quiet")
Assert-True ($script:LastExit -eq 0) "same-version install did not short-circuit before acquisition"
Assert-True ((Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash -ceq $before) "same-version short-circuit changed the existing binary"
Invoke-InstallerProcess @("-Offline", $missingArchive, "-Version", "v1.2.3", "-Dest", $installDest, "-Force", "-Quiet")
Assert-True ($script:LastExit -ne 0) "force did not reacquire the missing archive"
Assert-Contains "not found" $script:LastOutput "force failure did not report the missing archive"
Assert-NoInstallerResidue -Directory $installDest -Message "acquisition failure left installer residue"
Pass-Test "same-version skips acquisition but Force reacquires; Verify still runs"

$directoryDest = Join-Path $script:TestRoot "directory-target"
New-Item -ItemType Directory -Path (Join-Path $directoryDest "atp.exe") -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $directoryDest "atp.exe\sentinel"), "keep")
Invoke-InstallerProcess @("-Offline", $validZip, "-Checksum", $validHash, "-Version", "v1.2.3", "-Dest", $directoryDest, "-Force", "-Quiet")
Assert-True ($script:LastExit -ne 0) "directory install target unexpectedly succeeded"
Assert-Contains "directory" $script:LastOutput "directory-target error was not explicit"
Assert-True (Test-Path -LiteralPath (Join-Path $directoryDest "atp.exe\sentinel") -PathType Leaf) "directory target was mutated"
Pass-Test "directory install targets fail closed and are preserved"

$danglingFileTarget = Join-Path $script:TestRoot "dangling-file-target.txt"
$danglingFileLink = Join-Path $script:TestRoot "dangling-file-link.txt"
[IO.File]::WriteAllText($danglingFileTarget, "temporary")
$danglingFileOutput = & cmd.exe /d /c "mklink `"$danglingFileLink`" `"$danglingFileTarget`"" 2>&1
if ($LASTEXITCODE -eq 0) {
    [IO.File]::Delete($danglingFileTarget)
    Assert-True (-not (Test-AtpFileExists $danglingFileTarget)) "file symlink target was not removed"
    Assert-True (Test-AtpPathEntryExists $danglingFileLink) "lexical path detection missed a dangling file symlink"
    Remove-AtpFileStrict $danglingFileLink
    Assert-True (-not (Test-AtpPathEntryExists $danglingFileLink)) "dangling file symlink cleanup left the link behind"
    Pass-Test "strict file cleanup removes dangling symlinks without following a target"
} else {
    [IO.File]::Delete($danglingFileTarget)
    Fail-Test "required dangling file symlink fixture could not be created: $danglingFileOutput"
}

$danglingDirectoryTarget = Join-Path $script:TestRoot "dangling-directory-target"
$danglingDirectoryLink = Join-Path $script:TestRoot "dangling-directory-link"
New-Item -ItemType Directory -Path $danglingDirectoryTarget | Out-Null
$danglingDirectoryOutput = & cmd.exe /d /c "mklink /J `"$danglingDirectoryLink`" `"$danglingDirectoryTarget`"" 2>&1
if ($LASTEXITCODE -eq 0) {
    [IO.Directory]::Delete($danglingDirectoryTarget, $false)
    Assert-True (-not (Test-AtpDirectoryExists $danglingDirectoryTarget)) "directory junction target was not removed"
    Assert-True (Test-AtpPathEntryExists $danglingDirectoryLink) "lexical path detection missed a dangling directory junction"
    Remove-AtpDirectoryTreeStrict $danglingDirectoryLink
    Assert-True (-not (Test-AtpPathEntryExists $danglingDirectoryLink)) "dangling directory junction cleanup left the link behind"
    Pass-Test "strict directory cleanup removes dangling junctions without following a target"
} else {
    [IO.Directory]::Delete($danglingDirectoryTarget, $false)
    Fail-Test "required dangling directory junction fixture could not be created: $danglingDirectoryOutput"
}

$junctionRoot = Join-Path $script:TestRoot "junction-root"
$junctionTarget = Join-Path $script:TestRoot "junction-target"
New-Item -ItemType Directory -Path $junctionRoot | Out-Null
$junctionOutput = & cmd.exe /d /c "mklink /J `"$junctionTarget`" `"$junctionRoot`"" 2>&1
if ($LASTEXITCODE -eq 0) {
    $junctionSentinel = Join-Path $junctionRoot "sentinel.txt"
    [IO.File]::WriteAllText($junctionSentinel, "preserve")
    Assert-Throws { Remove-AtpDirectoryTreeStrict $junctionTarget } "reparse-point directory" "recursive cleanup must refuse a reparse-point root"
    Assert-True (Test-Path -LiteralPath $junctionTarget -PathType Container) "reparse-point root was removed"
    Assert-True (([IO.File]::ReadAllText($junctionSentinel)) -ceq "preserve") "reparse-root cleanup followed the junction and mutated its target"
    Pass-Test "recursive cleanup refuses reparse-point roots and preserves target sentinels"

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
    Fail-Test "required live junction fixture could not be created: $junctionOutput"
}

$lockedDest = Join-Path $script:TestRoot "locked-target"
New-Item -ItemType Directory -Path $lockedDest | Out-Null
$lockedTarget = Join-Path $lockedDest "atp.exe"
[IO.File]::Copy($goodExe, $lockedTarget)
$lockedBefore = (Get-FileHash -LiteralPath $lockedTarget -Algorithm SHA256).Hash
$held = [IO.File]::Open($lockedTarget, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
try {
    Invoke-InstallerProcess @("-Offline", $validZip, "-Checksum", $validHash, "-Version", "v1.2.3", "-Dest", $lockedDest, "-NoVerify", "-Force", "-Quiet")
    Assert-True ($script:LastExit -ne 0) "replacement of a locked binary unexpectedly succeeded"
} finally {
    $held.Dispose()
}
Assert-True ((Get-FileHash -LiteralPath $lockedTarget -Algorithm SHA256).Hash -ceq $lockedBefore) "replacement failure changed the locked binary"
Assert-NoInstallerResidue -Directory $lockedDest -Message "locked replacement failure left installer residue"
Pass-Test "replacement failure preserves the existing binary"

Assert-True (Test-AtpPathContains -PathValue "C:\Tools;C:\Users\Test\.local\bin" -Candidate "c:\users\test\.LOCAL\BIN\") "PATH matching was not case-insensitive and slash-stable"
Assert-True (-not (Test-AtpPathContains -PathValue "C:\Tools;C:\Other" -Candidate "C:\Users\Test\.local\bin")) "PATH helper reported a false match"
$systemDriveRoot = [IO.Path]::GetPathRoot("$($env:SystemDrive)\")
Assert-True ((Get-AtpNormalizedPathEntry $systemDriveRoot) -ceq $systemDriveRoot) "PATH normalization converted a drive root into a drive-relative path"
Assert-True (Test-AtpPathContains -PathValue "$systemDriveRoot;C:\Tools" -Candidate $systemDriveRoot) "PATH matching did not preserve a drive-root entry"
Assert-True (-not [string]::Equals((Get-AtpNormalizedPathEntry $systemDriveRoot), $systemDriveRoot.TrimEnd([char]'\'), [StringComparison]::Ordinal)) "drive-root normalization collapsed to C: semantics"
Invoke-InstallerProcess @("-Help")
Assert-True ($script:LastExit -eq 0) "Help exited non-zero"
Assert-Contains "native Windows x64" $script:LastOutput "Help output is missing the platform contract"
Pass-Test "EasyMode PATH matching preserves drive roots, remains idempotent, and Help is side-effect free"

Complete-TestRun
Write-Host "PASS: $($script:PassCount) PowerShell installer regression groups"
