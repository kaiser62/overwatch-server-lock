<#
.SYNOPSIS
  Force Overwatch 2 onto one server region (default: Singapore) by firewall-blocking every other datacenter.

.DESCRIPTION
  Builds per-region IP lists from Google's published Google Cloud ranges (cloud.json, grouped by cloud
  region) plus Blizzard-owned datacenter ranges, subtracts the region you keep and the Battle.net
  login/patch endpoints, and adds Windows Firewall block rules (IPv4 and IPv6) scoped to Overwatch.exe
  only (other apps using Google Cloud are untouched).

  The Google ranges are cached; -On uses the cache and only downloads when none exists. -Update
  re-downloads them when Google has published a new version and re-applies an active lock.

  Battle.net login hosts rotate IPs. -On registers a SYSTEM scheduled task that re-resolves them every
  few minutes (-Refresh) and rebuilds the rules from the cached lists when a new IP block appears.

.EXAMPLE
  .\ow-lock.ps1 -On          # block everything except Singapore, enable login IP auto-refresh
  .\ow-lock.ps1 -Update      # fetch newer datacenter lists, re-apply the lock if on
  .\ow-lock.ps1 -Off         # remove all rules and the refresh task
  .\ow-lock.ps1 -Status      # show current state
  .\ow-lock.ps1 -On -DryRun  # preview, no changes
  .\ow-lock.ps1 -On -Keep Japan -GamePath 'D:\Games\Overwatch\Overwatch.exe'
  .\ow-lock.ps1 -On -Keep 'NA West|NA Central'   # keep several regions
  .\ow-lock.ps1 -On -AllowHost 'some.login.host' -NoAutoRefresh
  .\ow-lock.ps1 -On -OwnerPid 1234   # unlock automatically once process 1234 exits
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'On', Mandatory)][switch]$On,
    [Parameter(ParameterSetName = 'Off', Mandatory)][switch]$Off,
    [Parameter(ParameterSetName = 'Status')][switch]$Status,
    # Re-resolve login hosts and rebuild rules if their IPs moved (run by the scheduled task).
    [Parameter(ParameterSetName = 'Refresh', Mandatory)][switch]$Refresh,
    # Check upstream for newer datacenter lists and re-apply the lock if it is on.
    [Parameter(ParameterSetName = 'Update', Mandatory)][switch]$Update,
    # Regex matched against region names (see $Regions); matching regions are kept reachable.
    [Parameter(ParameterSetName = 'On')][string]$Keep = 'Singapore',
    [Parameter(ParameterSetName = 'On')][string]$GamePath,
    # Extra hostnames (e.g. a regional Battle.net login server) to keep reachable. Comma-separated is fine.
    [Parameter(ParameterSetName = 'On')][string[]]$AllowHost = @(),
    # Do not register the login IP auto-refresh task.
    [Parameter(ParameterSetName = 'On')][switch]$NoAutoRefresh,
    # Temporary lock: the refresh task unlocks once this process exits (the GUI passes its own PID).
    [Parameter(ParameterSetName = 'On')][int]$OwnerPid,
    # Show what would be blocked without touching the firewall.
    [Parameter(ParameterSetName = 'On')][switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$RuleGroup   = 'OW-ForceServer'
$TaskName    = 'OverwatchServerLock-Refresh'
$CloudUrl    = 'https://www.gstatic.com/ipranges/cloud.json'
$StateDir    = Join-Path $env:ProgramData 'OverwatchServerLock'
$StateFile   = Join-Path $StateDir 'state.json'
$CacheFile   = Join-Path $StateDir 'gcp-ranges.json'
$LegacyCache = Join-Path $StateDir 'ow-ip-cache.json'
$RefreshLog  = Join-Path $StateDir 'refresh.log'
$ChunkSize   = 500   # remote addresses per firewall rule
$RefreshMins = 2     # how often the task re-resolves login hosts
$NetTtlDays  = 7     # keep previously seen login /24s open this long (hosts rotate through pools)

# Overwatch datacenters by region. Gcp is a regex on Google Cloud region names (the "scope" field in
# cloud.json), so new zones in a family are picked up automatically. Ranges are datacenters outside
# Google's list: Blizzard-owned blocks, and AWS me-south-1 for Bahrain.
# Google regions that match no entry (India, Canada, Mexico, Africa, ...) are never blocked.
$Regions = [ordered]@{
    'Singapore'   = @{ Gcp = '^asia-southeast';      Ranges = @() }
    'Japan'       = @{ Gcp = '^asia-northeast[12]$'; Ranges = @() }
    'South Korea' = @{ Gcp = '^asia-northeast3$';    Ranges = '121.254.0.0/16', '117.52.0.0/16', '202.9.66.0/23', '110.45.208.0/24', '182.162.31.0/24' }
    'Taiwan'      = @{ Gcp = '^asia-east';           Ranges = '5.42.160.0/22', '5.42.164.0/22' }
    'Australia'   = @{ Gcp = '^australia-';          Ranges = '158.115.196.0/23', '37.244.42.0/24' }
    'NA West'     = @{ Gcp = '^us-west';             Ranges = '64.224.24.0/23', '24.105.8.0/21' }
    'NA Central'  = @{ Gcp = '^us-central';          Ranges = '64.224.0.0/21', '24.105.40.0/21' }
    'NA East'     = @{ Gcp = '^us-east';             Ranges = @() }
    'Brazil'      = @{ Gcp = '^southamerica-';       Ranges = @() }
    'Europe'      = @{ Gcp = '^europe-';             Ranges = '64.224.26.0/23', '5.42.168.0/21' }
    'Middle East' = @{ Gcp = '^me-';                 Ranges = '157.175.0.0/16', '15.184.0.0/15', '16.24.0.0/16' }
}

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
        # Plain assignment: `$last = if (...) { $out[-1] }` would unroll the pair into a copy,
        # and extending the copy would silently drop the merged range.
        $last = $null
        if ($out.Count) { $last = $out[$out.Count - 1] }
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

# True when an IPv6 address falls inside an IPv6 CIDR.
function Test-InPrefix6([string]$addr, [string]$cidr) {
    $net, $len = $cidr -split '/'
    $a = [Net.IPAddress]::Parse($addr).GetAddressBytes()
    $n = [Net.IPAddress]::Parse($net).GetAddressBytes()
    for ($i = 0; $i -lt 16; $i++) {
        $bits = [math]::Min(8, [math]::Max(0, [int]$len - 8 * $i))
        if ($bits -eq 0) { break }
        $mask = (0xFF -shl (8 - $bits)) -band 0xFF
        if (($a[$i] -band $mask) -ne ($n[$i] -band $mask)) { return $false }
    }
    $true
}

# --- data --------------------------------------------------------------------
# State dir holds a copy of this script that SYSTEM runs, so only admins/SYSTEM may write to it.
# Always re-applied (owner too): a standard user could pre-create this folder under ProgramData.
function Initialize-StateDir {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
    $null = icacls $StateDir /setowner '*S-1-5-32-544' /T /C
    $null = icacls $StateDir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /C
    # Files just inherit the folder ACL. /reset also drops any extra grants on pre-created files.
    if (Get-ChildItem $StateDir -Force) { $null = icacls (Join-Path $StateDir '*') /reset /T /C }
}

# Cache: { SyncToken, CreationTime, Scopes: { "<google cloud region>": [ "<cidr>", ... ] } }.
function Read-GcpCache {
    if (-not (Test-Path $CacheFile)) { return $null }
    try { Get-Content $CacheFile -Raw -ErrorAction Stop | ConvertFrom-Json }
    catch { Write-Warning "Cannot read $CacheFile ($($_.Exception.Message)); run as administrator."; $null }
}

# Builds { region name: "cidr`ncidr..." } from the cached Google ranges and the fixed ranges in $Regions.
function ConvertTo-RegionLists($gcp) {
    $scopes = @($gcp.Scopes.PSObject.Properties)
    $lists = [ordered]@{}
    foreach ($name in $Regions.Keys) {
        $r = $Regions[$name]
        $cidrs = @($r.Ranges) + @($scopes | Where-Object { $_.Name -match $r.Gcp } | ForEach-Object { $_.Value })
        $lists[$name] = $cidrs -join "`n"
    }
    $lists
}

# Cache first; -Online downloads cloud.json (one request) and keeps the cache when its syncToken is unchanged.
function Get-IpLists([switch]$Online) {
    $cache = Read-GcpCache
    if ($cache -and -not $Online) {
        Write-Host "Using cached Google Cloud ranges ($($cache.CreationTime)). Use Update IP lists to refresh." -ForegroundColor DarkGray
        return ConvertTo-RegionLists $cache
    }
    try {
        $json = Invoke-RestMethod $CloudUrl -Headers @{ 'User-Agent' = 'ow-server-lock' }
        if ($cache -and $cache.SyncToken -eq $json.syncToken) {
            Write-Host "IP lists unchanged upstream (Google Cloud ranges of $($cache.CreationTime))." -ForegroundColor DarkGray
            return ConvertTo-RegionLists $cache
        }
        $scopes = [ordered]@{}
        foreach ($p in $json.prefixes) {
            $cidr = if ($p.ipv4Prefix) { $p.ipv4Prefix } else { $p.ipv6Prefix }
            if (-not $scopes.Contains($p.scope)) { $scopes[$p.scope] = New-Object Collections.Generic.List[string] }
            $scopes[$p.scope].Add($cidr)
        }
        $text = [ordered]@{ SyncToken = $json.syncToken; CreationTime = $json.creationTime; Scopes = $scopes } |
            ConvertTo-Json -Depth 4 -Compress
        Write-Host "Downloaded Google Cloud ranges of $($json.creationTime) ($(@($json.prefixes).Count) prefixes)." -ForegroundColor DarkGray
        if (-not $DryRun -and $isAdmin) {
            Initialize-StateDir
            Set-Content $CacheFile $text -Encoding UTF8
            if (Test-Path $LegacyCache) { Remove-Item $LegacyCache }
        }
        return ConvertTo-RegionLists ($text | ConvertFrom-Json)
    }
    catch {
        if (-not $cache) { throw "Could not download Google Cloud IP ranges and no cache found: $_" }
        Write-Warning "Download failed ($($_.Exception.Message)); using cached ranges from $CacheFile"
        return ConvertTo-RegionLists $cache
    }
}

function Read-State {
    if (-not (Test-Path $StateFile)) { return $null }
    Get-Content $StateFile -Raw | ConvertFrom-Json
}

# Owner: { Pid, Start } of the process whose exit ends a temporary lock, or $null.
function Save-State($keep, $exe, $allowHost, [hashtable]$nets, $owner) {
    [ordered]@{ Keep = $keep; Exe = $exe; AllowHost = @($allowHost); Nets = $nets; Owner = $owner; LastCheck = (Get-Date).ToString('o') } |
        ConvertTo-Json -Depth 4 | Set-Content $StateFile -Encoding UTF8
}

# Resolves login/patch hosts to their /24 network bases (e.g. "34.64.53.0"); IPv6 addresses as-is.
function Resolve-ServiceNets([string[]]$extraHosts) {
    @(foreach ($h in @($ServiceHosts) + @($extraHosts)) {
        if (-not $h) { continue }
        try {
            [Net.Dns]::GetHostAddresses($h) | ForEach-Object {
                if ($_.AddressFamily -eq 'InterNetwork') { $_.IPAddressToString -replace '\.\d+$', '.0' }
                elseif (-not $_.IsIPv6LinkLocal) { $_.IPAddressToString }
            }
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

# Computes the ranges to block: every region not matching $keep, minus kept regions and login hosts.
# IPv4 is range-subtracted; IPv6 prefixes are dropped whole when kept or when a login host is inside.
function Get-BlockPlan($lists, [string]$keep, [string[]]$nets) {
    $keepNames  = @($lists.Keys | Where-Object { $_ -match $keep })
    $blockNames = @($lists.Keys | Where-Object { $_ -notmatch $keep })
    if (-not $keepNames.Count) {
        throw "No region matches -Keep '$keep'. Available: $($lists.Keys -join ', ')"
    }
    $nets6  = @($nets | Where-Object { $_ -match ':' })
    $keep6  = @($keepNames | ForEach-Object { $lists[$_] -split "`n" } | Where-Object { $_ -match ':' })
    $block6 = @($blockNames | ForEach-Object { $lists[$_] -split "`n" } | Where-Object { $_ -match ':' } |
        Where-Object { $keep6 -notcontains $_ } | Sort-Object -Unique |
        Where-Object { $c6 = $_; -not @($nets6 | Where-Object { Test-InPrefix6 $_ $c6 }).Count })
    $netText    = ($nets | Where-Object { $_ -notmatch ':' } | ForEach-Object { "$_/24" }) -join "`n"
    $keepRanges = Merge-IpRanges @(
        @($keepNames | ForEach-Object { ConvertFrom-IpList $lists[$_] }) +
        @(ConvertFrom-IpList $netText))
    $blockRanges = Merge-IpRanges @($blockNames | ForEach-Object { ConvertFrom-IpList $lists[$_] })
    $final       = Remove-IpRanges $blockRanges $keepRanges
    $addresses = @($final | ForEach-Object {
        if ($_[0] -eq $_[1]) { ConvertTo-IpString $_[0] }
        else { '{0}-{1}' -f (ConvertTo-IpString $_[0]), (ConvertTo-IpString $_[1]) }
    }) + $block6
    if (-not $addresses.Count) { throw 'Nothing to block after subtracting kept ranges.' }
    [pscustomobject]@{ Addresses = $addresses; V6Count = $block6.Count; KeepNames = $keepNames; BlockNames = $blockNames }
}

function Set-Rules($plan, [string]$keep, [string]$exe) {
    [void](Remove-Rules)
    $desc = "Force Overwatch to '$keep' (kept: $($plan.KeepNames -join ', '))"
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
    if ($PSCommandPath -ne $target -and
        (-not (Test-Path $target) -or (Get-FileHash $PSCommandPath).Hash -ne (Get-FileHash $target).Hash)) {
        Copy-Item $PSCommandPath $target -Force
    }
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`" -Refresh"

    # Re-registering is slow; skip when an identical task already exists.
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing -and $existing.State -ne 'Disabled' -and
        $existing.Actions[0].Arguments -eq $arguments -and
        $existing.Triggers[0].Repetition.Interval -eq "PT$($RefreshMins)M") { return }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
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
    if ($task) {
        $state = Read-State
        $last = if ($state -and $state.LastCheck) { ([datetime]$state.LastCheck).ToString('g') } else { 'never' }
        Write-Host "  Login IP refresh: every $RefreshMins min, last check $last, $(@($state.Nets.PSObject.Properties).Count) login /24s open"
        if ($state -and $state.Owner) { Write-Host "  Temporary: unlocks when process $($state.Owner.Pid) exits" }
    }
    elseif (-not $isAdmin) { Write-Host '  Login IP refresh: unknown (run as admin to see the SYSTEM task)' }
    else { Write-Host '  Login IP refresh: off' }
    Write-Host '  Verify in match: Ctrl+Shift+N shows server IP.'
}

switch ($PSCmdlet.ParameterSetName) {
    'Off' {
        $n = Remove-Rules
        Unregister-RefreshTask
        if (Test-Path $StateFile) { Remove-Item $StateFile }
        if (Test-Path $StateDir) { Write-RefreshLog "Unlocked; removed $n rules." }
        Write-Host "Removed $n rules and the refresh task. Overwatch can use any server again." -ForegroundColor Green
    }
    'On' {
        $exe   = Find-Overwatch
        $owner = $null
        if ($OwnerPid) {
            $op = Get-Process -Id $OwnerPid -ErrorAction Stop
            $owner = [ordered]@{ Pid = $OwnerPid; Start = [string]$op.StartTime.ToUniversalTime().Ticks }
        }
        $lists = Get-IpLists
        $nets  = @(Resolve-ServiceNets $AllowHost)
        $plan  = Get-BlockPlan $lists $Keep $nets

        if ($DryRun) {
            Write-Host "Dry run: would block $($plan.Addresses.Count) ranges ($($plan.V6Count) IPv6) for $exe" -ForegroundColor Cyan
            Write-Host "Kept: $($plan.KeepNames -join ', ')"
            Write-Host "Battle.net login/patch /24s kept: $($nets -join ', ')"
            Write-Host "Blocked regions: $($plan.BlockNames -join ', ')"
            Write-Host "Sample: $($plan.Addresses[0..4] -join ', ')"
            Write-Verbose ($plan.Addresses -join "`n")
            return
        }

        # Keep login /24s seen recently by the refresh task, so re-locking never drops a working one.
        $netMap = @{}
        $prev = Read-State
        if ($prev -and $prev.Nets) {
            foreach ($p in $prev.Nets.PSObject.Properties) {
                if (((Get-Date) - [datetime]$p.Value).TotalDays -le $NetTtlDays) { $netMap[$p.Name] = $p.Value }
            }
        }
        $now = (Get-Date).ToString('o')
        foreach ($n in $nets) { $netMap[$n] = $now }
        if ($netMap.Count -gt $nets.Count) { $plan = Get-BlockPlan $lists $Keep @($netMap.Keys) }

        Set-Rules $plan $Keep $exe
        Initialize-StateDir
        Save-State $Keep $exe $AllowHost $netMap $owner
        # A temporary lock needs the task: it is what unlocks after the owner exits.
        if ($NoAutoRefresh -and -not $owner) { Unregister-RefreshTask } else { Register-RefreshTask }
        $until = if ($owner) { " until process $OwnerPid exits" } else { '' }
        Write-RefreshLog "Locked to '$Keep'$until. Login /24s open: $($nets -join ', ')"

        Write-Host "Blocked $($plan.Addresses.Count) ranges ($($plan.V6Count) IPv6) from $($plan.BlockNames.Count) regions for:" -ForegroundColor Green
        Write-Host "  $exe"
        Write-Host "Kept reachable: $($plan.KeepNames -join ', ')"
        Write-Host "Battle.net login/patch /24s kept: $($nets.Count)"
        if (-not $NoAutoRefresh -or $owner) { Write-Host "Login IPs re-checked every $RefreshMins min." }
        if ($owner) { Write-Host "Temporary lock: unlocks automatically when process $OwnerPid exits." }
        Write-Host 'Restart Overwatch if it is running. Unlock before grouping with friends on other servers.'
    }
    'Update' {
        $lists = Get-IpLists -Online
        $state = Read-State
        if (-not $state -or -not @(Get-NetFirewallRule -Group $RuleGroup -ErrorAction SilentlyContinue).Count) {
            Write-Host 'Not locked; the new lists will be used on the next Lock.' -ForegroundColor Green
            return
        }
        $nets = @(Resolve-ServiceNets @($state.AllowHost))
        if ($state.Nets) { $nets = @(@($nets) + @($state.Nets.PSObject.Properties.Name) | Sort-Object -Unique) }
        $plan = Get-BlockPlan $lists $state.Keep $nets
        Set-Rules $plan $state.Keep $state.Exe
        Write-RefreshLog "Lists updated; lock re-applied with $($plan.Addresses.Count) ranges."
        Write-Host "Re-applied lock to '$($state.Keep)': $($plan.Addresses.Count) ranges blocked." -ForegroundColor Green
    }
    'Refresh' {
        $state = Read-State
        if (-not $state -or -not @(Get-NetFirewallRule -Group $RuleGroup -ErrorAction SilentlyContinue).Count) {
            # Lock was removed some other way; clean up after ourselves.
            Unregister-RefreshTask
            return
        }
        if ($state.Owner) {
            # Temporary lock: end it once the owning window is gone (closed, crashed, or rebooted).
            $op = Get-Process -Id $state.Owner.Pid -ErrorAction SilentlyContinue
            if (-not $op -or [string]$op.StartTime.ToUniversalTime().Ticks -ne $state.Owner.Start) {
                $n = Remove-Rules
                Remove-Item $StateFile
                Write-RefreshLog "Temporary lock ended (process $($state.Owner.Pid) exited); removed $n rules."
                Unregister-RefreshTask
                return
            }
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
            $cache = Read-GcpCache
            if (-not $cache) { Write-RefreshLog 'No cached ranges; cannot rebuild.'; return }
            $lists = ConvertTo-RegionLists $cache
            $plan = Get-BlockPlan $lists $state.Keep @($known.Keys)
            Set-Rules $plan $state.Keep $state.Exe
            Write-RefreshLog "Rebuilt rules. New login /24s: $($new -join ', '). Expired: $($expired -join ', ')"
        }
        $netMap = @{}
        foreach ($k in $known.Keys) { $netMap[$k] = $known[$k].ToString('o') }
        Save-State $state.Keep $state.Exe @($state.AllowHost) $netMap $state.Owner
    }
    default { Show-Status }
}
