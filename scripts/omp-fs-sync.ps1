#requires -Version 5.1
# Standalone Windows x64 installer/updater; no Bun, Git, or checkout required.
# Usage: & .\omp-fs-sync.ps1 -InstallShell
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateNotNullOrEmpty()]
    [ValidateScript({
        if ([IO.Path]::GetExtension($_) -ine '.exe') { throw 'Destination must be an .exe file.' }
        if ([IO.Path]::GetFileName($_) -ieq 'omp.exe') { throw 'Destination must not replace the official omp.exe.' }
        $true
    })]
    [string]$Destination = "$env:USERPROFILE\.bun\bin\omp-fs.exe",
    [switch]$InstallShell
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This installer supports Windows x64 only.'
}
$runtimeInformation = 'System.Runtime.InteropServices.RuntimeInformation' -as [type]
$architecture = if ($null -ne $runtimeInformation) {
    $runtimeInformation::OSArchitecture.ToString()
} elseif ($env:PROCESSOR_ARCHITEW6432) {
    $env:PROCESSOR_ARCHITEW6432
} else {
    $env:PROCESSOR_ARCHITECTURE
}
if (-not [Environment]::Is64BitOperatingSystem -or $architecture -notin @('AMD64', 'X64')) {
    throw "Unsupported Windows architecture: $architecture. Only x64 is supported."
}
if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { throw 'USERPROFILE is not set.' }

$Destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
$updaterPath = Join-Path $env:USERPROFILE '.omp\bin\omp-sync.ps1'
$binaryName = 'omp-fs-windows-x64.exe'
$updaterName = 'omp-fs-sync.ps1'
$apiUrl = 'https://api.github.com/repos/DoriannX/oh-my-pi/releases/latest'
$downloadRoot = 'https://github.com/DoriannX/oh-my-pi/releases/download/'
$token = [Guid]::NewGuid().ToString('N')
$stageDirectory = Join-Path ([IO.Path]::GetDirectoryName($Destination)) ".omp-fs-update-$token"

function Assert-GitHubUrl {
    param([Uri]$Url)
    if (-not $Url.IsAbsoluteUri -or $Url.Scheme -cne 'https' -or -not $Url.IsDefaultPort -or $Url.UserInfo -or $Url.Fragment) {
        throw "Refusing an unsafe download URL: $Url"
    }
    $allowed = switch ($Url.DnsSafeHost.ToLowerInvariant()) {
        'api.github.com' { $Url.AbsolutePath -ceq '/repos/DoriannX/oh-my-pi/releases/latest' }
        'github.com' { $Url.AbsolutePath.StartsWith('/DoriannX/oh-my-pi/releases/download/', [StringComparison]::Ordinal) }
        'release-assets.githubusercontent.com' { $Url.AbsolutePath.StartsWith('/github-production-release-asset/', [StringComparison]::Ordinal) }
        'objects.githubusercontent.com' { $Url.AbsolutePath.StartsWith('/github-production-release-asset-', [StringComparison]::Ordinal) }
        default { $false }
    }
    if (-not $allowed) { throw "Refusing a URL outside the GitHub release endpoints: $Url" }
}

function Receive-GitHubFile {
    param([Uri]$Url, [string]$Path)
    # Check every redirect before sending it; automatic redirects could escape the allowlist.
    $deadline = [Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(15))
    try {
        for ($redirect = 0; $redirect -le 5; $redirect++) {
            Assert-GitHubUrl $Url
            $response = $client.GetAsync($Url, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $deadline.Token).GetAwaiter().GetResult()
            try {
                $status = [int]$response.StatusCode
                if ($status -in @(301, 302, 303, 307, 308)) {
                    if ($redirect -eq 5 -or $null -eq $response.Headers.Location) {
                        throw "Invalid or excessive GitHub redirects for $Url"
                    }
                    $Url = [Uri]::new($Url, $response.Headers.Location)
                    continue
                }
                if ($status -ne 200) { throw "GitHub download failed (HTTP $status): $Url" }
                $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                try {
                    $outputStream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try { $null = $inputStream.CopyToAsync($outputStream, 81920, $deadline.Token).GetAwaiter().GetResult() }
                    finally { $outputStream.Dispose() }
                } finally { $inputStream.Dispose() }
                return
            } finally { $response.Dispose() }
        }
    } finally { $deadline.Dispose() }
}

