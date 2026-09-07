<#
.SYNOPSIS
    Qubix controller: turns a Nix-built appliance image into a running,
    persistent Hyper-V VM and opens it as an RDP window.

.DESCRIPTION
    The default command, `up`, is idempotent and is what tools/qubix-up.cmd
    runs on double-click:

        manifest.json -> images (GitHub release | WSL build | local file)
                      -> Hyper-V VM        (created once, kept afterwards)
                      -> persistent home   (seeded once, never replaced)
                      -> wait for RDP
                      -> mstsc with a generated .rdp file

    Nothing here needs WSL unless -ImageSource wsl is requested.  The system
    disk is a throwaway Nix artifact; the home disk is the only state.

.PARAMETER Command
    up        create-if-missing, start, wait for RDP, connect      (default)
    connect   open the RDP window for a running VM
    start     start / resume the VM
    stop      graceful shutdown
    status    VM state, disks, address, installed image version
    recreate  replace the system disk with fresh images, keep the home disk
    destroy   remove VM + system disk (add -Purge to delete the home disk too)
    fetch     download release images into the cache without touching the VM
    build     build images in WSL (developer path)
    manifest  print the resolved machine config

.PARAMETER ImageSource
    auto      -ImagePath if given, otherwise the GitHub release      (default)
    release   download from the GitHub release named by -Release
    wsl       nix build inside WSL, manifest regenerated from Nix
    file      use -ImagePath / -HomeImagePath

.EXAMPLE
    .\tools\qubixctl.cmd                                   # up spotibox
    .\tools\qubixctl.cmd -Command recreate -Release v0.2.0
    .\tools\qubixctl.cmd -Command up -ImageSource wsl      # developer loop
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Script parameters are consumed by Invoke-QubixMain; the analyzer does not follow that.')]
[CmdletBinding()]
param(
    [ValidateSet('up', 'connect', 'start', 'stop', 'status', 'recreate', 'destroy', 'fetch', 'build', 'manifest')]
    [string]$Command = 'up',

    [string]$Machine = 'spotibox',

    [ValidateSet('auto', 'release', 'wsl', 'file')]
    [string]$ImageSource = 'auto',

    # Local .vhdx files (or .vhdx.gz) used by -ImageSource file / auto.
    [string]$ImagePath = '',
    [string]$HomeImagePath = '',

    # Release tag, or 'latest'.
    [string]$Release = 'latest',

    # Defaults to <repo>/manifest.json next to this script's parent folder.
    [string]$ManifestPath = '',

    # WSL build path only.
    [string]$WslDistro = '',
    [string]$RepoLinuxPath = '',

    # Overrides for manifest values.
    [string]$VmRoot = '',
    [string]$SwitchName = '',
    [string]$Address = '',

    [int]$TimeoutSeconds = 300,
    [switch]$NoConnect,
    [switch]$NoSavedCredential,
    [switch]$Purge
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Windows PowerShell 5.1 on older builds still defaults to TLS 1.0 for .NET
# web requests; GitHub requires TLS 1.2.
try {
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
} catch {
    Write-Verbose "Could not enable TLS 1.2: $($_.Exception.Message)"
}

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

function Get-Prop {
    # Strict-mode-safe property access on objects coming from ConvertFrom-Json.
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Get-EffectiveValue {
    param(
        [string]$Override,
        [object]$Default
    )

    if ([string]::IsNullOrWhiteSpace($Override)) {
        return [string]$Default
    }
    return $Override
}

function Join-QubixPath {
    # Join-Path validates the drive of its first argument against the current
    # session's PSDrives, which fails for roots on a volume that is not mounted
    # (or, in the unit checks, on Linux).  Path.Combine only joins strings.
    param(
        [string]$Path,
        [string]$ChildPath
    )
    return [System.IO.Path]::Combine($Path, $ChildPath)
}

function Get-DefaultManifestPath {
    return Join-QubixPath (Split-Path -Parent $PSScriptRoot) 'manifest.json'
}

# --------------------------------------------------------------------------
# Manifest
# --------------------------------------------------------------------------

function Assert-ManifestSchema {
    param([object]$Manifest)

    $version = Get-Prop $Manifest 'schemaVersion' 0
    if ([int]$version -ne 2) {
        throw "Unsupported manifest schemaVersion '$version' (expected 2). Regenerate manifest.json with tools/update-manifest.sh."
    }
    if ($null -eq (Get-Prop $Manifest 'machines')) {
        throw "Manifest has no 'machines' section."
    }
}

function Read-QubixManifest {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Manifest not found: $Path. Clone the full repository, or pass -ManifestPath."
    }

    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    Assert-ManifestSchema -Manifest $manifest
    return $manifest
}

function Resolve-MachineConfig {
    param(
        [object]$Manifest,
        [string]$Name
    )

    $machines = Get-Prop $Manifest 'machines'
    $config = Get-Prop $machines $Name
    if ($null -eq $config) {
        $known = @($machines.PSObject.Properties | ForEach-Object { $_.Name }) -join ', '
        throw "Machine '$Name' was not found in the Qubix manifest. Known machines: $known"
    }
    return $config
}

function Get-QubixLayout {
    param(
        [object]$Config,
        [string]$VmRootOverride
    )

    $vmName = [string](Get-Prop $Config 'vmName')
    $root = Get-EffectiveValue -Override $VmRootOverride -Default (Get-Prop $Config 'vmRoot' 'C:\HyperV\Qubix')
    $vmDir = Join-QubixPath $root $vmName

    return [PSCustomObject]@{
        VmName      = $vmName
        VmRoot      = $root
        VmDir       = $vmDir
        SystemVhdx  = Join-QubixPath $vmDir "$vmName.vhdx"
        HomeVhdx    = Join-QubixPath $vmDir "$vmName-home.vhdx"
        RdpFile     = Join-QubixPath $vmDir "$vmName.rdp"
        VersionFile = Join-QubixPath $vmDir 'image-version.txt'
        ImageCache  = Join-QubixPath (Join-QubixPath $root 'images') ([string](Get-Prop $Config 'hostName'))
    }
}

# --------------------------------------------------------------------------
# Host preconditions
# --------------------------------------------------------------------------

function Assert-HyperVAvailable {
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        throw ("Hyper-V PowerShell cmdlets are not available. Enable the feature from an elevated PowerShell and reboot:`n" +
               "  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All")
    }
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This command changes Hyper-V state and must run elevated. Double-click tools\qubix-up.cmd or use an elevated PowerShell."
    }
}

