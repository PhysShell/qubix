#!/usr/bin/env pwsh
<#
Unit checks for tools/qubix-acceptance.ps1.

There is no Hyper-V here either.  The script is dot-sourced, its pure helpers
are called directly, and whole runs are driven against stand-in Hyper-V
cmdlets defined below - a function wins over a cmdlet of the same name, and on
Linux there is no Hyper-V module to shadow anyway.  That is enough to pin the
two things the first run on a real host taught: nothing may depend on the
language the host speaks, and a run that breaks halfway still leaves its
evidence behind.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/qubix-acceptance.ps1')

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

# --- A stand-in Hyper-V host ----------------------------------------------

$manifestPath = Join-Path $repo 'manifest.json'
$spotibox = (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).machines.spotibox
$fakeVmName = [string]$spotibox.vmName
$fakeAddress = [string]$spotibox.staticIp

# What a Russian host calls the Shutdown service.  Built from code points:
# Windows PowerShell 5.1 reads a script without a BOM as ANSI, and Cyrillic
# decoded that way turns into smart quotes, which end string literals.
$shutdownRu = -join [char[]]@(0x417, 0x430, 0x432, 0x435, 0x440, 0x448, 0x435, 0x43D, 0x438, 0x435,
    0x20, 0x440, 0x430, 0x431, 0x43E, 0x442, 0x44B)

$script:hv = $null

function Reset-FakeHost {
    param([hashtable]$Overrides = @{})

    $script:hv = @{
        State        = 'Off'
        VmId         = [guid]'6a1f2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d'
        Assigned     = [long]2GB
        Demand       = [long]800MB
        Buffer       = 20
        FreeKB       = [long](8GB / 1KB)
        Xrdp         = $true
        Addresses    = @($fakeAddress, 'fe80::215:5dff:fe00:1')
        ShutdownCode = 0
        ThrowIn      = ''
        Calls        = New-Object System.Collections.ArrayList
    }
    foreach ($key in $Overrides.Keys) { $script:hv[$key] = $Overrides[$key] }
}

function Write-FakeCall {
    param([string]$Line)
    $null = $script:hv.Calls.Add($Line)
}

function Get-VM {
    param([string]$Name, [string]$ErrorAction)
    if ($Name -ne $fakeVmName) { return $null }
    return [PSCustomObject]@{
        Name           = $Name
        State          = $script:hv.State
        Generation     = 2
        Version        = '12.0'
        Id             = $script:hv.VmId
        MemoryAssigned = [long]$script:hv.Assigned
        MemoryDemand   = [long]$script:hv.Demand
    }
}

function Start-VM {
    param([string]$Name)
    Write-FakeCall "Start-VM $Name"
    $script:hv.State = 'Running'
}

function Stop-VM {
    param([string]$Name, [switch]$Force, [switch]$TurnOff, [switch]$Confirm)
    Write-FakeCall "Stop-VM Force=$Force TurnOff=$TurnOff"
    $script:hv.State = 'Off'
}

function Get-VMNetworkAdapter {
    param([string]$VMName)
    return [PSCustomObject]@{ IPAddresses = $script:hv.Addresses }
}

function Get-VMIntegrationService {
    param([string]$VMName)
    if ($script:hv.ThrowIn -eq 'Get-VMIntegrationService') { throw 'integration services are not listable here' }
    $prefix = 'Microsoft:{0}\' -f $script:hv.VmId.ToString().ToUpperInvariant()
    return @(
        [PSCustomObject]@{ Name = $shutdownRu; Id = $prefix + '9F8233AC-BE49-4C79-8EE3-E7E1985B2077'; Enabled = $true; PrimaryOperationalStatus = 'Ok' }
        [PSCustomObject]@{ Name = 'VSS'; Id = $prefix + '5CED1297-4598-4915-A5FC-AD21BB4D02A4'; Enabled = $true; PrimaryOperationalStatus = 'NoContact' }
    )
}