function Assert-BinaryWorks {
    param([string]$Path)
    # --version exits before loading the native addon, so it cannot validate a build.
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = $Path
    $process.StartInfo.Arguments = 'config get tui.fullscreen'
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    try {
        if (-not $process.Start()) { throw "Could not start $Path" }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) {
            $process.Kill()
            $process.WaitForExit()
            throw "Binary smoke check timed out: $Path config get tui.fullscreen"
        }
        $detail = ($stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()).Trim()
        if ($process.ExitCode -ne 0) {
            throw "Binary smoke check failed (exit $($process.ExitCode)): $Path config get tui.fullscreen`n$detail"
        }
    } finally { $process.Dispose() }
}

function Get-ShellProfileUpdate {
    if ([string]::IsNullOrWhiteSpace([string]$PROFILE)) { throw 'This PowerShell host does not provide a PROFILE path.' }
    $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath([string]$PROFILE)
    $encoding = [Text.UTF8Encoding]::new($true)
    $text = ''
    if ([IO.File]::Exists($path)) {
        # Preserve BOM/encoding and all text outside our marked block, including old PS5 ANSI profiles.
        $reader = [IO.StreamReader]::new($path, [Text.UTF8Encoding]::new($false, $true), $true)
        try {
            try {
                $text = $reader.ReadToEnd()
                $encoding = $reader.CurrentEncoding
            } catch [Text.DecoderFallbackException] {
                $encoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
                $text = [IO.File]::ReadAllText($path, $encoding)
            }
        } finally { $reader.Dispose() }
    } elseif (Test-Path -LiteralPath $path) { throw "Profile path is not a file: $path" }
    $starts = [regex]::Matches($text, '(?m)^# >>> omp-fullscreen\b[^\r\n]*')
    $ends = [regex]::Matches($text, '(?m)^# <<< omp-fullscreen\b[^\r\n]*')
    if ($starts.Count -ne $ends.Count -or $starts.Count -gt 1 -or ($starts.Count -eq 1 -and $ends[0].Index -lt $starts[0].Index)) {
        throw "Profile has ambiguous or incomplete omp-fullscreen markers; not modifying it: $path"
    }
    $newline = if ($text.Contains("`r`n") -or -not $text.Contains("`n")) { "`r`n" } else { "`n" }
    $escapedDestination = $Destination.Replace("'", "''")
    $block = @'
# >>> omp-fullscreen
function omp-fs {
    $exe = '__OMP_FULLSCREEN_EXE__'
    if ($args | Where-Object { $_ -like '--tui-mode*' }) { & $exe @args }
    else { & $exe --tui-mode=fullscreen @args }
}
function omp-sync { & "$env:USERPROFILE\.omp\bin\omp-sync.ps1" @args }
# <<< omp-fullscreen
'@
    $block = $block.Replace('__OMP_FULLSCREEN_EXE__', $escapedDestination).Replace("`r`n", "`n").Replace("`n", $newline)
    if ($starts.Count -eq 1) {
        $end = $ends[0].Index + $ends[0].Length
        $updated = $text.Substring(0, $starts[0].Index) + $block + $text.Substring($end)
    } else {
        $separator = if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $newline } else { '' }
        $updated = $text + $separator + $block + $newline
    }
    return @{ Path = $path; Original = $text; Text = $updated; Encoding = $encoding; Existed = [IO.File]::Exists($path) }
}

$profileUpdate = if ($InstallShell) { Get-ShellProfileUpdate } else { $null }
if ((Test-Path -LiteralPath $Destination) -and -not [IO.File]::Exists($Destination)) {
    throw "Destination is not a file: $Destination"
}
if ((Test-Path -LiteralPath $updaterPath) -and -not [IO.File]::Exists($updaterPath)) {
    throw "Updater destination is not a file: $updaterPath"
}