# --------------------------------------------------------------------------
# WSL build path (developer loop)
# --------------------------------------------------------------------------

function Save-WslTempScript {
    param([string]$Script)

    # GetTempFileName creates a file like C:\Users\...\AppData\Local\Temp\tmpXXXX.tmp
    $winPath = [System.IO.Path]::GetTempFileName()

    # Write script bytes directly - no BOM, LF-only line endings.
    # PowerShell's pipe (|) appends \r\n; WriteAllBytes avoids that entirely.
    [System.IO.File]::WriteAllBytes(
        $winPath,
        [System.Text.Encoding]::UTF8.GetBytes($Script + "`n")
    )

    return [PSCustomObject]@{ Win = $winPath; Wsl = (ConvertTo-WslMountPath -WindowsPath $winPath) }
}

function ConvertTo-WslMountPath {
    # C:\Users\x\file -> /mnt/c/Users/x/file
    param([string]$WindowsPath)

    if ($WindowsPath -notmatch '^([A-Za-z]):\\(.*)$') {
        throw "Not a drive-letter path: $WindowsPath"
    }
    return '/mnt/' + $matches[1].ToLowerInvariant() + '/' + ($matches[2] -replace '\\', '/')
}

function Resolve-WslRepoLocation {
    # Works out which distro and Linux path hold the repository this script
    # lives in.  \\wsl.localhost\Distro\home\me\qubix\tools -> (Distro, /home/me/qubix)
    param(
        [string]$DistroOverride,
        [string]$LinuxPathOverride
    )

    $repoWin = Split-Path -Parent $PSScriptRoot
    $distro = $DistroOverride
    $linuxPath = $LinuxPathOverride

    if ($repoWin -match '^\\\\(?:wsl\.localhost|wsl\$)\\([^\\]+)\\(.*)$') {
        if ([string]::IsNullOrWhiteSpace($distro)) { $distro = $matches[1] }
        if ([string]::IsNullOrWhiteSpace($linuxPath)) { $linuxPath = '/' + ($matches[2] -replace '\\', '/') }
    } elseif ([string]::IsNullOrWhiteSpace($linuxPath) -and $repoWin -match '^[A-Za-z]:\\') {
        $linuxPath = ConvertTo-WslMountPath -WindowsPath $repoWin
    }

    if ([string]::IsNullOrWhiteSpace($distro)) { $distro = 'NixOS' }
    if ([string]::IsNullOrWhiteSpace($linuxPath)) {
        throw "Cannot determine the Linux path of the repository. Pass -RepoLinuxPath."
    }

    return [PSCustomObject]@{ Distro = $distro; RepoPath = $linuxPath }
}

function Assert-WslAvailable {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw "wsl.exe was not found. -ImageSource wsl needs WSL with a Nix-capable distro; use the default release images instead."
    }
}

function Invoke-WslCapture {
    param(
        [string]$Distro,
        [string]$RepoPath,
        [string]$Script
    )

    # Write the script to a temp file with LF-only endings and pass the path to
    # bash directly.  This sidesteps both PowerShell's CRLF injection and all
    # wsl.exe argument-quoting issues with bash -c / stdin piping.
    $tmp = Save-WslTempScript -Script $Script
    try {
        $output = & wsl.exe -d $Distro --cd $RepoPath -- bash -l $tmp.Wsl
        if ($LASTEXITCODE -ne 0) {
            throw "WSL command failed with exit code ${LASTEXITCODE}: $Script"
        }
        return ($output -join "`n").Trim()
    } finally {
        Remove-Item -LiteralPath $tmp.Win -ErrorAction SilentlyContinue
    }
}

function Invoke-WslInteractive {
    param(
        [string]$Distro,
        [string]$RepoPath,
        [string]$Script
    )

    $tmp = Save-WslTempScript -Script $Script
    try {
        & wsl.exe -d $Distro --cd $RepoPath -- bash -l $tmp.Wsl
        if ($LASTEXITCODE -ne 0) {
            throw "WSL command failed with exit code ${LASTEXITCODE}: $Script"
        }
    } finally {
        Remove-Item -LiteralPath $tmp.Win -ErrorAction SilentlyContinue
    }
}