function Get-VMMemory {
    param([string]$VMName)
    if ($script:hv.ThrowIn -eq 'Get-VMMemory') { throw "the host said no`r`nsecond line of the reason" }
    return [PSCustomObject]@{
        DynamicMemoryEnabled = $true
        Startup              = [long]2GB
        Minimum              = [long]1GB
        Maximum              = [long]6GB
        Buffer               = [int]$script:hv.Buffer
    }
}

function Set-VMMemory {
    param([string]$VMName, [int]$Buffer)
    Write-FakeCall "Set-VMMemory -Buffer $Buffer"
    $script:hv.Buffer = $Buffer
    # A buffer above the default makes the host want more than startup, and
    # the only way it has to give it is hot-add.
    if ($Buffer -gt 20) { $script:hv.Assigned = [long]2560MB }
}

function Get-CimInstance {
    param([string]$Namespace, [string]$ClassName, [string]$Filter)
    switch ($ClassName) {
        'Win32_OperatingSystem' {
            return [PSCustomObject]@{ FreePhysicalMemory = [uint64]$script:hv.FreeKB }
        }
        'Msvm_ShutdownComponent' {
            Write-FakeCall "Get-CimInstance $Namespace $ClassName $Filter"
            # SystemName is the upper-case VM GUID; anything else finds nothing,
            # exactly as it would on a real host.
            if ($Filter -cne ("SystemName='{0}'" -f $script:hv.VmId.ToString().ToUpperInvariant())) { return }
            return [PSCustomObject]@{ EnabledState = [uint16]2; OperationalStatus = [uint16[]]@(2) }
        }
    }
}

function Invoke-CimMethod {
    param([object]$InputObject, [string]$MethodName, [hashtable]$Arguments)
    Write-FakeCall ('Invoke-CimMethod {0} Force={1}' -f $MethodName, $Arguments.Force)
    if ($script:hv.ShutdownCode -eq 0) { $script:hv.State = 'Off' }
    return [PSCustomObject]@{ ReturnValue = [uint32]$script:hv.ShutdownCode }
}

function Start-Sleep {
    param([int]$Seconds)
}

