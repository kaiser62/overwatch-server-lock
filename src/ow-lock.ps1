<#
.SYNOPSIS
  Force Overwatch 2 onto one server region (default: Singapore) by firewall-blocking every other datacenter.

.DESCRIPTION
  Pulls the community-maintained datacenter IP lists from foryVERX/Overwatch-Server-Selector,
  subtracts the ranges of the region you keep plus the Battle.net login/patch endpoints, and adds
  Windows Firewall block rules scoped to Overwatch.exe only (other apps using Google Cloud are untouched).

  Battle.net login hosts rotate IPs. -On registers a SYSTEM scheduled task that re-resolves them every
  few minutes (-Refresh) and rebuilds the rules from the cached lists when a new IP block appears.

.EXAMPLE
  .\ow-lock.ps1 -On          # block everything except Singapore, enable login IP auto-refresh
  .\ow-lock.ps1 -Off         # remove all rules and the refresh task
  .\ow-lock.ps1 -Status      # show current state
  .\ow-lock.ps1 -On -DryRun  # preview, no changes
  .\ow-lock.ps1 -On -Keep Japan -GamePath 'D:\Games\Overwatch\Overwatch.exe'
  .\ow-lock.ps1 -On -AllowHost 'some.login.host' -NoAutoRefresh
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'On', Mandatory)][switch]$On,
    [Parameter(ParameterSetName = 'Off', Mandatory)][switch]$Off,
    [Parameter(ParameterSetName = 'Status')][switch]$Status,
    # Re-resolve login hosts and rebuild rules if their IPs moved (run by the scheduled task).
    [Parameter(ParameterSetName = 'Refresh', Mandatory)][switch]$Refresh,
    # Regex matched against IP list file names; matching lists are kept reachable.
    [Parameter(ParameterSetName = 'On')][string]$Keep = 'Singapore',
    [Parameter(ParameterSetName = 'On')][string]$GamePath,
    # Extra hostnames (e.g. a regional Battle.net login server) to keep reachable. Comma-separated is fine.
    [Parameter(ParameterSetName = 'On')][string[]]$AllowHost = @(),
    # Do not register the login IP auto-refresh task.
    [Parameter(ParameterSetName = 'On')][switch]$NoAutoRefresh,
    # Show what would be blocked without touching the firewall.
    [Parameter(ParameterSetName = 'On')][switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$RuleGroup   = 'OW-ForceServer'
$TaskName    = 'OverwatchServerLock-Refresh'
$RepoApi     = 'https://api.github.com/repos/foryVERX/Overwatch-Server-Selector/contents/ip_lists'
$StateDir    = Join-Path $env:ProgramData 'OverwatchServerLock'
$StateFile   = Join-Path $StateDir 'state.json'
$CacheFile   = Join-Path $StateDir 'ow-ip-cache.json'
$RefreshLog  = Join-Path $StateDir 'refresh.log'
$ChunkSize   = 500   # remote addresses per firewall rule
$RefreshMins = 2     # how often the task re-resolves login hosts
$NetTtlDays  = 7     # keep previously seen login /24s open this long (hosts rotate through pools)

# Battle.net login/patch endpoints live inside the Google Cloud ranges we block
# (e.g. kr.actual.battle.net sits in the Korea list). Their /24s are always kept reachable.
$ServiceHosts = @(
    'us.actual.battle.net', 'eu.actual.battle.net', 'kr.actual.battle.net',
    'us.version.battle.net', 'eu.version.battle.net', 'kr.version.battle.net',
    'us.patch.battle.net', 'eu.patch.battle.net', 'kr.patch.battle.net', 'prod.depot.battle.net'
)
$AllowHost = @($AllowHost | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# --- elevation ---------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and $Refresh) { throw '-Refresh must run elevated (it is normally run by the scheduled task).' }
if (-not $isAdmin -and -not $DryRun -and $PSCmdlet.ParameterSetName -ne 'Status') {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
    foreach ($p in $PSBoundParameters.GetEnumerator()) {
        if ($p.Value -is [switch]) { $argList += "-$($p.Key)" }
        else { $argList += "-$($p.Key)"; $argList += "`"$(@($p.Value) -join ',')`"" }
    }
    $shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    Start-Process $shell -Verb RunAs -ArgumentList $argList
    return
}

# --- IP helpers --------------------------------------------------------------
function ConvertTo-IpInt([string]$ip) {
    $b = $ip.Split('.')
    [int64]$b[0] * 16777216 + [int64]$b[1] * 65536 + [int64]$b[2] * 256 + [int64]$b[3]
}

function ConvertTo-IpString([int64]$n) {
    '{0}.{1}.{2}.{3}' -f (($n -shr 24) -band 255), (($n -shr 16) -band 255), (($n -shr 8) -band 255), ($n -band 255)
}

# Parses "a.b.c.d-e.f.g.h" and "a.b.c.d/nn" lines into @(start, end) int pairs.
function ConvertFrom-IpList([string]$text) {
    $ip = '\d{1,3}(?:\.\d{1,3}){3}'
    foreach ($line in $text -split '[\r\n]+') {
        $l = $line.Trim()
        if ($l -match "^($ip)\s*-\s*($ip)$") {
            , @((ConvertTo-IpInt $Matches[1]), (ConvertTo-IpInt $Matches[2]))
        }
        elseif ($l -match "^($ip)/(\d{1,2})$") {
            $size  = [int64][math]::Pow(2, 32 - [int]$Matches[2])
            $start = ConvertTo-IpInt $Matches[1]
            $start -= $start % $size
            , @($start, ($start + $size - 1))
        }
        elseif ($l -match "^($ip)$") {
            $n = ConvertTo-IpInt $Matches[1]
            , @($n, $n)
        }
    }
}

function Merge-IpRanges($ranges) {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in ($ranges | Sort-Object { $_[0] })) {
        $last = if ($out.Count) { $out[$out.Count - 1] } else { $null }
        if ($last -and $r[0] -le $last[1] + 1) {
            if ($r[1] -gt $last[1]) { $last[1] = $r[1] }
        }
        else { $out.Add(@($r[0], $r[1])) }
    }
    , $out
}

# Both inputs must be merged (sorted, non-overlapping).
function Remove-IpRanges($block, $keep) {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($b in $block) {
        $s = $b[0]; $e = $b[1]
        foreach ($k in $keep) {
            if ($k[1] -lt $s) { continue }
            if ($k[0] -gt $e) { break }
            if ($k[0] -gt $s) { $out.Add(@($s, ($k[0] - 1))) }
            $s = $k[1] + 1
            if ($s -gt $e) { break }
        }
        if ($s -le $e) { $out.Add(@($s, $e)) }
    }
    , $out
}

# --- data --------------------------------------------------------------------
# State dir holds a copy of this script that SYSTEM runs, so only admins/SYSTEM may write to it.
function Initialize-StateDir {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
    $null = icacls $StateDir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX'
}

function Read-CachedLists {
    if (-not (Test-Path $CacheFile)) { return $null }
    $obj = Get-Content $CacheFile -Raw | ConvertFrom-Json
    $lists = [ordered]@{}
    foreach ($p in $obj.PSObject.Properties) { $lists[$p.Name] = $p.Value }
    $lists
}

function Get-IpLists {
    try {
        # Windows PowerShell emits the JSON array as one object; unroll before filtering.
        $index = Invoke-RestMethod $RepoApi -Headers @{ 'User-Agent' = 'ow-force-server' }
        $files = @($index) | ForEach-Object { $_ } |
            Where-Object { $_.type -eq 'file' -and $_.name -match '^(Ip_ranges_|cfg - ).*\.txt$' }
        $lists = [ordered]@{}
        foreach ($f in $files) {
            $lists[$f.name] = (Invoke-WebRequest $f.download_url -UseBasicParsing).Content
        }
        if (-not $DryRun) {
            Initialize-StateDir
            $lists | ConvertTo-Json | Set-Content $CacheFile -Encoding UTF8
        }
        Write-Host "Fetched $($lists.Count) IP lists from GitHub." -ForegroundColor DarkGray
        return $lists
    }
    catch {
        $lists = Read-CachedLists
        if (-not $lists) { throw "Could not fetch IP lists and no cache found: $_" }
        Write-Warning "GitHub fetch failed ($($_.Exception.Message)); using cached lists from $CacheFile"
        return $lists
    }
}

function Read-State {
    if (-not (Test-Path $StateFile)) { return $null }
    Get-Content $StateFile -Raw | ConvertFrom-Json
}

function Save-State($keep, $exe, $allowHost, [hashtable]$nets) {
    [ordered]@{ Keep = $keep; Exe = $exe; AllowHost = @($allowHost); Nets = $nets } |
        ConvertTo-Json -Depth 4 | Set-Content $StateFile -Encoding UTF8
}

# Resolves login/patch hosts to their /24 network bases (e.g. "34.64.53.0").
function Resolve-ServiceNets([string[]]$extraHosts) {
    @(foreach ($h in @($ServiceHosts) + @($extraHosts)) {
        if (-not $h) { continue }
        try {
            [Net.Dns]::GetHostAddresses($h) | Where-Object AddressFamily -eq 'InterNetwork' |
                ForEach-Object { $_.IPAddressToString -replace '\.\d+$', '.0' }
        }
        catch { Write-Warning "Could not resolve $h" }
    }) | Sort-Object -Unique
}

function Find-Overwatch {
    if ($GamePath) {
        if (-not (Test-Path $GamePath)) { throw "GamePath not found: $GamePath" }
        return (Resolve-Path $GamePath).Path
    }
    $roots = @()
    $running = Get-Process Overwatch -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($running -and $running.Path) { return $running.Path }
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        Get-ItemProperty $key -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'Overwatch*' -and $_.InstallLocation } |
            ForEach-Object { $roots += $_.InstallLocation }
    }
    $roots += 'C:\Program Files (x86)\Overwatch', 'C:\Program Files (x86)\Steam\steamapps\common\Overwatch'
    foreach ($r in $roots) {
        foreach ($rel in 'Overwatch.exe', '_retail_\Overwatch.exe') {
            $p = Join-Path $r $rel
            if (Test-Path $p) { return $p }
        }
    }
    throw 'Overwatch.exe not found. Pass -GamePath "<path to Overwatch.exe>".'
}

# --- actions -----------------------------------------------------------------
function Remove-Rules {
    $existing = @(Get-NetFirewallRule -Group $RuleGroup -ErrorAction SilentlyContinue)
    if ($existing.Count) { $existing | Remove-NetFirewallRule }
    $existing.Count
}

# Computes the ranges to block: every list not matching $keep, minus kept lists and login /24s.
function Get-BlockPlan($lists, [string]$keep, [string[]]$nets) {
    $keepNames  = @($lists.Keys | Where-Object { $_ -match $keep })
    $blockNames = @($lists.Keys | Where-Object { $_ -notmatch $keep })
    if (-not $keepNames.Count) {
        throw "No IP list matches -Keep '$keep'. Available: $($lists.Keys -join ', ')"
    }
    $netText    = ($nets | ForEach-Object { "$_/24" }) -join "`n"
    $keepRanges = Merge-IpRanges @(
        @($keepNames | ForEach-Object { ConvertFrom-IpList $lists[$_] }) +
        @(ConvertFrom-IpList $netText))
    $blockRanges = Merge-IpRanges @($blockNames | ForEach-Object { ConvertFrom-IpList $lists[$_] })
    $final       = Remove-IpRanges $blockRanges $keepRanges
    $addresses = @($final | ForEach-Object {
        if ($_[0] -eq $_[1]) { ConvertTo-IpString $_[0] }
        else { '{0}-{1}' -f (ConvertTo-IpString $_[0]), (ConvertTo-IpString $_[1]) }
    })
    if (-not $addresses.Count) { throw 'Nothing to block after subtracting kept ranges.' }
    [pscustomobject]@{ Addresses = $addresses; KeepNames = $keepNames; BlockNames = $blockNames }
}

function Set-Rules($plan, [string]$keep, [string]$exe) {
    [void](Remove-Rules)
    $desc = "Force Overwatch to '$keep' (kept: $($plan.KeepNames -join '; '))"
    $addresses = $plan.Addresses
    $i = 0
    for ($o = 0; $o -lt $addresses.Count; $o += $ChunkSize) {
        $i++
        $chunk = $addresses[$o..([math]::Min($o + $ChunkSize, $addresses.Count) - 1)]
        foreach ($dir in 'Outbound', 'Inbound') {
            $null = New-NetFirewallRule -DisplayName "OW Force $keep - $dir $i" -Group $RuleGroup `
                -Description $desc -Direction $dir -Action Block -Program $exe `
                -RemoteAddress $chunk -Profile Any
        }
    }
}

function Register-RefreshTask {
    $target = Join-Path $StateDir 'ow-lock.ps1'
    if ($PSCommandPath -ne $target) { Copy-Item $PSCommandPath $target -Force }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
        "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`" -Refresh")
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes $RefreshMins)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $null = Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description 'Keeps Battle.net login IPs reachable while Overwatch Server Lock is on.' -Force
}

function Unregister-RefreshTask {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
}

function Write-RefreshLog([string]$msg) {
    if ((Test-Path $RefreshLog) -and (Get-Item $RefreshLog).Length -gt 256KB) {
        $tail = Get-Content $RefreshLog -Tail 200
        Set-Content $RefreshLog $tail
    }
    Add-Content $RefreshLog "$(Get-Date -Format s)  $msg"
}

function Show-Status {
    $rules = @(Get-NetFirewallRule -Group $RuleGroup -ErrorAction SilentlyContinue)
    if (-not $rules.Count) {
        Write-Host 'OFF - no Overwatch server rules present. Matchmaking picks any region.' -ForegroundColor Yellow
        return
    }
    $app = ($rules[0] | Get-NetFirewallApplicationFilter).Program
    $out = @($rules | Where-Object Direction -eq 'Outbound')
    $count = ($out | Get-NetFirewallAddressFilter | ForEach-Object { @($_.RemoteAddress).Count } | Measure-Object -Sum).Sum
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Write-Host "ON - $($rules[0].Description)" -ForegroundColor Green
    Write-Host "  Program : $app"
    Write-Host "  Rules   : $($rules.Count) ($($out.Count) outbound + inbound mirror)"
    Write-Host "  Blocked : $count IP ranges"
    if ($task) { Write-Host "  Login IP refresh: every $RefreshMins min" }
    else { Write-Host '  Login IP refresh: off' }
    Write-Host '  Verify in match: Ctrl+Shift+N shows server IP.'
}

switch ($PSCmdlet.ParameterSetName) {
    'Off' {
        $n = Remove-Rules
        Unregister-RefreshTask
        if (Test-Path $StateFile) { Remove-Item $StateFile }
        Write-Host "Removed $n rules and the refresh task. Overwatch can use any server again." -ForegroundColor Green
    }
    'On' {
        $exe   = Find-Overwatch
        $lists = Get-IpLists
        $nets  = @(Resolve-ServiceNets $AllowHost)
        $plan  = Get-BlockPlan $lists $Keep $nets

        if ($DryRun) {
            Write-Host "Dry run: would block $($plan.Addresses.Count) ranges for $exe" -ForegroundColor Cyan
            Write-Host "Kept: $($plan.KeepNames -join ', ')"
            Write-Host "Battle.net login/patch /24s kept: $($nets -join ', ')"
            Write-Host "Blocked lists: $($plan.BlockNames -join ', ')"
            Write-Host "Sample: $($plan.Addresses[0..4] -join ', ')"
            Write-Verbose ($plan.Addresses -join "`n")
            return
        }

        Set-Rules $plan $Keep $exe
        Initialize-StateDir
        $now = (Get-Date).ToString('o')
        $netMap = @{}
        foreach ($n in $nets) { $netMap[$n] = $now }
        Save-State $Keep $exe $AllowHost $netMap
        if ($NoAutoRefresh) { Unregister-RefreshTask } else { Register-RefreshTask }

        Write-Host "Blocked $($plan.Addresses.Count) ranges from $($plan.BlockNames.Count) lists for:" -ForegroundColor Green
        Write-Host "  $exe"
        Write-Host "Kept reachable: $($plan.KeepNames -join ', ')"
        Write-Host "Battle.net login/patch /24s kept: $($nets.Count)"
        if (-not $NoAutoRefresh) { Write-Host "Login IPs re-checked every $RefreshMins min." }
        Write-Host 'Restart Overwatch if it is running. Unlock before grouping with friends on other servers.'
    }
    'Refresh' {
        $state = Read-State
        if (-not $state -or -not @(Get-NetFirewallRule -Group $RuleGroup -ErrorAction SilentlyContinue).Count) {
            # Lock was removed some other way; clean up after ourselves.
            Unregister-RefreshTask
            return
        }
        $known = @{}
        if ($state.Nets) {
            foreach ($p in $state.Nets.PSObject.Properties) { $known[$p.Name] = [datetime]$p.Value }
        }

        $current = @(Resolve-ServiceNets @($state.AllowHost))
        if (-not $current.Count) { return }   # offline / DNS down: leave rules alone
        $new = @($current | Where-Object { -not $known.ContainsKey($_) })

        $now = Get-Date
        foreach ($n in $current) { $known[$n] = $now }
        $expired = @($known.Keys | Where-Object { ($now - $known[$_]).TotalDays -gt $NetTtlDays })
        foreach ($n in $expired) { $known.Remove($n) }

        if ($new.Count -or $expired.Count) {
            $lists = Read-CachedLists
            if (-not $lists) { Write-RefreshLog 'No cached lists; cannot rebuild.'; return }
            $plan = Get-BlockPlan $lists $state.Keep @($known.Keys)
            Set-Rules $plan $state.Keep $state.Exe
            Write-RefreshLog "Rebuilt rules. New login /24s: $($new -join ', '). Expired: $($expired -join ', ')"
        }
        $netMap = @{}
        foreach ($k in $known.Keys) { $netMap[$k] = $known[$k].ToString('o') }
        Save-State $state.Keep $state.Exe @($state.AllowHost) $netMap
    }
    default { Show-Status }
}
