# GitHub Actions release transaction. Build/typecheck/test gates live in the workflow.
# No branch or release is changed remotely before the Publish phase.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Prepare', 'Native', 'Smoke', 'Publish')]
    [string]$Phase
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$Repository = 'DoriannX/oh-my-pi'
$Upstream = 'can1357/oh-my-pi'
$Branch = 'feat/fullscreen-chat-tui'
$AssetNames = @('omp-fs-windows-x64.exe', 'omp-fs-sync.ps1', 'SHA256SUMS')
if ($env:GITHUB_REPOSITORY -cne $Repository -or -not $env:RUNNER_TEMP) {
    throw "This helper requires the $Repository GitHub Actions environment."
}
$Root = Split-Path $PSScriptRoot -Parent
$StatePath = Join-Path $env:RUNNER_TEMP 'fullscreen-release-state.json'
$AssetsDir = Join-Path $env:RUNNER_TEMP 'fullscreen-release-assets'
Set-Location $Root

function Invoke-Checked {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed (exit $LASTEXITCODE): $($Arguments -join ' ')"
    }
}

function Get-GitHub {
    param([string]$Path, [switch]$AllowNotFound)
    if (-not $env:GH_TOKEN) { throw 'GH_TOKEN is required for GitHub API access.' }
    try {
        Invoke-RestMethod -Uri "https://api.github.com/$Path" -Headers @{
            Authorization = "Bearer $env:GH_TOKEN"
            Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
        }
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404 -and $AllowNotFound) {
            return $null
        }
        throw "GitHub API request failed for $Path; refusing to treat an API failure as a missing release."
    }
}

function Get-Release {
    param([string]$Tag)
    $published = Get-GitHub "repos/$Repository/releases/tags/$Tag" -AllowNotFound
    if ($published) { return $published }
    # GitHub's by-tag endpoint excludes drafts, including drafts owned by this token.
    # The authenticated release list includes them and permits interrupted uploads to resume.
    for ($page = 1; ; $page++) {
        $releases = @(Get-GitHub "repos/$Repository/releases?per_page=100&page=$page")
        $matching = @($releases | Where-Object { $_.tag_name -ceq $Tag })
        if ($matching.Count -gt 1) { throw "Multiple releases use tag $Tag." }
        if ($matching.Count -eq 1) { return $matching[0] }
        if ($releases.Count -lt 100) { return $null }
    }
}

function Get-RemoteCommit {
    param([string]$Ref)
    $rows = @(Invoke-Checked git @('ls-remote', 'origin', $Ref, "$Ref^{}"))
    if ($rows.Count -eq 0) { return $null }
    $peeled = @($rows | Where-Object { $_.EndsWith("$Ref^{}") })
    $row = if ($peeled.Count -eq 1) { $peeled[0] } else { $rows[0] }
    return ($row -split '\s+')[0]
}

function Assert-ReleaseAssets {
    param($Release)
    if ($Release.prerelease) { throw "Release $($Release.tag_name) is unexpectedly a prerelease." }
    $assets = @($Release.assets)
    if ($assets.Count -ne $AssetNames.Count) { throw "Release $($Release.tag_name) does not have exactly the required assets." }
    foreach ($name in $AssetNames) {
        $matching = @($assets | Where-Object { $_.name -ceq $name -and $_.state -eq 'uploaded' -and $_.size -gt 0 })
        if ($matching.Count -ne 1) { throw "Release $($Release.tag_name) is missing a complete $name asset." }
    }
}

