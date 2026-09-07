#!/usr/bin/env pwsh
<#
Unit checks for the pure parts of tools/qubixctl.ps1.

No Hyper-V, no network, no WSL: the script is dot-sourced (which defines the
functions without running a command) and the helpers that do not touch the
host are exercised on both Linux (CI) and Windows.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/qubixctl.ps1')

$script:failures = 0
$script:passes = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:passes++
    } else {
        $script:failures++
        Write-Host "FAIL: $Message" -ForegroundColor Red
    }
}

function Assert-Throw {
    param([scriptblock]$Block, [string]$Pattern, [string]$Message)
    try {
        & $Block | Out-Null
        $script:failures++
        Write-Host "FAIL: $Message (did not throw)" -ForegroundColor Red
    } catch {
        if ($_.Exception.Message -like $Pattern) {
            $script:passes++
        } else {
            $script:failures++
            Write-Host "FAIL: $Message (unexpected error: $($_.Exception.Message))" -ForegroundColor Red
        }
    }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("qubixctl-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

try {
    # --- Get-Prop / Get-EffectiveValue -------------------------------------
    $obj = [PSCustomObject]@{ a = 1; nested = [PSCustomObject]@{ b = 'x' }; empty = $null }
    Assert-True ((Get-Prop $obj 'a') -eq 1) 'Get-Prop returns an existing value'
    Assert-True ((Get-Prop $obj 'missing' 'dflt') -eq 'dflt') 'Get-Prop falls back for missing properties'
    Assert-True ((Get-Prop $obj 'empty' 'dflt') -eq 'dflt') 'Get-Prop falls back for null values'
    Assert-True ((Get-Prop $null 'a' 'dflt') -eq 'dflt') 'Get-Prop tolerates a null object'
    Assert-True ((Get-Prop (Get-Prop $obj 'nested') 'b') -eq 'x') 'Get-Prop composes'
    Assert-True ((Get-EffectiveValue -Override '' -Default 'd') -eq 'd') 'Get-EffectiveValue uses the default for empty overrides'
    Assert-True ((Get-EffectiveValue -Override 'o' -Default 'd') -eq 'o') 'Get-EffectiveValue prefers the override'

    # --- Manifest ------------------------------------------------------------
    $manifestPath = Join-Path $repo 'manifest.json'
    Assert-True (Test-Path -LiteralPath $manifestPath) 'manifest.json is committed'
    $manifest = Read-QubixManifest -Path $manifestPath
    Assert-True ((Get-Prop $manifest 'schemaVersion') -eq 2) 'manifest.json has schemaVersion 2'

    $config = Resolve-MachineConfig -Manifest $manifest -Name 'spotibox'
    Assert-True ((Get-Prop $config 'vmName') -eq 'qubix-spotibox') 'spotibox vmName is derived from hostName'
    Assert-True ((Get-Prop $config 'hostName') -eq 'spotibox') 'spotibox hostName'
    Assert-True ((Get-Prop (Get-Prop $config 'homeDisk') 'enable') -eq $true) 'spotibox has a persistent home disk'
    Assert-True ((Get-Prop (Get-Prop $config 'release') 'systemAsset') -eq 'spotibox.vhdx.gz') 'release asset names are stable'
    Assert-True ((Get-Prop (Get-Prop $config 'rdp') 'user') -eq 'rdp') 'rdp user is the dedicated account'
    Assert-True (-not [string]::IsNullOrWhiteSpace((Get-Prop $config 'staticIp' ''))) 'spotibox declares a static IP'
    Assert-True ((Get-Prop $config 'natSwitchSubnet' '') -like '*.0/24') 'NAT subnet is derived from the static IP'

    Assert-Throw { Resolve-MachineConfig -Manifest $manifest -Name 'nope' } '*Known machines: spotibox*' 'unknown machine names list the known ones'

    $v1 = '{"spotibox":{"vmName":"x"}}' | ConvertFrom-Json
    Assert-Throw { Assert-ManifestSchema -Manifest $v1 } '*schemaVersion*' 'schema v1 manifests are rejected with a hint'

    # --- Paths --------------------------------------------------------------
    $paths = Get-QubixLayout -Config $config -VmRootOverride ''
    Assert-True ($paths.VmName -eq 'qubix-spotibox') 'paths carry the VM name'
    Assert-True ($paths.SystemVhdx -like '*qubix-spotibox*qubix-spotibox.vhdx') 'system disk path'
    Assert-True ($paths.HomeVhdx -like '*qubix-spotibox-home.vhdx') 'home disk path'
    Assert-True ($paths.RdpFile -like '*qubix-spotibox.rdp') 'rdp file path'
    Assert-True ($paths.ImageCache -like '*images*spotibox') 'image cache is per machine'
    $custom = Get-QubixLayout -Config $config -VmRootOverride 'D:\vms'
    Assert-True ($custom.VmRoot -eq 'D:\vms') '-VmRoot override wins over the manifest'

    # --- WSL path helpers ---------------------------------------------------
    Assert-True ((ConvertTo-WslMountPath -WindowsPath 'C:\Users\me\x.tmp') -eq '/mnt/c/Users/me/x.tmp') 'drive path -> /mnt path'
    Assert-Throw { ConvertTo-WslMountPath -WindowsPath '\\server\share' } '*Not a drive-letter path*' 'UNC paths are rejected by the /mnt converter'
    $loc = Resolve-WslRepoLocation -DistroOverride 'Ubuntu' -LinuxPathOverride '/srv/qubix'
    Assert-True ($loc.Distro -eq 'Ubuntu' -and $loc.RepoPath -eq '/srv/qubix') 'explicit WSL overrides are honoured'

    # --- SHA256SUMS + gzip --------------------------------------------------
    $payload = [System.Text.Encoding]::ASCII.GetBytes(('qubix ' * 1000))
    $plain = Join-Path $tmp 'a.vhdx'
    $gz = Join-Path $tmp 'a.vhdx.gz'
    [System.IO.File]::WriteAllBytes($plain, $payload)
    $in = [System.IO.File]::OpenRead($plain)
    $out = [System.IO.File]::Create($gz)
    $stream = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionMode]::Compress)
    $in.CopyTo($stream); $stream.Dispose(); $out.Dispose(); $in.Dispose()

    $hash = (Get-FileHash -LiteralPath $gz -Algorithm SHA256).Hash.ToLowerInvariant()
    $sumsFile = Join-Path $tmp 'SHA256SUMS'
    Set-Content -LiteralPath $sumsFile -Value @("$hash  a.vhdx.gz", 'deadbeef  garbage line', "$hash *b.vhdx.gz")
    $sums = Read-Sha256SumFile -Path $sumsFile
    Assert-True ($sums['a.vhdx.gz'] -eq $hash) 'SHA256SUMS parsing (two-space form)'
    Assert-True ($sums['b.vhdx.gz'] -eq $hash) 'SHA256SUMS parsing (binary marker form)'
    Assert-True (-not $sums.ContainsKey('garbage line')) 'malformed lines are ignored'
    Assert-FileHash -Path $gz -Expected $hash.ToUpperInvariant()
    Assert-Throw { Assert-FileHash -Path $gz -Expected ('0' * 64) } '*SHA256 mismatch*' 'hash mismatch is fatal'

    $restored = Join-Path $tmp 'restored.vhdx'
    Expand-GzipFile -Path $gz -Destination $restored
    Assert-True (([System.IO.File]::ReadAllBytes($restored)).Length -eq $payload.Length) 'gzip round trip restores the payload'
    Assert-True (-not (Test-Path -LiteralPath "$restored.part")) 'no .part file is left behind'

    $cached = Get-ReleaseAsset -BaseUrl 'http://unused.invalid' -Dir $tmp -Asset 'restored.vhdx.gz' -Sums @{}
    Assert-True ($cached -eq $restored) 'cached assets are returned without downloading'

    # --- RDP ----------------------------------------------------------------
    $rdp = Format-RdpFile -Address '192.168.250.10' -User 'rdp' -Width 1280 -Height 800
    Assert-True ($rdp -like "full address:s:192.168.250.10`r`n*") 'rdp file starts with the address'
    Assert-True ($rdp -like "*username:s:rdp`r`n*") 'rdp file carries the user'
    Assert-True ($rdp -like "*audiomode:i:0`r`n*") 'audio is played on the host'
    Assert-True ($rdp -like "*redirectdrives:i:0`r`n*") 'drives are not redirected'
    Assert-True ($rdp -like "*desktopwidth:i:1280`r`n*desktopheight:i:800`r`n*") 'window size comes from the manifest'

    Assert-True ((Get-QubixAddress -Config $config -Explicit '10.0.0.5') -eq '10.0.0.5') 'explicit address wins'
    Assert-True ((Get-QubixAddress -Config $config -Explicit '') -eq (Get-Prop $config 'staticIp')) 'static IP is used without Hyper-V lookups'
    Assert-True (-not (Test-TcpPort -TargetHost '127.0.0.1' -Port 1 -TimeoutMs 500)) 'closed ports are reported as closed'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "qubixctl unit checks: $script:passes passed, $script:failures failed"
if ($script:failures -gt 0) { exit 1 }