function Convert-LinuxPathToWindows {
    param(
        [string]$Distro,
        [string]$LinuxPath
    )

    $output = & wsl.exe -d $Distro --cd / -- wslpath -w $LinuxPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to convert WSL path to Windows path: $LinuxPath"
    }
    return ($output -join "`n").Trim()
}

function Get-QubixManifestFromWsl {
    param(
        [string]$Distro,
        [string]$RepoPath
    )

    $json = Invoke-WslCapture -Distro $Distro -RepoPath $RepoPath `
        -Script 'manifest_path=$(nix build --no-link --print-out-paths .#qubix-manifest-json | tr -d ''\r''); cat "$manifest_path"'

    $manifest = $json | ConvertFrom-Json
    Assert-ManifestSchema -Manifest $manifest
    return $manifest
}

function Build-QubixImagesInWsl {
    param(
        [object]$Config,
        [string]$Distro,
        [string]$RepoPath
    )

    $package = [string](Get-Prop $Config 'package')
    $homePackage = [string](Get-Prop $Config 'homePackage' '')

    Write-Host "=== Building .#$package in WSL distro '$Distro' ==="
    Invoke-WslInteractive -Distro $Distro -RepoPath $RepoPath -Script "nix build -L .#$package"

    # --print-out-paths gives the absolute store path; wslpath -w and Copy-Item
    # need absolute paths, and the 'result' symlink would resolve relative to /.
    $vhdxLinux = Invoke-WslCapture -Distro $Distro -RepoPath $RepoPath `
        -Script "out=`$(nix build --no-link --print-out-paths .#$package | tr -d '\r'); find -L `"`$out`" -type f -name '*.vhdx' -print -quit"
    if ([string]::IsNullOrWhiteSpace($vhdxLinux)) {
        throw "Build completed, but no .vhdx file was found in the output of .#$package."
    }

    $homeWindows = ''
    if ($homePackage) {
        Write-Host "=== Building .#$homePackage in WSL distro '$Distro' ==="
        Invoke-WslInteractive -Distro $Distro -RepoPath $RepoPath -Script "nix build -L .#$homePackage"
        $homeLinux = Invoke-WslCapture -Distro $Distro -RepoPath $RepoPath `
            -Script "nix build --no-link --print-out-paths .#$homePackage | tr -d '\r'"
        $homeWindows = Convert-LinuxPathToWindows -Distro $Distro -LinuxPath $homeLinux
    }

    $version = Invoke-WslCapture -Distro $Distro -RepoPath $RepoPath `
        -Script "git describe --always --dirty 2>/dev/null || echo wsl-build"

    $systemWindows = Convert-LinuxPathToWindows -Distro $Distro -LinuxPath $vhdxLinux
    Write-Host "System image: $systemWindows"
    if ($homeWindows) { Write-Host "Home seed:    $homeWindows" }

    return @{ System = $systemWindows; Home = $homeWindows; Version = "wsl:$version" }
}

# --------------------------------------------------------------------------
# GitHub release path (default)
# --------------------------------------------------------------------------

function Resolve-ReleaseTag {
    param(
        [string]$Repo,
        [string]$Release
    )

    if ($Release -ne 'latest') { return $Release }

    # /releases/latest answers with a redirect to /releases/tag/<tag>.  Read the
    # Location header instead of following it: no API, no token, no JSON.
    $url = "https://github.com/$Repo/releases/latest"
    $request = [System.Net.HttpWebRequest]::Create($url)
    $request.AllowAutoRedirect = $false
    $request.Method = 'HEAD'
    $request.UserAgent = 'qubixctl'

    $response = $null
    try {
        $response = $request.GetResponse()
    } catch [System.Net.WebException] {
        if ($null -eq $_.Exception.Response) { throw }
        $response = $_.Exception.Response
    }

    try {
        $location = [string]$response.Headers['Location']
    } finally {
        $response.Close()
    }

    if ($location -notmatch '/releases/tag/([^/?#]+)') {
        throw "Could not resolve the latest release of $Repo (no redirect to /releases/tag/...). Publish a release, pass -Release <tag>, or use -ImageSource wsl."
    }
    return [uri]::UnescapeDataString($matches[1])
}

function Invoke-Download {
    param(
        [string]$Url,
        [string]$OutFile
    )

    $partial = "$OutFile.part"
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }

    # curl.exe ships with Windows 10 1803+ and streams large files far better
    # than Invoke-WebRequest in Windows PowerShell 5.1.
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source --fail --location --retry 3 --retry-delay 2 --progress-bar --output $partial $Url
        if ($LASTEXITCODE -ne 0) {
            throw "curl.exe failed with exit code $LASTEXITCODE while downloading $Url"
        }
    } else {
        Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
    }

    Move-Item -LiteralPath $partial -Destination $OutFile -Force
}

function Read-Sha256SumFile {
    param([string]$Path)

    $sums = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
            $sums[$matches[2]] = $matches[1].ToLowerInvariant()
        }
    }
    return $sums
}