# The real one opens a socket.
function Test-XrdpHandshake {
    param([string]$TargetHost)
    return [bool]$script:hv.Xrdp
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("qubix-acceptance-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

function Invoke-FakeRun {
    param([hashtable]$Overrides = @{}, [int]$Timeout = 2)

    Reset-FakeHost -Overrides $Overrides
    $report = Join-Path $tmp ('acceptance-' + [guid]::NewGuid().ToString('N') + '.txt')
    $verdict = Invoke-QubixAcceptance -Machine 'spotibox' -ManifestPath $manifestPath -VmRoot $tmp `
        -TimeoutSeconds $Timeout -ReportPath $report 6>$null
    return [PSCustomObject]@{
        Verdict  = $verdict
        Evidence = if (Test-Path -LiteralPath $report) { Get-Content -LiteralPath $report -Raw -Encoding UTF8 } else { '' }
        Results  = @($script:Results)
        Calls    = @($script:hv.Calls)
    }
}

function Get-Row {
    param([object]$Run, [string]$Check)
    return @($Run.Results | Where-Object { $_.Check -eq $Check })
}

function Test-Row {
    param([object]$Run, [string]$Check, [string]$Result)
    $rows = @(Get-Row -Run $Run -Check $Check)
    return ($rows.Count -eq 1 -and $rows[0].Result -eq $Result)
}

try {
    # --- Nothing is looked up by its translated name ---------------------
    # The first real run died on Get-VMIntegrationService -Name 'Shutdown': the
    # host was Russian, and -Name matches the display name in the host's
    # language.  Code lines only; comments may say what not to do.
    foreach ($file in @('tools/qubix-acceptance.ps1', 'tools/qubixctl.ps1')) {
        $code = @(Get-Content -LiteralPath (Join-Path $repo $file) | Where-Object { $_ -notmatch '^\s*#' })
        $byName = @($code | Where-Object { $_ -match 'VMIntegrationService\b.*\s-Name\b' })
        Assert-True ($byName.Count -eq 0) "$file looks up an integration service by its localized name: $($byName -join ' | ')"
        $described = @($code | Where-Object { $_ -match 'StatusDescription' })
        Assert-True ($described.Count -eq 0) "$file compares a translated status description: $($described -join ' | ')"
    }

    # --- Format-Duration ---------------------------------------------------
    # A culture that writes decimals with a comma, the way ru-RU does.  Cloned
    # from the invariant culture so it exists even where .NET runs without ICU.
    $comma = [System.Globalization.CultureInfo]::InvariantCulture.Clone()
    $comma.NumberFormat.NumberDecimalSeparator = ','
    $formatted = & {
        $saved = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $comma
            [PSCustomObject]@{ Ours = (Format-Duration 45.84); Culture = ('{0:N1}' -f 45.84) }
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $saved
        }
    }
    Assert-True ($formatted.Culture -eq '45,8') 'the comma culture is really in effect (otherwise the next check proves nothing)'
    Assert-True ($formatted.Ours -eq '45.8s') 'durations are written with a dot whatever the host culture'
    Assert-True ((Format-Duration 0) -eq '0.0s') 'zero is still a duration'

    # --- Get-HotAddPlan ------------------------------------------------------
    $plan = Get-HotAddPlan -DemandBytes 800MB -StartupBytes 2GB -MaximumBytes 6GB
    Assert-True ($plan.TargetBytes -eq 2560MB) 'hot-add aims half a gigabyte past startup'
    Assert-True ($plan.Buffer -eq 220) 'the buffer is exact: 800 MiB at 220% is 2560 MiB, not a percent more'
    Assert-True ((Get-HotAddPlan -DemandBytes 700MB -StartupBytes 2GB -MaximumBytes 6GB).Buffer -eq 266) 'a fractional buffer rounds up, so the target is reached rather than missed'
    Assert-True ((Get-HotAddPlan -DemandBytes 800MB -StartupBytes 2GB -MaximumBytes 2304MB).TargetBytes -eq 2304MB) 'the target never exceeds the maximum'
    Assert-True ((Get-HotAddPlan -DemandBytes 50MB -StartupBytes 2GB -MaximumBytes 6GB).Buffer -eq 2000) 'the buffer is capped at what Hyper-V accepts'
    Assert-True ((Get-HotAddPlan -DemandBytes 3GB -StartupBytes 2GB -MaximumBytes 6GB).Buffer -eq 5) 'a guest already past the target gets the smallest buffer Hyper-V accepts'
    Assert-True ($null -eq (Get-HotAddPlan -DemandBytes 800MB -StartupBytes 2GB -MaximumBytes 2GB)) 'no plan when there is no room above startup'
    Assert-True ($null -eq (Get-HotAddPlan -DemandBytes 0 -StartupBytes 2GB -MaximumBytes 6GB)) 'no plan without a demand to size it from'

    # --- Get-HarnessRevision ------------------------------------------------
    # sha256('abc') is ba7816bf8f01cfea414140de5dae2223b00361a3...
    Assert-True ((Get-HarnessRevision -Command ([PSCustomObject]@{ ScriptContents = 'abc' })) -eq 'sha256:ba7816bf8f01cfea') 'the harness digest is the first 16 hex digits of sha256'
    Assert-True ((Get-HarnessRevision -Command ([PSCustomObject]@{ ScriptContents = '' })) -eq 'unknown (PowerShell exposed no script text)') 'no text is said out loud'
    $why = Get-HarnessRevision -Command ([PSCustomObject]@{ Name = 'no ScriptContents here' })
    Assert-True ($why -like 'unknown (?*)') "a failure carries its reason (got '$why')"

    # --- The shutdown service, by numbers ------------------------------------
    $state = Get-ShutdownServiceState -Component ([PSCustomObject]@{ EnabledState = [uint16]2; OperationalStatus = [uint16[]]@(2, 32896) })
    Assert-True ($state.Ok -and $state.Enabled) 'enabled and OK is OK'
    Assert-True ($state.Detail -eq 'enabled, OK') 'status names are ours, not the host translation'
    $state = Get-ShutdownServiceState -Component ([PSCustomObject]@{ EnabledState = [uint16]2; OperationalStatus = [uint16[]]@(3) })
    Assert-True ($state.Ok -and $state.Detail -eq 'enabled, Degraded (an older protocol, working)') 'Degraded is an older protocol that still answers, and says so'
    $state = Get-ShutdownServiceState -Component ([PSCustomObject]@{ EnabledState = [uint16]2; OperationalStatus = [uint16[]]@(12) })
    Assert-True (-not $state.Ok -and $state.Detail -eq 'enabled, No Contact') 'No Contact is not OK'
    $state = Get-ShutdownServiceState -Component ([PSCustomObject]@{ EnabledState = [uint16]3; OperationalStatus = $null })
    Assert-True (-not $state.Ok -and -not $state.Enabled -and $state.Detail -eq 'disabled, no status') 'a disabled service with no status'
    Assert-True ((Get-ShutdownRequestResult -Code 0) -eq '0 (delivered)') 'request code 0 reads as delivered'
    Assert-True ((Get-ShutdownRequestResult -Code 32777) -eq '32777 (system not available)') 'refusals are named'
    Assert-True ((Get-ShutdownRequestResult -Code 1234) -eq '1234') 'unknown codes print as numbers'

    # --- A clean run, on a host that speaks Russian and writes decimal commas -
    $run = & {
        $saved = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $comma
            Invoke-FakeRun
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $saved
        }
    }
    Assert-True ($run.Verdict -eq 'PASS') "a healthy guest passes (got $($run.Verdict))"
    $checks = @('cold boot #1', 'KVP expected IPv4', 'shutdown service', 'memory demand', 'memory hot-add',
        'host shutdown', 'cold boot #2', 'KVP after reboot')
    foreach ($check in $checks) {
        Assert-True (Test-Row $run $check 'PASS') "'$check' passes in a clean run"
    }
    Assert-True ($run.Results.Count -eq $checks.Count) "a clean run records exactly the eight checks (got $($run.Results.Count))"
    Assert-True ($run.Evidence -match 'final verdict\s+: PASS') 'the evidence carries the verdict'
    $fileDigest = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $repo 'tools/qubix-acceptance.ps1')).Hash.Substring(0, 16).ToLowerInvariant()
    Assert-True ($run.Evidence.Contains("harness            : qubix-acceptance.ps1 sha256:$fileDigest")) 'the evidence names the harness by the same digits sha256sum gives for the file'
    Assert-True ($run.Evidence -match '\d\.\ds' -and $run.Evidence -notmatch '\d,\ds') 'durations in the evidence use a dot under a comma culture'
    Assert-True ($run.Evidence.Contains('9F8233AC-BE49-4C79-8EE3-E7E1985B2077')) 'integration services are listed by GUID'
    Assert-True ($run.Evidence.Contains($shutdownRu)) 'and with the name the host gave them, whatever the language'
    $expectedFilter = "SystemName='6A1F2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D'"
    Assert-True (@($run.Calls | Where-Object { $_ -like "Get-CimInstance root\virtualization\v2 Msvm_ShutdownComponent $expectedFilter" }).Count -ge 1) 'the shutdown component is found by the upper-case VM GUID'
    Assert-True ($run.Calls -contains 'Invoke-CimMethod InitiateShutdown Force=False') 'the shutdown request is polite: Force is false'
    Assert-True (@($run.Calls | Where-Object { $_ -like 'Stop-VM*' }).Count -eq 0) 'a VM that starts off is never Stop-VMed'
    $buffers = @($run.Calls | Where-Object { $_ -like 'Set-VMMemory*' })
    Assert-True ($buffers.Count -eq 2 -and $buffers[0] -eq 'Set-VMMemory -Buffer 220' -and $buffers[1] -eq 'Set-VMMemory -Buffer 20') "the buffer is raised for hot-add and put back ($($buffers -join ', '))"
    Assert-True ((Get-Row $run 'memory hot-add')[0].Detail -eq '2048 MiB startup, 2560 MiB at peak (buffer 220% on 800 MiB demand)') 'the hot-add result says how far it got'

    # --- It breaks halfway: the evidence survives ---------------------------
    $run = Invoke-FakeRun -Overrides @{ ThrowIn = 'Get-VMMemory' }
    Assert-True ($run.Verdict -eq 'FAIL') 'a harness error fails the run'
    Assert-True (Test-Row $run 'cold boot #1' 'PASS') 'checks finished before the error are kept'
    Assert-True (Test-Row $run 'KVP expected IPv4' 'PASS') 'all of them'
    Assert-True (Test-Row $run 'harness error' 'ERROR') 'the error itself is a row'
    Assert-True ((Get-Row $run 'harness error')[0].Detail -like 'the host said no / second line of the reason (qubix-acceptance.ps1:*)') 'the error keeps its message, on one line, with where it happened'
    Assert-True ($run.Evidence -match 'cold boot #1' -and $run.Evidence -match 'harness error') 'and the evidence file was written anyway'

    # --- It never boots ------------------------------------------------------
    $run = Invoke-FakeRun -Overrides @{ Xrdp = $false } -Timeout 1
    Assert-True ($run.Verdict -eq 'FAIL') 'no RDP, no pass'
    Assert-True ($run.Results.Count -eq 1 -and (Test-Row $run 'cold boot #1' 'FAIL')) 'nothing is checked on a VM that did not boot'
    Assert-True ($run.Evidence -match 'stopped after cold boot #1') 'the evidence says why it stopped'

    # --- The guest refuses the shutdown -----------------------------------
    $run = Invoke-FakeRun -Overrides @{ ShutdownCode = 32777 }
    Assert-True (Test-Row $run 'host shutdown' 'FAIL') 'a refused shutdown fails'
    Assert-True ((Get-Row $run 'host shutdown')[0].Detail -eq 'request 32777 (system not available) - left running on purpose') 'with the refusal named'
    Assert-True ($script:hv.State -eq 'Running') 'the VM is left running'
    Assert-True (@($run.Calls | Where-Object { $_ -like 'Stop-VM*' }).Count -eq 0) 'and nothing forces it off afterwards'
    Assert-True (Test-Row $run 'cold boot #2' 'SKIP') 'no second boot over the evidence'

    # --- The host has no memory to give ------------------------------------
    $run = Invoke-FakeRun -Overrides @{ FreeKB = [long](100MB / 1KB) }
    Assert-True (Test-Row $run 'memory hot-add' 'SKIP') 'a full host skips hot-add rather than blaming the guest'
    Assert-True ((Get-Row $run 'memory hot-add')[0].Detail -like 'the host has 100 MiB free*free some and re-run') 'and says what to do about it'
    Assert-True (@($run.Calls | Where-Object { $_ -like 'Set-VMMemory*' }).Count -eq 0) 'the buffer is not touched'

    # --- The VM was left running by qubixctl ----------------------------------
    $run = Invoke-FakeRun -Overrides @{ State = 'Running' }
    Assert-True ($run.Verdict -eq 'PASS') 'a VM found running is stopped first and still passes'
    Assert-True (@($run.Calls | Where-Object { $_ -eq 'Stop-VM Force=True TurnOff=False' }).Count -eq 1) 'the pre-run stop is the one Stop-VM, and it is not a power cut'
    Assert-True ($run.Evidence -match 'pre-run stop\s+: the VM was Running') 'and the evidence records it'

    # --- Listing integration services is for the record only -----------------
    $run = Invoke-FakeRun -Overrides @{ ThrowIn = 'Get-VMIntegrationService' }
    Assert-True ($run.Verdict -eq 'PASS') 'a listing that fails does not fail the run'
    Assert-True ($run.Evidence -match 'integration services could not be listed') 'but it is noted'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "qubix-acceptance unit checks: $script:passes passed, $script:failures failed"
if ($script:failures -gt 0) { exit 1 }
