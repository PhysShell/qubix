<#
.SYNOPSIS
    Checks the three promises only a real Hyper-V host can prove.

.DESCRIPTION
    tools/cold-boot.sh boots the shipped VHDX under OVMF and gets as far as an
    RDP reply, which proves the boot loader, the kernel, the filesystems, the
    network and xrdp.  It cannot prove anything Hyper-V specific, because
    there is no VMBus in QEMU - and profiles/kernel/hyperv.nix now builds a
    kernel whose entire hardware story is VMBus, while profiles/modes/prod.nix
    replaces Microsoft's Integration Services with a hand-picked subset.

    Those two changes rest on three claims that no test in this repository can
    reach:

      Dynamic Memory   hv_balloon is loaded, the host sees the guest's demand,
                       and hot-added memory blocks are brought online by the
                       udev rules copied into profiles/modes/prod.nix.
      Host shutdown    hv_utils answers the host's shutdown request, so
                       `Stop-VM` without -Force reaches Off.  There is no
                       userspace daemon in that path: the kernel calls
                       orderly_poweroff() itself.
      KVP              hv_kvp_daemon reports the guest's addresses back to the
                       host, which is what Get-QubixAddress falls back to for
                       machines without a static IP and what
                       `qubixctl -Command status` prints.

    This script exercises all three against a VM that qubixctl has already
    created, and finishes with a second cold boot so that the shutdown it
    asked for is proven to have been clean.

    It changes the VM's memory settings while it runs and restores them
    afterwards, and it stops and starts the VM.  Run it against a lab machine.

.PARAMETER Machine
    Manifest machine name.  Default: spotibox.

.PARAMETER TimeoutSeconds
    How long to wait for each of RDP, shutdown and memory to respond.

.PARAMETER ReportPath
    Where to write the result table.  Attach it to the release.

.EXAMPLE
    .\tools\qubix-acceptance.ps1
    .\tools\qubix-acceptance.ps1 -Machine spotibox -ReportPath acceptance.txt
#>