function Assert-FileHash {
    param(
        [string]$Path,
        [string]$Expected
    )

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "SHA256 mismatch for $Path`n  expected $Expected`n  actual   $actual"
    }
}

function Expand-GzipFile {
    param(
        [string]$Path,
        [string]$Destination
    )

    $partial = "$Destination.part"
    $source = [System.IO.File]::OpenRead($Path)
    try {
        $gzip = New-Object System.IO.Compression.GZipStream($source, [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $output = [System.IO.File]::Create($partial)
            try {
                $gzip.CopyTo($output, 4MB)
            } finally {
                $output.Dispose()
            }
        } finally {
            $gzip.Dispose()
        }
    } finally {
        $source.Dispose()
    }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
}

function Get-ReleaseAsset {
    # Returns the path of the unpacked .vhdx for one release asset, downloading,
    # verifying and unpacking it only when the cache does not have it yet.
    param(
        [string]$BaseUrl,
        [string]$Dir,
        [string]$Asset,
        [hashtable]$Sums
    )

    $vhdx = Join-QubixPath $Dir ($Asset -replace '\.gz$', '')
    if (Test-Path -LiteralPath $vhdx) { return $vhdx }

    $gz = Join-QubixPath $Dir $Asset
    if (-not (Test-Path -LiteralPath $gz)) {
        Write-Host "Downloading $BaseUrl/$Asset"
        Invoke-Download -Url "$BaseUrl/$Asset" -OutFile $gz
    }

    if (-not $Sums.ContainsKey($Asset)) {
        throw "SHA256SUMS has no entry for $Asset"
    }
    Assert-FileHash -Path $gz -Expected $Sums[$Asset]

    if ($Asset -like '*.gz') {
        Write-Host "Unpacking $Asset"
        Expand-GzipFile -Path $gz -Destination $vhdx
        Remove-Item -LiteralPath $gz -Force
    }
    return $vhdx
}

function Get-ReleaseImageSet {
    param(
        [object]$Config,
        [object]$Paths,
        [string]$Release
    )

    $release = Get-Prop $Config 'release'
    if ($null -eq $release) {
        throw "The manifest has no 'release' section for this machine. Use -ImageSource wsl or -ImagePath."
    }

    $repo = [string](Get-Prop $release 'repo')
    $tag = Resolve-ReleaseTag -Repo $repo -Release $Release
    $dir = Join-QubixPath $Paths.ImageCache $tag
    $baseUrl = "https://github.com/$repo/releases/download/$tag"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Write-Host "Release $tag of $repo -> $dir"

    $sumsAsset = [string](Get-Prop $release 'sumsAsset' 'SHA256SUMS')
    $sumsFile = Join-QubixPath $dir $sumsAsset
    if (-not (Test-Path -LiteralPath $sumsFile)) {
        Invoke-Download -Url "$baseUrl/$sumsAsset" -OutFile $sumsFile
    }
    $sums = Read-Sha256SumFile -Path $sumsFile

    $system = Get-ReleaseAsset -BaseUrl $baseUrl -Dir $dir -Asset ([string](Get-Prop $release 'systemAsset')) -Sums $sums

    $homeImage = ''
    $homeEnabled = [bool](Get-Prop (Get-Prop $Config 'homeDisk') 'enable' $false)
    if ($homeEnabled) {
        $homeImage = Get-ReleaseAsset -BaseUrl $baseUrl -Dir $dir -Asset ([string](Get-Prop $release 'homeAsset')) -Sums $sums
    }

    return @{ System = $system; Home = $homeImage; Version = $tag }
}

function Get-LocalImageSet {
    param(
        [object]$Config,
        [object]$Paths,
        [string]$ImagePath,
        [string]$HomeImagePath
    )

    if ([string]::IsNullOrWhiteSpace($ImagePath)) {
        throw "-ImageSource file needs -ImagePath <system.vhdx|.vhdx.gz>."
    }
    if (-not (Test-Path -LiteralPath $ImagePath)) {
        throw "Image not found: $ImagePath"
    }

    $homeEnabled = [bool](Get-Prop (Get-Prop $Config 'homeDisk') 'enable' $false)
    if ($homeEnabled -and -not (Test-Path -LiteralPath $Paths.HomeVhdx)) {
        if ([string]::IsNullOrWhiteSpace($HomeImagePath)) {
            throw "This VM has no home disk yet and needs a seed: pass -HomeImagePath <home.vhdx|.vhdx.gz> (nix build .#$(Get-Prop $Config 'homePackage'))."
        }
        if (-not (Test-Path -LiteralPath $HomeImagePath)) {
            throw "Home seed not found: $HomeImagePath"
        }
    }

    $stage = Join-QubixPath $Paths.ImageCache 'local'
    New-Item -ItemType Directory -Force -Path $stage | Out-Null

    $system = $ImagePath
    if ($ImagePath -like '*.gz') {
        $system = Join-QubixPath $stage ((Split-Path -Leaf $ImagePath) -replace '\.gz$', '')
        Write-Host "Unpacking $ImagePath"
        Expand-GzipFile -Path $ImagePath -Destination $system
    }

    $homeImage = $HomeImagePath
    if ($HomeImagePath -and $HomeImagePath -like '*.gz') {
        $homeImage = Join-QubixPath $stage ((Split-Path -Leaf $HomeImagePath) -replace '\.gz$', '')
        Write-Host "Unpacking $HomeImagePath"
        Expand-GzipFile -Path $HomeImagePath -Destination $homeImage
    }

    return @{ System = $system; Home = $homeImage; Version = "file:$(Split-Path -Leaf $ImagePath)" }
}

function Resolve-QubixImageSet {
    param(
        [object]$Config,
        [object]$Paths,
        [hashtable]$Ctx
    )

    $source = $Ctx.ImageSource
    if ($source -eq 'auto') {
        if ([string]::IsNullOrWhiteSpace($Ctx.ImagePath)) { $source = 'release' } else { $source = 'file' }
    }

    switch ($source) {
        'release' { return Get-ReleaseImageSet -Config $Config -Paths $Paths -Release $Ctx.Release }
        'file'    { return Get-LocalImageSet -Config $Config -Paths $Paths -ImagePath $Ctx.ImagePath -HomeImagePath $Ctx.HomeImagePath }
        'wsl'     {
            Assert-WslAvailable
            return Build-QubixImagesInWsl -Config $Config -Distro $Ctx.WslDistro -RepoPath $Ctx.RepoLinuxPath
        }
    }
    throw "Unknown image source '$source'."
}

# --------------------------------------------------------------------------
# Hyper-V networking
# --------------------------------------------------------------------------

function Initialize-QubixNatSwitch {
    param(
        [string]$SwitchName,
        [string]$GatewayIp,
        [string]$Subnet
    )

    # Internal switch - host <-> VM only, no external uplink.
    if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
        Write-Host "Creating Internal Switch '$SwitchName'..."
        New-VMSwitch -SwitchName $SwitchName -SwitchType Internal | Out-Null
    }

    # Assign the gateway IP to the host-side vEthernet adapter.
    $adapterAlias = "vEthernet ($SwitchName)"
    $prefix = [int]($Subnet.Split('/')[1])
    if (-not (Get-NetIPAddress -InterfaceAlias $adapterAlias -IPAddress $GatewayIp -ErrorAction SilentlyContinue)) {
        Write-Host "Assigning $GatewayIp/$prefix to '$adapterAlias'..."
        New-NetIPAddress -IPAddress $GatewayIp -PrefixLength $prefix -InterfaceAlias $adapterAlias | Out-Null
    }

    # Create the NAT rule that gives the VM outbound internet access.
    $natName = "$SwitchName-nat"
    if (-not (Get-NetNat -Name $natName -ErrorAction SilentlyContinue)) {
        Write-Host "Creating NAT '$natName' for $Subnet..."
        New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $Subnet | Out-Null
    }
}

