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

      Dynamic Memory   hv_balloon reports the guest's demand, and the host can
                       grow the guest past its startup memory.  Memory above
                       startup can only arrive by hot-add, so MemoryAssigned
                       crossing it proves the hot-add path on this kernel end
                       to end.  A running VM's floor cannot be raised - Hyper-V
                       only lets it go down, and never above startup - so the
                       host is made to want more through the buffer, the one
                       memory knob it lets move up at run time.  Onlining the
                       new blocks is the kernel's own job here
                       (MEMORY_HOTPLUG_DEFAULT_ONLINE, pinned by
                       tests/kernel-contract.nix), and the host cannot watch
                       it; but hv_balloon reports hot-added pages that are
                       still offline as committed, so if they stayed offline
                       the demand column in the evidence jumps by the amount
                       added.
      Host shutdown    hv_utils answers the host's shutdown request, and the
                       guest reaches Off.  There is no userspace daemon in that
                       path: the kernel calls orderly_poweroff() itself, which
                       is exactly why dropping hv_vss_daemon and
                       hv_fcopy_uio_daemon is supposed to be safe.
      KVP              hv_kvp_daemon reports the guest's addresses back to the
                       host.  That is what Get-QubixAddress falls back to for
                       machines without a static IP, and it is the reason that
                       one daemon was kept when the other two were not.

    A failing shutdown is never rescued with -Force here.  The VM is left
    running and the run ends FAIL, because forcing it off would destroy the
    only evidence that the shutdown path is broken.

    Nothing here compares a translated string.  Integration service names and
    status descriptions are localized - on a Russian host the Shutdown service
    is not called "Shutdown" - so the checks go by WMI class, GUID, enum and
    numeric code, and numbers are written in the invariant culture.

    Everything is timed and written to -ReportPath, and that includes a run
    that stops early or trips over something unexpected: the checks that did
    finish are exactly the part worth keeping.  Six months from now, a hot-add
    that takes 55 seconds instead of 4 is the kind of degradation that creeps
    in quietly, and there is no way to notice it without the earlier number to
    compare against.

    The script raises the VM's memory buffer while it runs and restores it,
    and it stops and starts the VM.  Run it against a lab machine.

.PARAMETER Machine
    Manifest machine name.  Default: spotibox.

.PARAMETER TimeoutSeconds
    Deadline for each check that waits: RDP, KVP, the guest's first memory
    report, the shutdown service, hot-add and shutdown.

.PARAMETER ReportPath
    Where to write the evidence.  Defaults to an `acceptance-<timestamp>.txt`
    next to the VM, beside the image-version.txt qubixctl writes there, so a
    run always leaves a record and it is always somewhere findable.  Attach it
    to the release.

.EXAMPLE
    .\tools\qubix-acceptance.cmd
    .\tools\qubix-acceptance.cmd -ReportPath C:\temp\acceptance-v0.3.0.txt

.NOTES
    Needs an elevated shell: the Hyper-V cmdlets and the virtualization WMI
    namespace do.  tools\qubix-acceptance.cmd elevates, sets a process-scoped
    execution policy and passes arguments through, which is also what makes it
    work from a \\wsl.localhost\... path.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Script parameters are consumed by Invoke-QubixAcceptance; the analyzer does not follow that.')]
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

function Format-Duration {
    # '{0:N1}' -f follows the host's culture and writes 45,8 on a Russian one.
    # Evidence from different hosts has to compare as it is.
    param([double]$Seconds)
    return $Seconds.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture) + 's'
}