[CmdletBinding()]
param(
    [string]$Machine = 'spotibox',
    [string]$ManifestPath = '',
    [int]$TimeoutSeconds = 300,
    [string]$ReportPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Results = @()

function Add-Result {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail
    )

    $script:Results += [PSCustomObject]@{
        Check  = $Name
        Result = if ($Passed) { 'PASS' } else { 'FAIL' }
        Detail = $Detail
    }
    $colour = if ($Passed) { 'Green' } else { 'Red' }
    Write-Host ("{0,-22} {1}  {2}" -f $Name, $(if ($Passed) { 'PASS' } else { 'FAIL' }), $Detail) -ForegroundColor $colour
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

function Test-RdpPort {
    param([string]$TargetHost, [int]$Port = 3389, [int]$TimeoutMs = 2000)

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

function Wait-ForRdp {
    param([string]$TargetHost, [int]$Seconds)

    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-RdpPort -TargetHost $TargetHost) { return $true }
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

# --------------------------------------------------------------------------

if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    throw 'The Hyper-V PowerShell module is not available. Run this on the Hyper-V host, elevated.'
}

$config = Get-ManifestMachine -Path $ManifestPath -Name $Machine
$vmName = [string]$config.vmName
$address = if ($config.PSObject.Properties.Name -contains 'staticIp') {
    [string]$config.staticIp
} else {
    "$($config.hostName).local"
}

$vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if ($null -eq $vm) {
    throw "VM '$vmName' does not exist. Create it first: tools\qubixctl.cmd"
}

Write-Host "Hyper-V acceptance for $vmName at $address" -ForegroundColor Cyan
Write-Host ''

# 1. Cold boot ------------------------------------------------------------
if ((Get-VM -Name $vmName).State -ne 'Off') {
    Stop-VM -Name $vmName -Force -Confirm:$false
    $null = Wait-ForVmState -Name $vmName -State 'Off' -Seconds 60
}
Start-VM -Name $vmName
$booted = Wait-ForRdp -TargetHost $address -Seconds $TimeoutSeconds
Add-Result -Name 'cold boot' -Passed $booted -Detail $(
    if ($booted) { "xrdp answered on $address" }
    else { "no RDP on $address within $TimeoutSeconds s" })
if (-not $booted) {
    Write-Host 'Stopping here: nothing below can be trusted on a VM that did not boot.' -ForegroundColor Yellow
    $script:Results | Format-Table -AutoSize | Out-String | Write-Host
    exit 1
}

# 2. KVP ------------------------------------------------------------------
# The addresses the host can see come from hv_kvp_daemon inside the guest.
# Give it a moment after boot: it reports once networking has settled.
Start-Sleep -Seconds 20
$reported = @(Get-VMNetworkAdapter -VMName $vmName |
    ForEach-Object { $_.IPAddresses } |
    Where-Object { $_ -and $_ -notlike '169.254.*' -and $_ -notlike 'fe80:*' })
Add-Result -Name 'KVP addresses' -Passed ($reported.Count -gt 0) -Detail $(
    if ($reported.Count -gt 0) { $reported -join ', ' }
    else { 'the host sees no guest addresses - hv_kvp_daemon is not reporting' })

$shutdownIc = Get-VMIntegrationService -VMName $vmName -Name 'Shutdown'
Add-Result -Name 'shutdown service' -Passed ($shutdownIc.PrimaryStatusDescription -eq 'OK') -Detail (
    "status: $($shutdownIc.PrimaryStatusDescription)")

# 3. Dynamic Memory -------------------------------------------------------
# Raising the minimum above what the guest currently has forces the host to
# hand it more memory.  The guest only ends up using it if hv_balloon is
# loaded and the hot-add udev rules bring the new blocks online, so
# MemoryAssigned following the new floor is a test of both.
$mem = Get-VMMemory -VMName $vmName
if (-not $mem.DynamicMemoryEnabled) {
    Add-Result -Name 'dynamic memory' -Passed $false -Detail (
        'not enabled on this VM - enable it (VM off) and re-run to test it')
} else {
    $originalMinimum = $mem.Minimum
    $assignedBefore = (Get-VM -Name $vmName).MemoryAssigned
    $demand = (Get-VM -Name $vmName).MemoryDemand
    Add-Result -Name 'memory demand' -Passed ($demand -gt 0) -Detail $(
        if ($demand -gt 0) { "guest reports $([math]::Round($demand / 1MB)) MiB in use" }
        else { 'the host sees no demand - hv_balloon is not talking' })

    $target = $assignedBefore + 512MB
    if ($target -gt $mem.Maximum) { $target = $mem.Maximum }
    try {
        Set-VMMemory -VMName $vmName -MinimumBytes $target
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $grew = $false
        while ((Get-Date) -lt $deadline) {
            if ((Get-VM -Name $vmName).MemoryAssigned -ge $target) { $grew = $true; break }
            Start-Sleep -Seconds 3
        }
        $assignedAfter = (Get-VM -Name $vmName).MemoryAssigned
        Add-Result -Name 'memory hot-add' -Passed $grew -Detail (
            "{0} MiB -> {1} MiB (floor {2} MiB)" -f `
                [math]::Round($assignedBefore / 1MB),
                [math]::Round($assignedAfter / 1MB),
                [math]::Round($target / 1MB))
    } finally {
        Set-VMMemory -VMName $vmName -MinimumBytes $originalMinimum
    }
}

# 4. Host-requested shutdown ----------------------------------------------
# No -Force: this goes through the shutdown integration service, which
# hv_utils answers in the kernel by calling orderly_poweroff().
Stop-VM -Name $vmName -Confirm:$false
$stopped = Wait-ForVmState -Name $vmName -State 'Off' -Seconds $TimeoutSeconds
Add-Result -Name 'host shutdown' -Passed $stopped -Detail $(
    if ($stopped) { 'the guest powered itself off on request' }
    else { "still running after $TimeoutSeconds s - hv_utils did not answer" })
if (-not $stopped) {
    Stop-VM -Name $vmName -Force -Confirm:$false
    $null = Wait-ForVmState -Name $vmName -State 'Off' -Seconds 60
}

# 5. Second cold boot -----------------------------------------------------
# A shutdown that corrupted the root filesystem shows up here and nowhere else.
Start-VM -Name $vmName
$rebooted = Wait-ForRdp -TargetHost $address -Seconds $TimeoutSeconds
Add-Result -Name 'second cold boot' -Passed $rebooted -Detail $(
    if ($rebooted) { 'came back after the clean shutdown' }
    else { "no RDP on $address within $TimeoutSeconds s" })

# --------------------------------------------------------------------------

Write-Host ''
$table = $script:Results | Format-Table -AutoSize | Out-String
Write-Host $table
if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $header = "Qubix Hyper-V acceptance - $vmName - $(Get-Date -Format o)"
    ($header + "`n" + $table) | Set-Content -LiteralPath $ReportPath -Encoding UTF8
    Write-Host "wrote $ReportPath"
}

$failed = @($script:Results | Where-Object { $_.Result -eq 'FAIL' })
if ($failed.Count -gt 0) {
    Write-Host "$($failed.Count) check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All Hyper-V acceptance checks passed.' -ForegroundColor Green