function Resolve-QubixSwitch {
    param(
        [object]$Config,
        [string]$SwitchOverride
    )

    $staticIp = [string](Get-Prop $Config 'staticIp' '')
    if ($staticIp) {
        # Static IP mode: create (or reuse) a dedicated NAT switch so the VM
        # gets a stable address.  The switch name is derived from the hostname.
        $name = Get-EffectiveValue -Override $SwitchOverride -Default "$(Get-Prop $Config 'hostName')-nat"
        Initialize-QubixNatSwitch -SwitchName $name `
            -GatewayIp ([string](Get-Prop $Config 'gatewayIp')) `
            -Subnet ([string](Get-Prop $Config 'natSwitchSubnet'))
        return $name
    }

    # DHCP mode: use Default Switch (or whatever switchName says).
    $name = Get-EffectiveValue -Override $SwitchOverride -Default (Get-Prop $Config 'switchName' 'Default Switch')
    if (-not (Get-VMSwitch -Name $name -ErrorAction SilentlyContinue)) {
        throw "Hyper-V switch '$name' does not exist. Pass -SwitchName or create it in Hyper-V Manager."
    }
    return $name
}

# --------------------------------------------------------------------------
# Hyper-V VM lifecycle
# --------------------------------------------------------------------------

function Initialize-QubixVm {
    param(
        [object]$Config,
        [object]$Paths,
        [string]$SystemImage,
        [string]$HomeImage,
        [string]$Version,
        [string]$SwitchOverride
    )

    $vmName = $Paths.VmName
    $switch = Resolve-QubixSwitch -Config $Config -SwitchOverride $SwitchOverride
    New-Item -ItemType Directory -Force -Path $Paths.VmDir | Out-Null

    Write-Host "Copying system image -> $($Paths.SystemVhdx)"
    Copy-Item -LiteralPath $SystemImage -Destination $Paths.SystemVhdx -Force

    $homeEnabled = [bool](Get-Prop (Get-Prop $Config 'homeDisk') 'enable' $false)
    if ($homeEnabled) {
        if (Test-Path -LiteralPath $Paths.HomeVhdx) {
            Write-Host "Keeping existing home disk $($Paths.HomeVhdx)"
        } else {
            if ([string]::IsNullOrWhiteSpace($HomeImage)) {
                throw "No home seed image available and $($Paths.HomeVhdx) does not exist."
            }
            Write-Host "Seeding home disk -> $($Paths.HomeVhdx)"
            Copy-Item -LiteralPath $HomeImage -Destination $Paths.HomeVhdx -Force
        }
    }

    Write-Host "Creating Generation 2 VM '$vmName' on switch '$switch'"
    New-VM `
        -Name $vmName `
        -Generation 2 `
        -MemoryStartupBytes ([UInt64](Get-Prop $Config 'memoryStartupBytes')) `
        -VHDPath $Paths.SystemVhdx `
        -SwitchName $switch `
        -Path $Paths.VmRoot | Out-Null

    Set-VMProcessor -VMName $vmName -Count ([int](Get-Prop $Config 'cpuCount'))
    Set-VMMemory `
        -VMName $vmName `
        -DynamicMemoryEnabled $true `
        -MinimumBytes 1GB `
        -StartupBytes ([UInt64](Get-Prop $Config 'memoryStartupBytes')) `
        -MaximumBytes ([UInt64](Get-Prop $Config 'maxMemoryBytes'))

    # NixOS images generated for Hyper-V boot cleanly with Secure Boot disabled.
    # Keeping this explicit avoids firmware surprises across Windows installs.
    Set-VMFirmware -VMName $vmName -EnableSecureBoot Off

    if ($homeEnabled) {
        Add-VMHardDiskDrive -VMName $vmName -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 1 -Path $Paths.HomeVhdx
    }
    $bootDisk = Get-VMHardDiskDrive -VMName $vmName -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0
    Set-VMFirmware -VMName $vmName -FirstBootDevice $bootDisk

    # Checkpoints would fork the home disk into .avhdx chains that `recreate`
    # cannot reason about.  Persistence here is the home VHDX, nothing else.
    Set-VM -Name $vmName -CheckpointType Disabled

    Set-Content -LiteralPath $Paths.VersionFile -Value $Version
}

function Get-QubixVm {
    param([object]$Paths)
    return Get-VM -Name $Paths.VmName -ErrorAction SilentlyContinue
}

function Assert-QubixDisksPresent {
    param([object]$Paths)

    foreach ($disk in @(Get-VMHardDiskDrive -VMName $Paths.VmName)) {
        if (-not (Test-Path -LiteralPath $disk.Path)) {
            throw ("VM '$($Paths.VmName)' references a missing disk: $($disk.Path).`n" +
                   "If this is the home disk, restore it from backup; otherwise run 'destroy' and 'up' again.")
        }
    }
}

