param(
    [ValidateSet("build", "recreate", "start", "stop", "destroy", "status", "mstsc")]
    [string]$Command = "status",

    [string]$Machine = "spotibox",
    [string]$WslDistro = "",
    [string]$RepoLinuxPath = "/home/nixos/Documents/repos/qubix",
    [string]$VmRoot = "",
    [string]$SwitchName = "",
    [string]$Address = ""
)

$ErrorActionPreference = "Stop"

function New-WslTempScript {
    param([string]$Script)

    # GetTempFileName creates a file like C:\Users\...\AppData\Local\Temp\tmpXXXX.tmp
    $winPath = [System.IO.Path]::GetTempFileName()

    # Write script bytes directly — no BOM, LF-only line endings.
    # PowerShell's pipe (|) appends \r\n; WriteAllBytes avoids that entirely.
    [System.IO.File]::WriteAllBytes(
        $winPath,
        [System.Text.Encoding]::UTF8.GetBytes($Script + "`n")
    )

    # Convert Windows path to WSL /mnt/<drive>/... path.
    $wslPath = "/mnt/" + $winPath[0].ToString().ToLower() + "/" +
               $winPath.Substring(3).Replace("\", "/")

    return [PSCustomObject]@{ Win = $winPath; Wsl = $wslPath }
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
    $tmp = New-WslTempScript -Script $Script
    try {
        $output = & wsl.exe -d $Distro --cd $RepoPath -- bash -l $tmp.Wsl
        if ($LASTEXITCODE -ne 0) {
            throw "WSL command failed with exit code ${LASTEXITCODE}: $Script"
        }
        return ($output -join "`n").Trim()
    } finally {
        Remove-Item $tmp.Win -ErrorAction SilentlyContinue
    }
}

function Invoke-WslInteractive {
    param(
        [string]$Distro,
        [string]$RepoPath,
        [string]$Script
    )

    $tmp = New-WslTempScript -Script $Script
    try {
        & wsl.exe -d $Distro --cd $RepoPath -- bash -l $tmp.Wsl
        if ($LASTEXITCODE -ne 0) {
            throw "WSL command failed with exit code ${LASTEXITCODE}: $Script"
        }
    } finally {
        Remove-Item $tmp.Win -ErrorAction SilentlyContinue
    }
}

function Get-QubixManifest {
    param(
        [string]$Distro,
        [string]$RepoPath
    )

    $json = Invoke-WslCapture `
        -Distro $Distro `
        -RepoPath $RepoPath `
        -Script 'manifest_path=$(nix build --no-link --print-out-paths .#qubix-manifest-json | tr -d ''\r''); cat "$manifest_path"'

    return $json | ConvertFrom-Json
}

function Resolve-MachineConfig {
    param(
        [object]$Manifest,
        [string]$Name
    )

    $config = $Manifest.PSObject.Properties[$Name].Value
    if (-not $config) {
        throw "Machine '$Name' was not found in the Nix-generated Qubix manifest."
    }

    return $config
}

function Assert-HyperVAvailable {
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        throw "Hyper-V PowerShell cmdlets are not available. Enable Hyper-V and run this from Windows PowerShell."
    }
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this command from an elevated PowerShell session."
    }
}

function Ensure-QubixNatSwitch {
    param(
        [string]$SwitchName,
        [string]$GatewayIp,
        [string]$Subnet
    )

    # Internal switch — host <-> VM only, no external uplink.
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

function Build-QubixMachine {
    param(
        [object]$Config,
        [string]$Distro,
        [string]$RepoPath
    )

    Write-Host "=== Building $($Config.package) in WSL distro '$Distro' ==="
    Invoke-WslInteractive -Distro $Distro -RepoPath $RepoPath -Script "nix build .#$($Config.package)"

    # realpath resolves the 'result' nix symlink to an absolute store path
    # (/nix/store/...).  wslpath -w and Copy-Item require an absolute path;
    # a relative path gets resolved from / and the copy fails.
    $vhdxLinuxPath = Invoke-WslCapture `
        -Distro $Distro `
        -RepoPath $RepoPath `
        -Script "find -L result -type f -name '*.vhdx' -print -quit | xargs -r realpath"

    if ([string]::IsNullOrWhiteSpace($vhdxLinuxPath)) {
        throw "Build completed, but no .vhdx file was found under ./result."
    }

    $vhdxWindowsPath = Convert-LinuxPathToWindows -Distro $Distro -LinuxPath $vhdxLinuxPath
    Write-Host "VHDX: $vhdxWindowsPath"
    return $vhdxWindowsPath
}

function Recreate-QubixVm {
    param(
        [object]$Config,
        [string]$Distro,
        [string]$RepoPath,
        [string]$VmRootOverride,
        [string]$SwitchOverride
    )

    Assert-HyperVAvailable
    Assert-Administrator

    $sourceVhdx = Build-QubixMachine -Config $Config -Distro $Distro -RepoPath $RepoPath
    $vmName = [string]$Config.vmName
    $effectiveVmRoot = Get-EffectiveValue -Override $VmRootOverride -Default $Config.vmRoot

    if (-not [string]::IsNullOrEmpty($Config.staticIp)) {
        # Static IP mode: create (or reuse) a dedicated NAT switch so the VM
        # gets a stable address.  The switch name is derived from the hostname.
        $defaultNatSwitch = "$($Config.hostName)-nat"
        $effectiveSwitchName = Get-EffectiveValue -Override $SwitchOverride -Default $defaultNatSwitch
        Ensure-QubixNatSwitch `
            -SwitchName $effectiveSwitchName `
            -GatewayIp ([string]$Config.gatewayIp) `
            -Subnet ([string]$Config.natSwitchSubnet)
    } else {
        # DHCP mode: use Default Switch (or whatever switchName says).
        $effectiveSwitchName = Get-EffectiveValue -Override $SwitchOverride -Default $Config.switchName
    }
    $vmPath = Join-Path $effectiveVmRoot $vmName
    $vhdPath = Join-Path $vmPath "$vmName.vhdx"

    Write-Host "=== Recreating Hyper-V VM '$vmName' ==="

    $existingVm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($existingVm) {
        if ($existingVm.State -ne 'Off') {
            Write-Host "Stopping existing VM..."
            Stop-VM -Name $vmName -TurnOff -Force
        }
        Write-Host "Removing existing VM configuration..."
        Remove-VM -Name $vmName -Force
    }

    if (Test-Path $vmPath) {
        Write-Host "Removing old VM directory: $vmPath"
        Remove-Item -Path $vmPath -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $vmPath | Out-Null

    Write-Host "Copying VHDX to $vhdPath"
    Copy-Item -Path $sourceVhdx -Destination $vhdPath -Force

    Write-Host "Creating Generation 2 VM on switch '$effectiveSwitchName'"
    New-VM `
        -Name $vmName `
        -Generation 2 `
        -MemoryStartupBytes ([UInt64]$Config.memoryStartupBytes) `
        -VHDPath $vhdPath `
        -SwitchName $effectiveSwitchName `
        -Path $vmPath | Out-Null

    Set-VMProcessor -VMName $vmName -Count ([int]$Config.cpuCount)
    Set-VMMemory `
        -VMName $vmName `
        -DynamicMemoryEnabled $true `
        -MinimumBytes 1GB `
        -StartupBytes ([UInt64]$Config.memoryStartupBytes) `
        -MaximumBytes ([UInt64]$Config.maxMemoryBytes)

    # NixOS images generated for Hyper-V boot cleanly with Secure Boot disabled.
    # Keeping this explicit avoids firmware surprises across Windows installs.
    Set-VMFirmware -VMName $vmName -EnableSecureBoot Off

    Start-VM -Name $vmName
    Write-Host "=== VM '$vmName' is running ==="
}

function Start-QubixVm {
    param([object]$Config)

    Assert-HyperVAvailable
    Start-VM -Name ([string]$Config.vmName)
}

function Stop-QubixVm {
    param([object]$Config)

    Assert-HyperVAvailable
    Stop-VM -Name ([string]$Config.vmName) -Force
}

function Destroy-QubixVm {
    param(
        [object]$Config,
        [string]$VmRootOverride
    )

    Assert-HyperVAvailable
    Assert-Administrator

    $vmName = [string]$Config.vmName
    $effectiveVmRoot = Get-EffectiveValue -Override $VmRootOverride -Default $Config.vmRoot
    $vmPath = Join-Path $effectiveVmRoot $vmName

    $existingVm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($existingVm) {
        Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue
        Remove-VM -Name $vmName -Force
    }

    if (Test-Path $vmPath) {
        Remove-Item -Path $vmPath -Recurse -Force
    }
}

function Show-QubixStatus {
    param([object]$Config)

    Assert-HyperVAvailable

    $vmName = [string]$Config.vmName
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Host "VM '$vmName' does not exist."
        return
    }

    $vm | Format-Table -AutoSize Name, State, CPUUsage, MemoryAssigned, Uptime, Status
    Get-VMNetworkAdapter -VMName $vmName | Format-Table -AutoSize Name, SwitchName, Status, IPAddresses
}

function Open-QubixMstsc {
    param(
        [object]$Config,
        [string]$ExplicitAddress
    )

    if ([string]::IsNullOrWhiteSpace($ExplicitAddress)) {
        $target = "$($Config.hostName).local"
    } else {
        $target = $ExplicitAddress
    }

    Write-Host "Opening mstsc for $target"
    Start-Process "mstsc.exe" -ArgumentList "/v:$target"
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "wsl.exe was not found. Qubix MVP expects Windows PowerShell with WSL available."
}

$bootstrapDistro = $WslDistro
if ([string]::IsNullOrWhiteSpace($bootstrapDistro)) {
    $bootstrapDistro = "NixOS"
}

$manifest = Get-QubixManifest -Distro $bootstrapDistro -RepoPath $RepoLinuxPath
$config = Resolve-MachineConfig -Manifest $manifest -Name $Machine

$effectiveDistro = Get-EffectiveValue -Override $WslDistro -Default $config.wslDistro
if ($effectiveDistro -ne $bootstrapDistro) {
    $manifest = Get-QubixManifest -Distro $effectiveDistro -RepoPath $RepoLinuxPath
    $config = Resolve-MachineConfig -Manifest $manifest -Name $Machine
}

switch ($Command) {
    "build" {
        Build-QubixMachine -Config $config -Distro $effectiveDistro -RepoPath $RepoLinuxPath | Out-Null
    }
    "recreate" {
        Recreate-QubixVm `
            -Config $config `
            -Distro $effectiveDistro `
            -RepoPath $RepoLinuxPath `
            -VmRootOverride $VmRoot `
            -SwitchOverride $SwitchName
    }
    "start" {
        Start-QubixVm -Config $config
    }
    "stop" {
        Stop-QubixVm -Config $config
    }
    "destroy" {
        Destroy-QubixVm -Config $config -VmRootOverride $VmRoot
    }
    "status" {
        Show-QubixStatus -Config $config
    }
    "mstsc" {
        Open-QubixMstsc -Config $config -ExplicitAddress $Address
    }
}