Add-Type -AssemblyName System.Net.Http
$previousTls = [Net.ServicePointManager]::SecurityProtocol
[Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
$handler = [Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$client = [Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromMinutes(15)
$client.DefaultRequestHeaders.UserAgent.ParseAdd('omp-fs-sync/1.0')
$client.DefaultRequestHeaders.Add('X-GitHub-Api-Version', '2022-11-28')
$updaterStage = $null
$profileStage = $null
$parked = $null
try {
    [IO.Directory]::CreateDirectory($stageDirectory) | Out-Null
    Write-Host 'Fetching the latest published fullscreen release...'
    $metadataPath = Join-Path $stageDirectory 'release.json'
    Receive-GitHubFile $apiUrl $metadataPath
    $release = [IO.File]::ReadAllText($metadataPath) | ConvertFrom-Json
    if ($release.draft -ne $false -or $release.prerelease -ne $false -or $release.tag_name -cnotmatch '^fullscreen-v[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]{7,40}$') {
        throw 'GitHub latest release is not a published stable fullscreen release.'
    }
    $assets = @{}
    foreach ($name in @($binaryName, $updaterName, 'SHA256SUMS')) {
        $matches = @($release.assets | Where-Object { $_.name -ceq $name })
        if ($matches.Count -ne 1) { throw "Release must contain exactly one $name asset." }
        $expectedUrl = $downloadRoot + [Uri]::EscapeDataString($release.tag_name) + '/' + $name
        if ($matches[0].browser_download_url -cne $expectedUrl) { throw "Unexpected release asset URL for $name." }
        Assert-GitHubUrl ([Uri]$expectedUrl)
        $assets[$name] = $expectedUrl
    }
    Write-Host "Release: $($release.tag_name)"
    $checksumsPath = Join-Path $stageDirectory 'SHA256SUMS'
    Receive-GitHubFile $assets['SHA256SUMS'] $checksumsPath
    $hashes = @{}
    foreach ($line in [IO.File]::ReadAllLines($checksumsPath)) {
        if ($line.Length -eq 0) { continue }
        $entry = [regex]::Match($line, '^([0-9a-fA-F]{64})  (omp-fs-windows-x64\.exe|omp-fs-sync\.ps1)$')
        if (-not $entry.Success) { throw 'Invalid SHA256SUMS entry; expected a SHA256 hash, two spaces, and an exact release filename.' }
        $name = $entry.Groups[2].Value
        if ($hashes.ContainsKey($name)) { throw "Duplicate SHA256SUMS entry: $name" }
        $hashes[$name] = $entry.Groups[1].Value
    }
    if ($hashes.Count -ne 2) { throw 'SHA256SUMS must contain both the binary and updater hashes.' }

    $downloadedUpdater = Join-Path $stageDirectory $updaterName
    Receive-GitHubFile $assets[$updaterName] $downloadedUpdater
    if ((Get-FileHash -LiteralPath $downloadedUpdater -Algorithm SHA256).Hash -ine $hashes[$updaterName]) {
        throw 'Updater SHA256 mismatch; installed files have not been changed.'
    }
    $binaryUnchanged = [IO.File]::Exists($Destination) -and (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ieq $hashes[$binaryName]
    if ($binaryUnchanged) {
        Assert-BinaryWorks $Destination
        Write-Host 'Installed binary already matches the release; verified without reinstalling.'
    } else {
        $stagedBinary = Join-Path $stageDirectory $binaryName
        Write-Host "Downloading $binaryName..."
        Receive-GitHubFile $assets[$binaryName] $stagedBinary
        if ((Get-FileHash -LiteralPath $stagedBinary -Algorithm SHA256).Hash -ine $hashes[$binaryName]) {
            throw 'Binary SHA256 mismatch; installed files have not been changed.'
        }
        Assert-BinaryWorks $stagedBinary
        $installedNewBinary = $false
        try {
            if ([IO.File]::Exists($Destination)) {
                $rollbackPath = "$Destination.parked-$token"
                # Rename, never overwrite or delete a potentially running Windows executable.
                [IO.File]::Move($Destination, $rollbackPath)
                $parked = $rollbackPath
            }
            [IO.File]::Move($stagedBinary, $Destination)
            $installedNewBinary = $true
            Assert-BinaryWorks $Destination
        } catch {
            $installFailure = $_.Exception.Message
            try {
                if ($installedNewBinary) { [IO.File]::Move($Destination, "$Destination.failed-$token") }
                if ($null -ne $parked) { [IO.File]::Move($parked, $Destination) }
            } catch {
                throw "Install failed: $installFailure`nRollback also failed: $($_.Exception.Message)`nPrevious binary retained at: $parked"
            }
            throw "Install failed; previous installation restored (if present): $installFailure"
        }
    }

    # Install the verified release asset, not this running script. Same-directory replacement
    # is atomic and works when this invocation itself came from ~/.omp/bin/omp-sync.ps1.
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($updaterPath)) | Out-Null
    if (-not [IO.File]::Exists($updaterPath) -or (Get-FileHash -LiteralPath $updaterPath -Algorithm SHA256).Hash -ine $hashes[$updaterName]) {
        $updaterStage = Join-Path ([IO.Path]::GetDirectoryName($updaterPath)) ".omp-sync-$token.ps1"
        [IO.File]::Copy($downloadedUpdater, $updaterStage)
        if ([IO.File]::Exists($updaterPath)) { [IO.File]::Replace($updaterStage, $updaterPath, [NullString]::Value) }
        else { [IO.File]::Move($updaterStage, $updaterPath) }
    }
    if ($InstallShell -and $profileUpdate.Text -cne $profileUpdate.Original) {
        # Do not overwrite a profile edited while the release was downloading.
        if ([IO.File]::Exists($profileUpdate.Path) -ne $profileUpdate.Existed -or ($profileUpdate.Existed -and [IO.File]::ReadAllText($profileUpdate.Path, $profileUpdate.Encoding) -cne $profileUpdate.Original)) {
            throw "Profile changed during installation; rerun with -InstallShell: $($profileUpdate.Path)"
        }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($profileUpdate.Path)) | Out-Null
        $profileStage = Join-Path ([IO.Path]::GetDirectoryName($profileUpdate.Path)) ".omp-fullscreen-profile-$token.ps1"
        $writeEncoding = $profileUpdate.Encoding
        if ($writeEncoding.GetString($writeEncoding.GetBytes($profileUpdate.Text)) -cne $profileUpdate.Text) {
            $writeEncoding = [Text.UTF8Encoding]::new($true)
        }
        [IO.File]::WriteAllText($profileStage, $profileUpdate.Text, $writeEncoding)
        if ($profileUpdate.Existed) { [IO.File]::Replace($profileStage, $profileUpdate.Path, [NullString]::Value) }
        else { [IO.File]::Move($profileStage, $profileUpdate.Path) }
    }
    Write-Host "Verified fullscreen binary: $Destination"
    Write-Host "Installed updater: $updaterPath"
    if ($null -ne $parked) { Write-Host "Previous binary kept for rollback: $parked" }
    if ($InstallShell) { Write-Host "Shell functions installed in $($profileUpdate.Path). Open a new shell or reload that profile." }
    if ($Destination -ine (Join-Path $env:USERPROFILE '.bun\bin\omp-fs.exe')) {
        Write-Host "For this custom location, pass -Destination '$($Destination.Replace("'", "''"))' to future omp-sync calls."
    }
} finally {
    $client.Dispose()
    [Net.ServicePointManager]::SecurityProtocol = $previousTls
    # Only remove temporary paths created by this invocation; parked executables are never pruned.
    foreach ($temporary in @($updaterStage, $profileStage, $stageDirectory)) {
        if ($temporary -and (Test-Path -LiteralPath $temporary)) {
            try { Remove-Item -LiteralPath $temporary -Recurse -Force }
            catch { Write-Warning "Could not remove temporary path ${temporary}: $($_.Exception.Message)" }
        }
    }
}