function Resume-QubixVm {
    param([object]$Vm)

    switch ([string]$Vm.State) {
        'Running' { Write-Host "VM '$($Vm.Name)' is already running." }
        'Paused'  { Write-Host "Resuming VM '$($Vm.Name)'..."; Resume-VM -Name $Vm.Name }
        default   { Write-Host "Starting VM '$($Vm.Name)' (state: $($Vm.State))..."; Start-VM -Name $Vm.Name }
    }
}

function Unregister-QubixVm {
    param(
        [object]$Paths,
        [bool]$PurgeHome
    )

    $vm = Get-QubixVm -Paths $Paths
    if ($vm) {
        if ($vm.State -ne 'Off') {
            Write-Host "Turning off VM '$($Paths.VmName)'..."
            Stop-VM -Name $Paths.VmName -TurnOff -Force
        }
        Write-Host "Removing VM configuration '$($Paths.VmName)'..."
        Remove-VM -Name $Paths.VmName -Force
    }

    if ($PurgeHome) {
        if (Test-Path -LiteralPath $Paths.VmDir) {
            Write-Host "Purging $($Paths.VmDir) (including the home disk)"
            Remove-Item -LiteralPath $Paths.VmDir -Recurse -Force
        }
        return
    }

    foreach ($item in @($Paths.SystemVhdx, $Paths.VersionFile)) {
        if (Test-Path -LiteralPath $item) {
            Write-Host "Removing $item"
            Remove-Item -LiteralPath $item -Force
        }
    }
    foreach ($sub in @('Virtual Machines', 'Snapshots', 'Virtual Hard Disks')) {
        $dir = Join-QubixPath $Paths.VmDir $sub
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force
        }
    }
    if (Test-Path -LiteralPath $Paths.HomeVhdx) {
        Write-Host "Home disk kept: $($Paths.HomeVhdx)  (use -Purge to delete it)"
    }
}

# --------------------------------------------------------------------------
# RDP
# --------------------------------------------------------------------------

function Get-QubixAddress {
    param(
        [object]$Config,
        [string]$Explicit
    )

    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }

    $staticIp = [string](Get-Prop $Config 'staticIp' '')
    if ($staticIp) { return $staticIp }

    # DHCP mode: the guest's hv_kvp_daemon reports its addresses to Hyper-V.
    try {
        foreach ($adapter in @(Get-VMNetworkAdapter -VMName ([string](Get-Prop $Config 'vmName')) -ErrorAction Stop)) {
            foreach ($ip in @($adapter.IPAddresses)) {
                if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$' -and $ip -notlike '169.254.*') { return $ip }
            }
        }
    } catch {
        Write-Verbose "KVP address lookup failed: $($_.Exception.Message)"
    }

    # Last resort: Avahi in the guest, mDNS on the host.
    return "$(Get-Prop $Config 'hostName').local"
}

