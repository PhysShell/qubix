<#
.SYNOPSIS
    Checks the promises only a real Hyper-V host can prove, and writes the
    evidence down.

.DESCRIPTION
    tools/cold-boot.sh boots the shipped VHDX under OVMF and gets as far as an
    RDP reply, which proves the boot loader, the kernel, the filesystems, the
    network and xrdp.  It cannot prove anything Hyper-V specific, because there
    is no VMBus in QEMU - and profiles/kernel/hyperv.nix now builds a kernel
    whose entire hardware story is VMBus, while profiles/modes/prod.nix
    replaces Microsoft's Integration Services with a hand-picked subset.

    Three claims rest on that, and nothing in this repository can reach them:

      Dynamic Memory   hv_balloon is loaded, the host sees the guest's demand,
                       and hot-added memory blocks are brought online by the
                       udev rules copied into profiles/modes/prod.nix.  Raising
                       the VM's floor above what the guest currently has makes
                       the host hand it memory; the guest only ends up holding
                       it if the driver and the rules both work, so watching
                       MemoryAssigned follow tests the whole chain rather than
                       the presence of a package.
      Host shutdown    hv_utils answers the host's shutdown request, so
                       `Stop-VM` without -Force reaches Off.  There is no
                       userspace daemon in that path: the kernel calls
                       orderly_poweroff() itself, which is exactly why dropping
                       hv_vss_daemon and hv_fcopy_uio_daemon is supposed to be
                       safe.
      KVP              hv_kvp_daemon reports the guest's addresses back to the
                       host.  That is what Get-QubixAddress falls back to for
                       machines without a static IP, and it is the reason that
                       one daemon was kept when the other two were not.

    A failing shutdown is never rescued with -Force here.  The VM is left
    running and the run ends FAIL, because forcing it off would destroy the
    only evidence that the shutdown path is broken.

    Everything is timed and written to -ReportPath.  Six months from now, a
    hot-add that takes 55 seconds instead of 4 is the kind of degradation that
    creeps in quietly, and there is no way to notice it without the earlier
    number to compare against.

    The script changes the VM's memory floor while it runs and restores it, and
    it stops and starts the VM.  Run it against a lab machine.

.PARAMETER Machine
    Manifest machine name.  Default: spotibox.

.PARAMETER TimeoutSeconds
    Deadline for each of RDP, memory convergence and shutdown.

.PARAMETER ReportPath
    Where to write the evidence.  Defaults to an `acceptance-<timestamp>.txt`
    next to the VM, beside the image-version.txt qubixctl writes there, so a
    run always leaves a record and it is always somewhere findable.  Attach it
    to the release.

.EXAMPLE
    .\tools\qubix-acceptance.cmd
    .\tools\qubix-acceptance.cmd -ReportPath C:\temp\acceptance-v0.3.0.txt

.NOTES
    Needs an elevated shell: the Hyper-V cmdlets do.  tools\qubix-acceptance.cmd
    elevates, sets a process-scoped execution policy and passes arguments
    through, which is also what makes it work from a \\wsl.localhost\... path.
#>

[CmdletBinding()]
param(
    [string]$Machine = 'spotibox',
    [string]$ManifestPath = '',
    [string]$VmRoot = '',
    [int]$TimeoutSeconds = 300,
    [string]$ReportPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Results = @()
$script:Notes = @()

function Add-Result {
    param(
        [string]$Name,
        [string]$Result,
        [string]$Detail,
        [double]$Seconds = -1
    )

    $took = if ($Seconds -ge 0) { '{0:N1}s' -f $Seconds } else { '' }
    $script:Results += [PSCustomObject]@{
        Check   = $Name
        Result  = $Result
        Took    = $took
        Detail  = $Detail
    }
    $colour = switch ($Result) {
        'PASS' { 'Green' }
        'SKIP' { 'Yellow' }
        default { 'Red' }
    }
    Write-Host ("{0,-26} {1,-4} {2,7}  {3}" -f $Name, $Result, $took, $Detail) -ForegroundColor $colour
}

function Add-Note {
    param([string]$Line)
    $script:Notes += $Line
}

function Get-ManifestMachine {
    param([string]$Path, [string]$Name)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path (Split-Path -Parent $PSScriptRoot) 'manifest.json'
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Manifest not found: $Path"
    }
    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$manifest.schemaVersion -ne 2) {
        throw "Unsupported manifest schemaVersion '$($manifest.schemaVersion)' (expected 2)."
    }
    $machine = $manifest.machines.PSObject.Properties |
        Where-Object { $_.Name -eq $Name } |
        ForEach-Object { $_.Value }
    if ($null -eq $machine) {
        throw "Machine '$Name' is not in the manifest."
    }
    return $machine
}