if ($Phase -eq 'Prepare') {
    Invoke-Checked git @('config', 'user.name', 'github-actions[bot]')
    Invoke-Checked git @('config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com')
    $baseCommit = (Invoke-Checked git @('rev-parse', 'HEAD')).Trim()
    if ((Invoke-Checked git @('branch', '--show-current')).Trim() -cne $Branch) {
        throw "Checkout must be on $Branch."
    }
    $upstreamRelease = Get-GitHub "repos/$Upstream/releases/latest"
    $upstreamTag = [string]$upstreamRelease.tag_name
    if ($upstreamRelease.draft -or $upstreamRelease.prerelease -or $upstreamTag -cnotmatch '^v?\d+\.\d+\.\d+$') {
        throw "Upstream latest release is not a stable version tag: $upstreamTag"
    }
    Invoke-Checked git @('fetch', '--no-tags', "https://github.com/$Upstream.git", "refs/tags/$upstreamTag")
    $upstreamCommit = (Invoke-Checked git @('rev-parse', 'FETCH_HEAD^{commit}')).Trim()
    & git merge-base --is-ancestor $upstreamCommit HEAD
    $ancestorExit = $LASTEXITCODE
    if ($ancestorExit -eq 1) {
        # A real conflict fails before restoring anything or pushing. Preserve fork
        # workflows: GITHUB_TOKEN cannot write new upstream workflow definitions.
        Invoke-Checked git @('merge', '--no-commit', '--no-ff', '--no-edit', $upstreamCommit)
        Invoke-Checked git @('restore', "--source=$baseCommit", '--staged', '--worktree', '--', '.github/workflows')
        Invoke-Checked git @('commit', '--no-gpg-sign', '-m', "Merge upstream $upstreamTag into fullscreen fork")
    } elseif ($ancestorExit -ne 0) {
        throw "Cannot determine whether upstream $upstreamTag is already merged."
    }

    $commit = (Invoke-Checked git @('rev-parse', 'HEAD')).Trim()
    $shortCommit = $commit.Substring(0, 12)
    $version = $upstreamTag -creplace '^v', ''
    $tag = "fullscreen-v$version-$shortCommit"
    $packageManager = [string](Get-Content (Join-Path $Root 'package.json') -Raw | ConvertFrom-Json).packageManager
    if ($packageManager -cnotmatch '^bun@(\d+\.\d+\.\d+)(?:\+sha(?:256|512)\.[a-fA-F0-9]+)?$') {
        throw "Merged package.json must pin a stable Bun version, got: $packageManager"
    }
    $bunVersion = $Matches[1]
    $state = [ordered]@{
        baseCommit = $baseCommit
        commit = $commit
        upstreamTag = $upstreamTag
        upstreamCommit = $upstreamCommit
        tag = $tag
        bunVersion = $bunVersion
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding utf8NoBOM

    $release = Get-Release $tag
    $tagCommit = Get-RemoteCommit "refs/tags/$tag"
    if ($tagCommit -and $tagCommit -cne $commit) { throw "Immutable tag $tag already points to a different commit." }
    if ($release -and -not $release.draft) {
        if ($tagCommit -cne $commit) { throw "Published release $tag does not resolve to the verified source." }
        Assert-ReleaseAssets $release
        Write-Host "Source $commit already published as $tag; nothing to build or push."
        'skip=true' | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8NoBOM
        return
    }
    @('skip=false', "bun-version=$bunVersion") | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8NoBOM
    Write-Host "Building $tag from upstream $upstreamTag with Bun $bunVersion."
    return
}

$state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
if ((Invoke-Checked git @('rev-parse', 'HEAD')).Trim() -cne $state.commit) {
    throw 'The checkout changed after source selection.'
}

if ($Phase -eq 'Native') {
    $package = '@oh-my-pi/pi-natives-win32-x64'
    $version = [string](Get-Content (Join-Path $Root 'packages/natives/package.json') -Raw | ConvertFrom-Json).version
    if ($version -cnotmatch '^\d+\.\d+\.\d+$') { throw "Invalid native package version: $version" }
    try {
        $manifest = Invoke-RestMethod -Uri "https://registry.npmjs.org/$package/$version"
    } catch {
        throw "Cannot fetch exact $package@$version from npm. No Rust or older-addon fallback is permitted; the next hourly run will retry. $($_.Exception.Message)"
    }
    if ($manifest.name -cne $package -or $manifest.version -cne $version) {
        throw "npm returned a different package instead of $package@$version."
    }
    $tarball = "https://registry.npmjs.org/$package/-/pi-natives-win32-x64-$version.tgz"
    if ($manifest.dist.tarball -cne $tarball -or $manifest.dist.integrity -cnotmatch '^sha512-[A-Za-z0-9+/]+={0,2}$') {
        throw "Unexpected tarball URL or missing SHA-512 integrity for $package@$version."
    }
    $tempDir = Join-Path $env:RUNNER_TEMP "fullscreen-release-native-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $tempDir
    try {
        $archive = Join-Path $tempDir 'natives.tgz'
        Invoke-WebRequest -Uri $tarball -OutFile $archive
        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash
        $integrity = 'sha512-' + [Convert]::ToBase64String([Convert]::FromHexString($hash))
        if ($integrity -cne $manifest.dist.integrity) { throw "SHA-512 integrity mismatch for $package@$version." }
        $addonName = 'pi_natives.win32-x64-baseline.node'
        Invoke-Checked tar @('-xzf', $archive, '-C', $tempDir, 'package/package.json', "package/$addonName")
        $extractedPackage = Get-Content (Join-Path $tempDir 'package/package.json') -Raw | ConvertFrom-Json
        $addon = Join-Path $tempDir "package/$addonName"
        if ($extractedPackage.name -cne $package -or $extractedPackage.version -cne $version -or
            -not (Test-Path -LiteralPath $addon -PathType Leaf) -or (Get-Item -LiteralPath $addon).Length -le 0) {
            throw "Tarball does not contain the exact $package@$version baseline addon."
        }
        $nativeDir = Join-Path $Root 'packages/natives/native'
        # Never let the embed script prefer a stale modern/default variant.
        Get-ChildItem -LiteralPath $nativeDir -Filter 'pi_natives.win32-x64*.node' | Remove-Item -Force
        Copy-Item -LiteralPath $addon -Destination (Join-Path $nativeDir $addonName)
        "$version`n" | Set-Content (Join-Path $nativeDir '.installed-version') -Encoding utf8NoBOM -NoNewline
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
    return
}

if ($Phase -eq 'Smoke') {
    $binary = Join-Path $Root 'packages/coding-agent/dist/omp.exe'
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw "Build did not produce $binary." }
    $smokeDir = Join-Path $env:RUNNER_TEMP "fullscreen-release-smoke-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $smokeDir
    $isolatedEnv = @{
        HOME = $smokeDir
        USERPROFILE = $smokeDir
        PI_CODING_AGENT_DIR = (Join-Path $smokeDir '.omp/agent')
        PI_CONFIG_DIR = '.omp'
        OMP_PROFILE = $null
        PI_PROFILE = $null
        GH_TOKEN = $null
        GITHUB_TOKEN = $null
        NO_COLOR = '1'
    }
    $savedEnv = @{}
    foreach ($name in $isolatedEnv.Keys) {
        $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $isolatedEnv[$name], 'Process')
    }
    try {
        Set-Location $smokeDir
        $versionOutput = (Invoke-Checked $binary @('--version') | Out-String).Trim()
        $expectedVersion = [string](Get-Content (Join-Path $Root 'packages/coding-agent/package.json') -Raw | ConvertFrom-Json).version
        if ($versionOutput -notmatch "(?<![\w.])$([regex]::Escape($expectedVersion))(?![\w.])") {
            throw "Binary version does not match source version $expectedVersion."
        }
        # tui-mode belongs to the launch command, not the config subcommand.
        $help = Invoke-Checked $binary @('--tui-mode=fullscreen', '--help') | Out-String
        if ($help -notmatch 'tui-mode' -or $help -notmatch 'fullscreen') { throw 'Binary does not expose fullscreen launch mode.' }
        $null = Invoke-Checked $binary @('config', 'set', 'tui.fullscreen', 'true', '--json')
        $config = (Invoke-Checked $binary @('config', 'get', 'tui.fullscreen', '--json') | Out-String) | ConvertFrom-Json
        if ($config.key -cne 'tui.fullscreen' -or $config.value -isnot [bool] -or -not $config.value) {
            throw 'Real binary failed the isolated fullscreen config round trip.'
        }
        Write-Host "Binary smoke passed: $versionOutput; tui.fullscreen=$($config.value)."
    } finally {
        Set-Location $Root
        foreach ($name in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], 'Process') }
        Remove-Item -LiteralPath $smokeDir -Recurse -Force
    }
    $installer = Join-Path $Root 'scripts/omp-fs-sync.ps1'
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) { throw "Updater syntax errors: $($parseErrors -join '; ')" }
    if (Test-Path -LiteralPath $AssetsDir) { Remove-Item -LiteralPath $AssetsDir -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $AssetsDir
    Copy-Item -LiteralPath $binary -Destination (Join-Path $AssetsDir $AssetNames[0])
    Copy-Item -LiteralPath $installer -Destination (Join-Path $AssetsDir $AssetNames[1])
    $checksums = foreach ($name in $AssetNames[0..1]) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $AssetsDir $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $name"
    }
    [IO.File]::WriteAllText((Join-Path $AssetsDir 'SHA256SUMS'), ($checksums -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    return
}

# Publish can only consume assets produced by the successful Smoke phase.
foreach ($name in $AssetNames) {
    $file = Join-Path $AssetsDir $name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -le 0) {
        throw "Verified asset is missing: $name"
    }
}
$remoteHead = Get-RemoteCommit "refs/heads/$Branch"
if ($remoteHead -cne $state.baseCommit) {
    throw "Remote $Branch advanced during verification. No release will be published; retry on the new head."
}
$tagCommit = Get-RemoteCommit "refs/tags/$($state.tag)"
if ($tagCommit -and $tagCommit -cne $state.commit) { throw "Immutable tag $($state.tag) already has a different target." }
$refspecs = @()
if ($state.commit -cne $state.baseCommit) { $refspecs += "$($state.commit):refs/heads/$Branch" }
if (-not $tagCommit) { $refspecs += "$($state.commit):refs/tags/$($state.tag)" }
if ($refspecs.Count -gt 0) {
    Invoke-Checked git (@('push', '--atomic', 'origin') + $refspecs)
}
if ((Get-RemoteCommit "refs/heads/$Branch") -cne $state.commit) {
    throw 'Remote branch advanced before publication; leaving the existing public latest unchanged.'
}