function Test-TcpPort {
    param(
        [string]$TargetHost,
        [int]$Port,
        [int]$TimeoutMs = 2000
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Wait-QubixRdp {
    param(
        [object]$Config,
        [string]$Explicit,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $address = Get-QubixAddress -Config $Config -Explicit $Explicit
    Write-Host "Waiting for RDP on $address (up to $TimeoutSeconds s)..."

    while ((Get-Date) -lt $deadline) {
        $address = Get-QubixAddress -Config $Config -Explicit $Explicit
        if (Test-TcpPort -TargetHost $address -Port 3389) {
            Write-Host "RDP is up at $address"
            return $address
        }
        Start-Sleep -Seconds 3
    }

    throw "Timed out waiting for RDP on '$address'. Check 'qubixctl -Command status' or open the VM in Hyper-V Manager."
}

function Format-RdpFile {
    param(
        [string]$Address,
        [string]$User,
        [int]$Width,
        [int]$Height
    )

    # Windowed session, audio played on the host, clipboard shared, nothing
    # else redirected.  authentication level 0 accepts xrdp's self-signed cert
    # without a prompt; the lab user is not a secret anyway.
    $lines = @(
        "full address:s:$Address",
        "username:s:$User",
        "screen mode id:i:1",
        "desktopwidth:i:$Width",
        "desktopheight:i:$Height",
        "smart sizing:i:1",
        "dynamic resolution:i:1",
        "audiomode:i:0",
        "audiocapturemode:i:0",
        "redirectclipboard:i:1",
        "redirectdrives:i:0",
        "redirectprinters:i:0",
        "redirectcomports:i:0",
        "redirectsmartcards:i:0",
        "authentication level:i:0",
        "prompt for credentials:i:0",
        "negotiate security layer:i:1",
        "autoreconnection enabled:i:1",
        "compression:i:1",
        "bitmapcachepersistenable:i:1"
    )
    return (($lines -join "`r`n") + "`r`n")
}

function Connect-QubixRdp {
    param(
        [object]$Config,
        [object]$Paths,
        [string]$Address,
        [bool]$SaveCredential
    )

    $rdp = Get-Prop $Config 'rdp'
    $user = [string](Get-Prop $rdp 'user' 'rdp')
    $content = Format-RdpFile -Address $Address -User $user `
        -Width ([int](Get-Prop $rdp 'width' 1280)) -Height ([int](Get-Prop $rdp 'height' 800))

    New-Item -ItemType Directory -Force -Path $Paths.VmDir | Out-Null
    [System.IO.File]::WriteAllText($Paths.RdpFile, $content)

    if ($SaveCredential) {
        $password = [string](Get-Prop $rdp 'password' '')
        if ($password) {
            # Windows Credential Manager entry mstsc looks up for this host.
            & cmdkey.exe /generic:"TERMSRV/$Address" /user:$user /pass:$password | Out-Null
        }
    }

    Write-Host "Opening $($Paths.RdpFile)"
    Start-Process -FilePath 'mstsc.exe' -ArgumentList "`"$($Paths.RdpFile)`""
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

function Invoke-QubixUp {
    param(
        [object]$Config,
        [object]$Paths,
        [hashtable]$Ctx
    )

    Assert-HyperVAvailable
    Assert-Administrator

    $vm = Get-QubixVm -Paths $Paths
    if (-not $vm) {
        Write-Host "=== VM '$($Paths.VmName)' does not exist yet: creating it ==="
        $images = Resolve-QubixImageSet -Config $Config -Paths $Paths -Ctx $Ctx
        Initialize-QubixVm -Config $Config -Paths $Paths `
            -SystemImage $images.System -HomeImage $images.Home -Version $images.Version `
            -SwitchOverride $Ctx.SwitchName
        $vm = Get-QubixVm -Paths $Paths
    } else {
        Assert-QubixDisksPresent -Paths $Paths
        $imageOptionsGiven = ($Ctx.ImageSource -ne 'auto') -or ($Ctx.Release -ne 'latest') -or
            -not [string]::IsNullOrWhiteSpace($Ctx.ImagePath)
        if ($imageOptionsGiven) {
            Write-Host "VM '$($Paths.VmName)' already exists; image options only apply to 'recreate'."
        }
    }

    Resume-QubixVm -Vm $vm

    if ($Ctx.NoConnect) { return }
    $address = Wait-QubixRdp -Config $Config -Explicit $Ctx.Address -TimeoutSeconds $Ctx.TimeoutSeconds
    Connect-QubixRdp -Config $Config -Paths $Paths -Address $address -SaveCredential $Ctx.SaveCredential
}

function Invoke-QubixConnect {
    param(
        [object]$Config,
        [object]$Paths,
        [hashtable]$Ctx
    )

    $address = Wait-QubixRdp -Config $Config -Explicit $Ctx.Address -TimeoutSeconds $Ctx.TimeoutSeconds
    Connect-QubixRdp -Config $Config -Paths $Paths -Address $address -SaveCredential $Ctx.SaveCredential
}

function Invoke-QubixStatus {
    param(
        [object]$Config,
        [object]$Paths
    )

    Assert-HyperVAvailable

    $vm = Get-QubixVm -Paths $Paths
    if (-not $vm) {
        Write-Host "VM '$($Paths.VmName)' does not exist. Run 'up' to create it."
    } else {
        $vm | Format-Table -AutoSize Name, State, CPUUsage, MemoryAssigned, Uptime, Status
        Get-VMNetworkAdapter -VMName $Paths.VmName | Format-Table -AutoSize Name, SwitchName, Status, IPAddresses
        Get-VMHardDiskDrive -VMName $Paths.VmName | Format-Table -AutoSize ControllerLocation, Path
    }

    if (Test-Path -LiteralPath $Paths.VersionFile) {
        Write-Host "Installed image: $((Get-Content -LiteralPath $Paths.VersionFile -Raw).Trim())"
    }
    Write-Host "Home disk:       $($Paths.HomeVhdx) $(if (Test-Path -LiteralPath $Paths.HomeVhdx) { '(present)' } else { '(absent)' })"
    Write-Host "Address:         $(Get-QubixAddress -Config $Config -Explicit '')"

    if (Test-Path -LiteralPath $Paths.ImageCache) {
        $cached = @(Get-ChildItem -LiteralPath $Paths.ImageCache -Directory | ForEach-Object { $_.Name })
        if ($cached.Count -gt 0) { Write-Host "Cached images:   $($cached -join ', ')  ($($Paths.ImageCache))" }
    }
}

function Invoke-QubixRecreate {
    param(
        [object]$Config,
        [object]$Paths,
        [hashtable]$Ctx
    )

    Assert-HyperVAvailable
    Assert-Administrator

    Write-Host "=== Recreating '$($Paths.VmName)' with fresh images (home disk is kept) ==="
    Unregister-QubixVm -Paths $Paths -PurgeHome $false
    Invoke-QubixUp -Config $Config -Paths $Paths -Ctx $Ctx
}

function Invoke-QubixDestroy {
    param(
        [object]$Paths,
        [bool]$PurgeHome
    )

    Assert-HyperVAvailable
    Assert-Administrator
    Unregister-QubixVm -Paths $Paths -PurgeHome $PurgeHome
}

function Invoke-QubixMain {
    $ctx = @{
        ImageSource     = $ImageSource
        ImagePath       = $ImagePath
        HomeImagePath   = $HomeImagePath
        Release         = $Release
        WslDistro       = ''
        RepoLinuxPath   = ''
        SwitchName      = $SwitchName
        Address         = $Address
        TimeoutSeconds  = $TimeoutSeconds
        NoConnect       = [bool]$NoConnect
        SaveCredential  = -not [bool]$NoSavedCredential
    }

    $needsWsl = ($ImageSource -eq 'wsl') -or ($Command -eq 'build')
    if ($needsWsl) {
        # Developer loop: the manifest comes straight from Nix so that edits to
        # machines/*.nix are honoured without regenerating manifest.json first.
        Assert-WslAvailable
        $wsl = Resolve-WslRepoLocation -DistroOverride $WslDistro -LinuxPathOverride $RepoLinuxPath
        $ctx.WslDistro = $wsl.Distro
        $ctx.RepoLinuxPath = $wsl.RepoPath
        $ctx.ImageSource = 'wsl'
        $manifest = Get-QubixManifestFromWsl -Distro $wsl.Distro -RepoPath $wsl.RepoPath
    } else {
        $manifest = Read-QubixManifest -Path (Get-EffectiveValue -Override $ManifestPath -Default (Get-DefaultManifestPath))
    }

    $config = Resolve-MachineConfig -Manifest $manifest -Name $Machine
    $paths = Get-QubixLayout -Config $config -VmRootOverride $VmRoot

    switch ($Command) {
        'up'       { Invoke-QubixUp -Config $config -Paths $paths -Ctx $ctx }
        'connect'  { Invoke-QubixConnect -Config $config -Paths $paths -Ctx $ctx }
        'start'    {
            Assert-HyperVAvailable
            Assert-Administrator
            $vm = Get-QubixVm -Paths $paths
            if (-not $vm) { throw "VM '$($paths.VmName)' does not exist. Run 'up' first." }
            Resume-QubixVm -Vm $vm
        }
        'stop'     {
            Assert-HyperVAvailable
            Assert-Administrator
            Stop-VM -Name $paths.VmName -Force
        }
        'status'   { Invoke-QubixStatus -Config $config -Paths $paths }
        'recreate' { Invoke-QubixRecreate -Config $config -Paths $paths -Ctx $ctx }
        'destroy'  { Invoke-QubixDestroy -Paths $paths -PurgeHome ([bool]$Purge) }
        'fetch'    {
            $images = Get-ReleaseImageSet -Config $config -Paths $paths -Release $Release
            Write-Host "System image: $($images.System)"
            if ($images.Home) { Write-Host "Home seed:    $($images.Home)" }
        }
        'build'    {
            Build-QubixImagesInWsl -Config $config -Distro $ctx.WslDistro -RepoPath $ctx.RepoLinuxPath | Out-Null
        }
        'manifest' { $config | ConvertTo-Json -Depth 8 }
    }
}

# Dot-source the script to load the functions without running anything
# (used by the tests); every other invocation runs the command.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-QubixMain
}