function Get-QubixVmDir {
    # Where qubixctl keeps everything belonging to one VM: its disks, its
    # generated .rdp file, and the image-version.txt it writes when it installs
    # a system disk.
    param([object]$Config, [string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = if ($Config.PSObject.Properties.Name -contains 'vmRoot') {
            [string]$Config.vmRoot
        } else {
            'C:\HyperV\Qubix'
        }
    }
    return Join-Path $Root ([string]$Config.vmName)
}

function Get-ImageRevision {
    param([string]$VmDir)

    $file = Join-Path $VmDir 'image-version.txt'
    if (Test-Path -LiteralPath $file) {
        return (Get-Content -LiteralPath $file -Raw).Trim()
    }
    return 'unknown (no image-version.txt - was this VM created by qubixctl?)'
}

function Test-XrdpHandshake {
    # A forwarded or half-open socket accepts a connection whether or not
    # anything is listening behind it, so this sends an X.224 Connection
    # Request with an RDP negotiation request and insists on a TPKT reply.
    param([string]$TargetHost, [int]$Port = 3389, [int]$TimeoutMs = 8000)

    $request = [byte[]]@(
        0x03, 0x00, 0x00, 0x13, 0x0E, 0xE0, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x00, 0x08, 0x00, 0x03, 0x00, 0x00, 0x00)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.Write($request, 0, $request.Length)
        $buffer = New-Object byte[] 64
        $read = $stream.Read($buffer, 0, $buffer.Length)
        return ($read -ge 2 -and $buffer[0] -eq 0x03 -and $buffer[1] -eq 0x00)
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Wait-ForXrdp {
    param([string]$TargetHost, [int]$Seconds)

    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-XrdpHandshake -TargetHost $TargetHost) { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Wait-ForVmState {
    param([string]$Name, [string]$State, [int]$Seconds)

    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-VM -Name $Name).State -eq $State) { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Get-ReportedIPv4 {
    # What the host can see comes from hv_kvp_daemon inside the guest.  Only
    # routable IPv4 counts: link-local means the guest answered with an address
    # it made up itself, which proves nothing about the static configuration.
    param([string]$Name)

    return @(Get-VMNetworkAdapter -VMName $Name |
        ForEach-Object { $_.IPAddresses } |
        Where-Object { $_ -and $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' })
}

# --------------------------------------------------------------------------

if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    throw 'The Hyper-V PowerShell module is not available. Run this on the Hyper-V host, elevated.'
}

$config = Get-ManifestMachine -Path $ManifestPath -Name $Machine
$vmName = [string]$config.vmName
if (-not ($config.PSObject.Properties.Name -contains 'staticIp')) {
    throw ("Machine '$Machine' has no staticIp in the manifest. This script checks that the guest " +
           'comes back on the same address across a shutdown, which needs one to compare against.')
}
$address = [string]$config.staticIp

$vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if ($null -eq $vm) {
    throw "VM '$vmName' does not exist. Create it first: tools\qubixctl.cmd"
}

$vmDir = Get-QubixVmDir -Config $config -Root $VmRoot
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    # Always leave a record, and always somewhere findable.  A relative path
    # would land wherever the elevated shell happened to start, which is
    # system32 often enough to be a nuisance.
    $ReportPath = Join-Path $vmDir ('acceptance-{0:yyyyMMdd-HHmmss}.txt' -f (Get-Date))
}

$startedAt = Get-Date
Add-Note ("run started        : {0:o}" -f $startedAt)
Add-Note ("image revision     : {0}" -f (Get-ImageRevision -VmDir $vmDir))
Add-Note ("Hyper-V host       : {0} ({1})" -f $env:COMPUTERNAME, [System.Environment]::OSVersion.VersionString)
Add-Note ("VM                 : {0}" -f $vmName)
Add-Note ("VM generation      : {0}" -f $vm.Generation)
Add-Note ("VM config version  : {0}" -f $vm.Version)
Add-Note ("expected address   : {0}" -f $address)

Write-Host "Hyper-V acceptance for $vmName at $address" -ForegroundColor Cyan
$script:Notes | ForEach-Object { Write-Host "  $_" }
Write-Host ''

# 1. Cold boot ------------------------------------------------------------
if ((Get-VM -Name $vmName).State -ne 'Off') {
    Stop-VM -Name $vmName -Force -Confirm:$false
    $null = Wait-ForVmState -Name $vmName -State 'Off' -Seconds 60
}
$watch = [System.Diagnostics.Stopwatch]::StartNew()
Start-VM -Name $vmName
$booted = Wait-ForXrdp -TargetHost $address -Seconds $TimeoutSeconds
$watch.Stop()
Add-Result -Name 'cold boot #1' -Result $(if ($booted) { 'PASS' } else { 'FAIL' }) `
    -Seconds $watch.Elapsed.TotalSeconds -Detail $(
    if ($booted) { "xrdp answered an X.224 connection request on $address" }
    else { "no X.224 reply from $address within $TimeoutSeconds s" })
if (-not $booted) {
    Write-Host 'Stopping here: nothing below can be trusted on a VM that did not boot.' -ForegroundColor Yellow
    $script:Results | Format-Table -AutoSize | Out-String | Write-Host
    exit 1
}

# 2. KVP ------------------------------------------------------------------
# Give the daemon a moment after boot: it reports once networking has settled.
$watch = [System.Diagnostics.Stopwatch]::StartNew()
$reported = @()
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    $reported = Get-ReportedIPv4 -Name $vmName
    if ($reported -contains $address) { break }
    Start-Sleep -Seconds 5
}
$watch.Stop()
$kvpOk = $reported -contains $address
Add-Result -Name 'KVP expected IPv4' -Result $(if ($kvpOk) { 'PASS' } else { 'FAIL' }) `
    -Seconds $watch.Elapsed.TotalSeconds -Detail $(
    if ($kvpOk) { "host sees $address" }
    elseif ($reported.Count -gt 0) { "host sees $($reported -join ', ') but not $address" }
    else { 'host sees no routable IPv4 - hv_kvp_daemon is not reporting' })

$shutdownIc = Get-VMIntegrationService -VMName $vmName -Name 'Shutdown'
Add-Result -Name 'shutdown service' -Result $(
    if ($shutdownIc.PrimaryStatusDescription -eq 'OK') { 'PASS' } else { 'FAIL' }) `
    -Detail "status: $($shutdownIc.PrimaryStatusDescription)"

# 3. Dynamic Memory -------------------------------------------------------
$mem = Get-VMMemory -VMName $vmName
if (-not $mem.DynamicMemoryEnabled) {
    Add-Result -Name 'memory demand' -Result 'SKIP' -Detail 'Dynamic Memory is off on this VM'
    Add-Result -Name 'memory hot-add' -Result 'SKIP' -Detail 'enable Dynamic Memory (VM off) and re-run'
} else {
    $demand = (Get-VM -Name $vmName).MemoryDemand
    Add-Result -Name 'memory demand' -Result $(if ($demand -gt 0) { 'PASS' } else { 'FAIL' }) -Detail $(
        if ($demand -gt 0) { "guest reports {0} MiB in use" -f [math]::Round($demand / 1MB) }
        else { 'host sees no demand - hv_balloon is not talking' })

    $originalMinimum = $mem.Minimum
    $assignedBefore = (Get-VM -Name $vmName).MemoryAssigned
    $target = [math]::Min($assignedBefore + 512MB, $mem.Maximum)
    $series = @()
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Set-VMMemory -VMName $vmName -MinimumBytes $target
        $grew = $false
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            $now = Get-VM -Name $vmName
            $series += [PSCustomObject]@{
                At          = '{0:N1}s' -f $watch.Elapsed.TotalSeconds
                AssignedMiB = [math]::Round($now.MemoryAssigned / 1MB)
                DemandMiB   = [math]::Round($now.MemoryDemand / 1MB)
            }
            if ($now.MemoryAssigned -ge $target) { $grew = $true; break }
            Start-Sleep -Seconds 3
        }
        $watch.Stop()
        $assignedAfter = (Get-VM -Name $vmName).MemoryAssigned
        Add-Result -Name 'memory hot-add' -Result $(if ($grew) { 'PASS' } else { 'FAIL' }) `
            -Seconds $watch.Elapsed.TotalSeconds -Detail (
            '{0} MiB -> {1} MiB (floor raised to {2} MiB)' -f `
                [math]::Round($assignedBefore / 1MB),
                [math]::Round($assignedAfter / 1MB),
                [math]::Round($target / 1MB))
        Add-Note ''
        Add-Note 'memory hot-add, as it converged:'
        $series | ForEach-Object {
            Add-Note ('  {0,7}  assigned {1,6} MiB  demand {2,6} MiB' -f $_.At, $_.AssignedMiB, $_.DemandMiB)
        }
    } finally {
        Set-VMMemory -VMName $vmName -MinimumBytes $originalMinimum
    }
}

# 4. Host-requested shutdown ----------------------------------------------
# No -Force, and no -Force afterwards either: if hv_utils did not answer, the
# VM stays up so that somebody can look at it.  Forcing it off here would
# delete the only evidence of the failure this check exists to find.
$watch = [System.Diagnostics.Stopwatch]::StartNew()
Stop-VM -Name $vmName -Confirm:$false -ErrorAction SilentlyContinue
$stopped = Wait-ForVmState -Name $vmName -State 'Off' -Seconds $TimeoutSeconds
$watch.Stop()
Add-Result -Name 'host shutdown' -Result $(if ($stopped) { 'PASS' } else { 'FAIL' }) `
    -Seconds $watch.Elapsed.TotalSeconds -Detail $(
    if ($stopped) { 'the guest powered itself off on request' }
    else { "still $((Get-VM -Name $vmName).State) after $TimeoutSeconds s - left running on purpose" })

# 5. Second cold boot -----------------------------------------------------
# A shutdown that corrupted the root filesystem shows up here and nowhere
# else, and the address check catches a guest that came back on a different
# one.
if (-not $stopped) {
    Add-Result -Name 'cold boot #2' -Result 'SKIP' -Detail 'the VM never shut down; not power-cycling over the evidence'
    Add-Result -Name 'KVP after reboot' -Result 'SKIP' -Detail 'no second boot to check'
} else {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Start-VM -Name $vmName
    $rebooted = Wait-ForXrdp -TargetHost $address -Seconds $TimeoutSeconds
    $watch.Stop()
    Add-Result -Name 'cold boot #2' -Result $(if ($rebooted) { 'PASS' } else { 'FAIL' }) `
        -Seconds $watch.Elapsed.TotalSeconds -Detail $(
        if ($rebooted) { "came back on $address after the clean shutdown" }
        else { "no X.224 reply from $address within $TimeoutSeconds s" })

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $again = @()
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $again = Get-ReportedIPv4 -Name $vmName
        if ($again -contains $address) { break }
        Start-Sleep -Seconds 5
    }
    $watch.Stop()
    Add-Result -Name 'KVP after reboot' -Result $(if ($again -contains $address) { 'PASS' } else { 'FAIL' }) `
        -Seconds $watch.Elapsed.TotalSeconds -Detail $(
        if ($again -contains $address) { "still $address" }
        else { "host sees $($again -join ', ')" })
}

# --------------------------------------------------------------------------

$failed = @($script:Results | Where-Object { $_.Result -ne 'PASS' })
$verdict = if ($failed.Count -eq 0) { 'PASS' } else { 'FAIL' }
Add-Note ''
Add-Note ("run finished       : {0:o}" -f (Get-Date))
Add-Note ("final verdict      : {0}" -f $verdict)

$table = $script:Results | Format-Table -AutoSize | Out-String
Write-Host ''
Write-Host $table
Write-Host ("final verdict: {0}" -f $verdict) -ForegroundColor $(
    if ($verdict -eq 'PASS') { 'Green' } else { 'Red' })

$evidence = @('Qubix Hyper-V acceptance', '') + $script:Notes + @('', $table.TrimEnd())
$parent = Split-Path -Parent $ReportPath
if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
    $null = New-Item -ItemType Directory -Path $parent -Force
}
$evidence -join "`r`n" | Set-Content -LiteralPath $ReportPath -Encoding UTF8
Write-Host "evidence: $ReportPath"

if ($verdict -ne 'PASS') { exit 1 }