function Add-Result {
    param(
        [string]$Name,
        [string]$Result,
        [string]$Detail,
        [double]$Seconds = -1
    )

    $took = if ($Seconds -ge 0) { Format-Duration $Seconds } else { '' }
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
    Write-Host ("{0,-26} {1,-5} {2,7}  {3}" -f $Name, $Result, $took, $Detail) -ForegroundColor $colour
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

function Get-HarnessRevision {
    # Which version of this script produced a given evidence file.  The image
    # revision says what was tested; this says what did the testing, and the
    # two move independently.
    try {
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $PSCommandPath).Hash
        return 'sha256:' + $hash.Substring(0, 16).ToLowerInvariant()
    } catch {
        return 'unknown'
    }
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

function Get-ShutdownComponent {
    # The Shutdown integration service as the WMI device behind it.  SystemName
    # is the VM's GUID, which reads the same on every host in every language -
    # unlike Get-VMIntegrationService -Name 'Shutdown', which only matches the
    # English display name and finds nothing on a localized host.
    param([guid]$VmId)

    $filter = "SystemName='{0}'" -f $VmId.ToString().ToUpperInvariant()
    return @(Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName 'Msvm_ShutdownComponent' -Filter $filter)
}

function Get-ShutdownServiceState {
    # EnabledState 2 is Enabled; OperationalStatus[0] 2 is OK, and 3 is
    # Degraded, which Microsoft documents as operating normally on an older
    # protocol version than the host's newest - answering all the same.  The
    # same information is in StatusDescriptions as text, translated, which is
    # precisely what this must not compare.
    param([object]$Component)

    $status = if ($null -eq $Component.OperationalStatus) { -1 } else { [int]@($Component.OperationalStatus)[0] }
    $name = switch ($status) {
        2 { 'OK' }
        3 { 'Degraded (an older protocol, working)' }
        7 { 'Non-Recoverable Error' }
        12 { 'No Contact' }
        13 { 'Lost Communication' }
        -1 { 'no status' }
        default { "status $status" }
    }
    $enabled = ([int]$Component.EnabledState -eq 2)
    return [PSCustomObject]@{
        Enabled = $enabled
        Ok      = ($enabled -and ($status -eq 2 -or $status -eq 3))
        Detail  = '{0}, {1}' -f $(if ($enabled) { 'enabled' } else { 'disabled' }), $name
    }
}

function Get-ShutdownRequestResult {
    # Return codes of Msvm_ShutdownComponent.InitiateShutdown, as documented.
    param([int]$Code)

    $meaning = @{
        0     = 'delivered'
        4096  = 'accepted as a job'
        32768 = 'failed'
        32769 = 'access denied'
        32770 = 'not supported'
        32771 = 'status unknown'
        32772 = 'timed out'
        32773 = 'invalid parameter'
        32774 = 'system in use'
        32775 = 'invalid state for this operation'
        32776 = 'incorrect data type'
        32777 = 'system not available'
        32778 = 'out of memory'
        32779 = 'file not found'
        32780 = 'system not ready'
        32781 = 'the machine is locked and needs a forced shutdown'
        32782 = 'a shutdown is already in progress'
    }
    if ($meaning.ContainsKey($Code)) { return "$Code ($($meaning[$Code]))" }
    return "$Code"
}

function Get-HostFreeMemory {
    # Bytes of physical memory the host reports free.  Win32_OperatingSystem
    # rather than the Hyper-V balancer's performance counters, whose paths
    # are translated as well.
    return [long](Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory * 1KB
}

function Get-HotAddPlan {
    # Hyper-V aims to give a guest demand * (1 + buffer/100).  This picks the
    # buffer that makes it want Headroom past startup memory, which it can only
    # deliver by hot-adding.  Integer arithmetic on purpose: 2560/800 - 1 in
    # floating point is 2.2000000000000002, and a ceiling of that is off by one.
    param(
        [long]$DemandBytes,
        [long]$StartupBytes,
        [long]$MaximumBytes,
        [long]$HeadroomBytes = 512MB
    )

    if ($DemandBytes -le 0 -or $MaximumBytes -le $StartupBytes) { return $null }
    $target = [math]::Min($StartupBytes + $HeadroomBytes, $MaximumBytes)
    $buffer = [math]::Ceiling(($target - $DemandBytes) * 100 / $DemandBytes)
    return [PSCustomObject]@{
        TargetBytes = [long]$target
        Buffer      = [int][math]::Max(5, [math]::Min(2000, $buffer))
    }
}

function Add-IntegrationServiceNote {
    # For the record, not for the verdict: which services the guest answers.
    # Names come in whatever language the host speaks, so every line leads
    # with the service's GUID, which is the same everywhere.
    param([string]$VmName)

    try {
        $services = @(Get-VMIntegrationService -VMName $VmName)
        Add-Note ''
        Add-Note 'integration services, as the host reports them:'
        foreach ($service in $services) {
            $guid = ([string]$service.Id -split '\\')[-1]
            $enabled = if ($service.Enabled) { 'enabled' } else { 'disabled' }
            $status = [string]$service.PrimaryOperationalStatus
            Add-Note ('  {0}  {1,-8}  {2,-20}  {3}' -f $guid, $enabled, $status, $service.Name)
        }
    } catch {
        Add-Note "integration services could not be listed: $($_.Exception.Message)"
    }
}

function Invoke-AcceptanceCheck {
    param(
        [string]$VmName,
        [guid]$VmId,
        [string]$Address,
        [int]$TimeoutSeconds
    )

    # 1. Cold boot --------------------------------------------------------
    $state = (Get-VM -Name $VmName).State
    if ($state -ne 'Off') {
        # Preparation, not a check, so -Force is fine here.
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        Stop-VM -Name $VmName -Force -Confirm:$false
        $null = Wait-ForVmState -Name $VmName -State 'Off' -Seconds 60
        $watch.Stop()
        Add-Note ("pre-run stop       : the VM was {0}; Stop-VM -Force took {1}" -f $state, (Format-Duration $watch.Elapsed.TotalSeconds))
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Start-VM -Name $VmName
    $booted = Wait-ForXrdp -TargetHost $Address -Seconds $TimeoutSeconds
    $watch.Stop()
    Add-Result -Name 'cold boot #1' -Result $(if ($booted) { 'PASS' } else { 'FAIL' }) `
        -Seconds $watch.Elapsed.TotalSeconds -Detail $(
        if ($booted) { "xrdp answered an X.224 connection request on $Address" }
        else { "no X.224 reply from $Address within $TimeoutSeconds s" })
    if (-not $booted) {
        Add-Note ''
        Add-Note 'stopped after cold boot #1: nothing else can be trusted on a VM that did not boot'
        return
    }

    # 2. KVP --------------------------------------------------------------
    # Give the daemon a moment after boot: it reports once networking has settled.
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $reported = @()
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $reported = Get-ReportedIPv4 -Name $VmName
        if ($reported -contains $Address) { break }
        Start-Sleep -Seconds 5
    }
    $watch.Stop()
    $kvpOk = $reported -contains $Address
    Add-Result -Name 'KVP expected IPv4' -Result $(if ($kvpOk) { 'PASS' } else { 'FAIL' }) `
        -Seconds $watch.Elapsed.TotalSeconds -Detail $(
        if ($kvpOk) { "host sees $Address" }
        elseif ($reported.Count -gt 0) { "host sees $($reported -join ', ') but not $Address" }
        else { 'host sees no routable IPv4 - hv_kvp_daemon is not reporting' })

    Add-IntegrationServiceNote -VmName $VmName

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $shutdownService = [PSCustomObject]@{ Enabled = $false; Ok = $false; Detail = 'the VM has no shutdown component' }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $found = @(Get-ShutdownComponent -VmId $VmId)
        if ($found.Count -eq 0) { break }
        $shutdownService = Get-ShutdownServiceState -Component $found[0]
        if ($shutdownService.Ok -or -not $shutdownService.Enabled) { break }
        Start-Sleep -Seconds 3
    }
    $watch.Stop()
    Add-Result -Name 'shutdown service' -Result $(if ($shutdownService.Ok) { 'PASS' } else { 'FAIL' }) `
        -Seconds $watch.Elapsed.TotalSeconds -Detail $shutdownService.Detail

    # 3. Dynamic Memory ---------------------------------------------------
    $mem = Get-VMMemory -VMName $VmName
    if (-not $mem.DynamicMemoryEnabled) {
        Add-Result -Name 'memory demand' -Result 'SKIP' -Detail 'Dynamic Memory is off on this VM'
        Add-Result -Name 'memory hot-add' -Result 'SKIP' -Detail 'enable Dynamic Memory (VM off) and re-run'
    } else {
        # hv_balloon says nothing for its first 45 seconds (pressure_report_delay
        # in drivers/hv/hv_balloon.c), which on this image ends at about the
        # moment xrdp starts answering: a single sample taken then reads zero.
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $demand = [long]0
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            $demand = [long](Get-VM -Name $VmName).MemoryDemand
            if ($demand -gt 0) { break }
            Start-Sleep -Seconds 3
        }
        $watch.Stop()
        Add-Result -Name 'memory demand' -Result $(if ($demand -gt 0) { 'PASS' } else { 'FAIL' }) `
            -Seconds $watch.Elapsed.TotalSeconds -Detail $(
            if ($demand -gt 0) { 'guest reports {0} MiB' -f [math]::Round($demand / 1MB) }
            else { 'host sees no demand - hv_balloon is not talking' })

        $startup = [long]$mem.Startup
        $assigned = [long](Get-VM -Name $VmName).MemoryAssigned
        $plan = Get-HotAddPlan -DemandBytes $demand -StartupBytes $startup -MaximumBytes $mem.Maximum
        $free = Get-HostFreeMemory
        if ($null -eq $plan) {
            Add-Result -Name 'memory hot-add' -Result 'SKIP' -Detail $(
                if ($demand -le 0) { 'no demand to size the request from' }
                else { 'maximum memory equals startup: there is nothing to hot-add into' })
        } elseif ($free -lt ($plan.TargetBytes - $assigned)) {
            Add-Result -Name 'memory hot-add' -Result 'SKIP' -Detail (
                'the host has {0} MiB free and this needs {1} MiB more for the guest; free some and re-run' -f
                [math]::Round($free / 1MB), [math]::Round(($plan.TargetBytes - $assigned) / 1MB))
        } else {
            $originalBuffer = $mem.Buffer
            $raised = $false
            $series = @()
            $peak = $assigned
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                Set-VMMemory -VMName $VmName -Buffer $plan.Buffer
                $raised = $true
                $previous = [long]-1
                $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
                while ((Get-Date) -lt $deadline) {
                    $now = Get-VM -Name $VmName
                    $current = [long]$now.MemoryAssigned
                    $series += [PSCustomObject]@{
                        At          = Format-Duration $watch.Elapsed.TotalSeconds
                        AssignedMiB = [math]::Round($current / 1MB)
                        DemandMiB   = [math]::Round([long]$now.MemoryDemand / 1MB)
                        HostFreeMiB = [math]::Round((Get-HostFreeMemory) / 1MB)
                    }
                    $peak = [math]::Max($peak, $current)
                    # Done once it reaches the target, or once it is past startup
                    # and has stopped moving.
                    if ($current -ge $plan.TargetBytes -or ($current -gt $startup -and $current -eq $previous)) { break }
                    $previous = $current
                    Start-Sleep -Seconds 3
                }
                $watch.Stop()
                $grew = $peak -gt $startup
                Add-Result -Name 'memory hot-add' -Result $(if ($grew) { 'PASS' } else { 'FAIL' }) `
                    -Seconds $watch.Elapsed.TotalSeconds -Detail (
                    '{0} MiB startup, {1} MiB at peak (buffer {2}% on {3} MiB demand)' -f
                    [math]::Round($startup / 1MB), [math]::Round($peak / 1MB), $plan.Buffer, [math]::Round($demand / 1MB))
            } finally {
                if ($raised) { Set-VMMemory -VMName $VmName -Buffer $originalBuffer }
                Add-Note ''
                Add-Note ('memory hot-add, buffer {0}% -> {1}% aiming at {2} MiB, host had {3} MiB free:' -f
                    $originalBuffer, $plan.Buffer, [math]::Round($plan.TargetBytes / 1MB), [math]::Round($free / 1MB))
                foreach ($sample in $series) {
                    Add-Note ('  {0,7}  assigned {1,6} MiB  demand {2,6} MiB  host free {3,6} MiB' -f
                        $sample.At, $sample.AssignedMiB, $sample.DemandMiB, $sample.HostFreeMiB)
                }
            }
        }
    }

    # 4. Host-requested shutdown ------------------------------------------
    # Asked through Msvm_ShutdownComponent.InitiateShutdown, the shutdown
    # service's own WMI method, rather than Stop-VM: the method answers with a
    # number and returns, while Stop-VM blocks until the guest is off however
    # long that takes - a guest that accepted and then hung would hang this
    # script with it - and its refusals are translated sentences.  No -Force,
    # then or later: if hv_utils did not answer, the VM stays up so that
    # somebody can look at it.
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $accepted = $false
    $request = 'not sent: the VM has no shutdown component'
    $found = @(Get-ShutdownComponent -VmId $VmId)
    if ($found.Count -gt 0) {
        $reply = Invoke-CimMethod -InputObject $found[0] -MethodName 'InitiateShutdown' `
            -Arguments @{ Force = $false; Reason = 'qubix acceptance: host-requested shutdown' }
        $code = [int]$reply.ReturnValue
        $accepted = ($code -eq 0 -or $code -eq 4096)
        $request = Get-ShutdownRequestResult -Code $code
    }
    $stopped = $accepted -and (Wait-ForVmState -Name $VmName -State 'Off' -Seconds $TimeoutSeconds)
    $watch.Stop()
    Add-Result -Name 'host shutdown' -Result $(if ($stopped) { 'PASS' } else { 'FAIL' }) `
        -Seconds $watch.Elapsed.TotalSeconds -Detail $(
        if ($stopped) { "request $request, and the guest powered itself off" }
        elseif ($accepted) { "request $request, but still $((Get-VM -Name $VmName).State) after $TimeoutSeconds s - left running on purpose" }
        else { "request $request - left running on purpose" })

    # 5. Second cold boot -------------------------------------------------
    # A shutdown that corrupted the root filesystem shows up here and nowhere
    # else, and the address check catches a guest that came back on a different
    # one.
    if (-not $stopped) {
        Add-Result -Name 'cold boot #2' -Result 'SKIP' -Detail 'the VM never shut down; not power-cycling over the evidence'
        Add-Result -Name 'KVP after reboot' -Result 'SKIP' -Detail 'no second boot to check'
        return
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Start-VM -Name $VmName
    $rebooted = Wait-ForXrdp -TargetHost $Address -Seconds $TimeoutSeconds
    $watch.Stop()
    Add-Result -Name 'cold boot #2' -Result $(if ($rebooted) { 'PASS' } else { 'FAIL' }) `
        -Seconds $watch.Elapsed.TotalSeconds -Detail $(
        if ($rebooted) { "came back on $Address after the clean shutdown" }
        else { "no X.224 reply from $Address within $TimeoutSeconds s" })

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $again = @()
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $again = Get-ReportedIPv4 -Name $VmName
        if ($again -contains $Address) { break }
        Start-Sleep -Seconds 5
    }
    $watch.Stop()
    Add-Result -Name 'KVP after reboot' -Result $(if ($again -contains $Address) { 'PASS' } else { 'FAIL' }) `
        -Seconds $watch.Elapsed.TotalSeconds -Detail $(
        if ($again -contains $Address) { "still $Address" }
        else { "host sees $($again -join ', ')" })
}

function Invoke-QubixAcceptance {
    # Returns the verdict, and nothing else: the caller turns it into an exit
    # code, and the tests read it directly.
    param(
        [string]$Machine,
        [string]$ManifestPath,
        [string]$VmRoot,
        [int]$TimeoutSeconds,
        [string]$ReportPath
    )

    $script:Results = @()
    $script:Notes = @()

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
    Add-Note ("harness            : qubix-acceptance.ps1 {0}" -f (Get-HarnessRevision))
    Add-Note ("Hyper-V host       : {0} ({1})" -f $env:COMPUTERNAME, [System.Environment]::OSVersion.VersionString)
    Add-Note ("VM                 : {0}" -f $vmName)
    Add-Note ("VM generation      : {0}" -f $vm.Generation)
    Add-Note ("VM config version  : {0}" -f $vm.Version)
    Add-Note ("expected address   : {0}" -f $address)
    Add-Note ("deadline per check : {0} s" -f $TimeoutSeconds)

    Write-Host "Hyper-V acceptance for $vmName at $address" -ForegroundColor Cyan
    $script:Notes | ForEach-Object { Write-Host "  $_" }
    Write-Host ''

    try {
        $null = Invoke-AcceptanceCheck -VmName $vmName -VmId $vm.Id -Address $address -TimeoutSeconds $TimeoutSeconds
    } catch {
        # Whatever broke, the checks that did finish are still evidence, and
        # the evidence file is written below either way.
        $message = $_.Exception.Message -replace '\s*\r?\n\s*', ' / '
        Add-Result -Name 'harness error' -Result 'ERROR' -Detail (
            '{0} (qubix-acceptance.ps1:{1})' -f $message, $_.InvocationInfo.ScriptLineNumber)
    }

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

    return $verdict
}

# Dot-source the script to load the functions without running anything
# (used by the tests); every other invocation runs the checks.
if ($MyInvocation.InvocationName -ne '.') {
    $verdict = Invoke-QubixAcceptance -Machine $Machine -ManifestPath $ManifestPath -VmRoot $VmRoot `
        -TimeoutSeconds $TimeoutSeconds -ReportPath $ReportPath
    if ($verdict -ne 'PASS') { exit 1 }
}