$release = Get-Release $state.tag
if ($release -and -not $release.draft) {
    Assert-ReleaseAssets $release
    Write-Host "Release $($state.tag) is already public; leaving it immutable."
    return
}
if (-not $release) {
    $notes = "Windows x64 fullscreen build from upstream $($state.upstreamTag).`n`nSource commit: $($state.commit)`nUpstream commit: $($state.upstreamCommit)`n`nAssets include the standalone executable, PowerShell updater, and SHA256SUMS."
    Invoke-Checked gh @('release', 'create', $state.tag, '--repo', $Repository, '--verify-tag', '--draft', '--title', "OMP fullscreen $($state.upstreamTag) ($($state.commit.Substring(0, 12)))", '--notes', $notes)
}
# Reuse our same-tag draft after an interrupted upload; never alter a public release.
$assetPaths = @($AssetNames | ForEach-Object { Join-Path $AssetsDir $_ })
Invoke-Checked gh (@('release', 'upload', $state.tag, '--repo', $Repository, '--clobber') + $assetPaths)
$release = Get-Release $state.tag
if (-not $release.draft) { throw 'Release unexpectedly became public during asset upload.' }
Assert-ReleaseAssets $release
$downloadDir = Join-Path $env:RUNNER_TEMP "fullscreen-release-download-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $downloadDir
try {
    Invoke-Checked gh @('release', 'download', $state.tag, '--repo', $Repository, '--dir', $downloadDir)
    foreach ($name in $AssetNames) {
        $localHash = (Get-FileHash -LiteralPath (Join-Path $AssetsDir $name) -Algorithm SHA256).Hash
        $remoteHash = (Get-FileHash -LiteralPath (Join-Path $downloadDir $name) -Algorithm SHA256).Hash
        if ($localHash -cne $remoteHash) { throw "Uploaded asset checksum mismatch: $name; retaining the draft." }
    }
} finally {
    Remove-Item -LiteralPath $downloadDir -Recurse -Force
}
if ((Get-RemoteCommit "refs/heads/$Branch") -cne $state.commit -or
    (Get-RemoteCommit "refs/tags/$($state.tag)") -cne $state.commit) {
    throw 'Remote source changed before draft publication; retaining the draft and previous public latest.'
}
Invoke-Checked gh @('release', 'edit', $state.tag, '--repo', $Repository, '--draft=false', '--prerelease=false', '--latest')
$published = Get-GitHub "repos/$Repository/releases/latest"
if ($published.tag_name -cne $state.tag -or $published.draft) { throw 'GitHub did not mark the verified release as latest.' }
Assert-ReleaseAssets $published
Write-Host "Published $($state.tag): $($published.html_url)"
