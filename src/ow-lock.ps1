<#
.SYNOPSIS
  Force Overwatch 2 onto one server region (default: Singapore) by firewall-blocking every other datacenter.

.DESCRIPTION
  Pulls the community-maintained datacenter IP lists from foryVERX/Overwatch-Server-Selector,
  subtracts the ranges of the region you keep, and adds Windows Firewall block rules
  scoped to Overwatch.exe only (other apps using Google Cloud are untouched).

.EXAMPLE
  .\ow-lock.ps1 -On          # block everything except Singapore
  .\ow-lock.ps1 -Off         # remove all rules
  .\ow-lock.ps1 -Status      # show current state
  .\ow-lock.ps1 -On -DryRun  # preview, no changes
  .\ow-lock.ps1 -On -Keep Japan -GamePath 'D:\Games\Overwatch\Overwatch.exe'
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'On', Mandatory)][switch]$On,
    [Parameter(ParameterSetName = 'Off', Mandatory)][switch]$Off,
    [Parameter(ParameterSetName = 'Status')][switch]$Status,
    # Regex matched against IP list file names; matching lists are kept reachable.
    [Parameter(ParameterSetName = 'On')][string]$Keep = 'Singapore',
    [Parameter(ParameterSetName = 'On')][string]$GamePath,
    # Extra hostnames (e.g. a regional Battle.net login server) to keep reachable.
    [Parameter(ParameterSetName = 'On')][string[]]$AllowHost = @(),
    # Show what would be blocked without touching the firewall.
    [Parameter(ParameterSetName = 'On')][switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$RuleGroup = 'OW-ForceServer'
$RepoApi   = 'https://api.github.com/repos/foryVERX/Overwatch-Server-Selector/contents/ip_lists'
$CacheFile = Join-Path $PSScriptRoot 'ow-ip-cache.json'
$ChunkSize = 500   # remote addresses per firewall rule

# Battle.net login/patch endpoints live inside the Google Cloud ranges we block
# (e.g. kr.actual.battle.net sits in the Korea list). Their /24s are always kept reachable.
$ServiceHosts = @(
    'us.actual.battle.net', 'eu.actual.battle.net', 'kr.actual.battle.net', 'tw.actual.battle.net',
    'us.version.battle.net', 'eu.version.battle.net', 'kr.version.battle.net',
    'us.patch.battle.net', 'eu.patch.battle.net', 'kr.patch.battle.net', 'prod.depot.battle.net'
)

# --- elevation ---------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun -and $PSCmdlet.ParameterSetName -ne 'Status') {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
    foreach ($p in $PSBoundParameters.GetEnumerator()) {
        if ($p.Value -is [switch]) { $argList += "-$($p.Key)" }
        else { $argList += "-$($p.Key)"; $argList += "`"$($p.Value)`"" }
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
        $lists | ConvertTo-Json | Set-Content $CacheFile -Encoding UTF8
        Write-Host "Fetched $($lists.Count) IP lists from GitHub." -ForegroundColor DarkGray
        return $lists
    }
    catch {
        if (-not (Test-Path $CacheFile)) { throw "Could not fetch IP lists and no cache found: $_" }
        Write-Warning "GitHub fetch failed ($($_.Exception.Message)); using cached lists from $CacheFile"
        $obj = Get-Content $CacheFile -Raw | ConvertFrom-Json
        $lists = [ordered]@{}
        foreach ($p in $obj.PSObject.Properties) { $lists[$p.Name] = $p.Value }
        return $lists
    }
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

function Show-Status {
    $rules = @(Get-NetFirewallRule -Group $RuleGroup -ErrorAction SilentlyContinue)
    if (-not $rules.Count) {
        Write-Host 'OFF - no Overwatch server rules present. Matchmaking picks any region.' -ForegroundColor Yellow
        return
    }
    $app = ($rules[0] | Get-NetFirewallApplicationFilter).Program
    $out = @($rules | Where-Object Direction -eq 'Outbound')
    $count = ($out | Get-NetFirewallAddressFilter | ForEach-Object { @($_.RemoteAddress).Count } | Measure-Object -Sum).Sum
    Write-Host "ON - $($rules[0].Description)" -ForegroundColor Green
    Write-Host "  Program : $app"
    Write-Host "  Rules   : $($rules.Count) ($($out.Count) outbound + inbound mirror)"
    Write-Host "  Blocked : $count IP ranges"
    Write-Host '  Verify in match: Ctrl+Shift+N shows server IP.'
}

switch ($PSCmdlet.ParameterSetName) {
    'Off' {
        $n = Remove-Rules
        Write-Host "Removed $n rules. Overwatch can use any server again." -ForegroundColor Green
    }
    'On' {
        $exe   = Find-Overwatch
        $lists = Get-IpLists

        $keepNames  = @($lists.Keys | Where-Object { $_ -match $Keep })
        $blockNames = @($lists.Keys | Where-Object { $_ -notmatch $Keep })
        if (-not $keepNames.Count) {
            throw "No IP list matches -Keep '$Keep'. Available: $($lists.Keys -join ', ')"
        }

        $serviceIps = @(foreach ($h in @($ServiceHosts) + $AllowHost) {
            try {
                [Net.Dns]::GetHostAddresses($h) | Where-Object AddressFamily -eq 'InterNetwork' |
                    ForEach-Object { $_.IPAddressToString }
            }
            catch { Write-Warning "Could not resolve $h" }
        }) | Sort-Object -Unique
        $serviceText = ($serviceIps | ForEach-Object { ($_ -replace '\.\d+$', '.0') + '/24' }) -join "`n"

        $keepRanges  = Merge-IpRanges @(
            @($keepNames | ForEach-Object { ConvertFrom-IpList $lists[$_] }) +
            @(ConvertFrom-IpList $serviceText))
        $blockRanges = Merge-IpRanges @($blockNames | ForEach-Object { ConvertFrom-IpList $lists[$_] })
        $final       = Remove-IpRanges $blockRanges $keepRanges

        $addresses = @($final | ForEach-Object {
            if ($_[0] -eq $_[1]) { ConvertTo-IpString $_[0] }
            else { '{0}-{1}' -f (ConvertTo-IpString $_[0]), (ConvertTo-IpString $_[1]) }
        })
        if (-not $addresses.Count) { throw 'Nothing to block after subtracting kept ranges.' }

        if ($DryRun) {
            Write-Host "Dry run: would block $($addresses.Count) ranges for $exe" -ForegroundColor Cyan
            Write-Host "Kept: $($keepNames -join ', ')"
            Write-Host "Battle.net service IPs kept: $($serviceIps -join ', ')"
            Write-Verbose ($addresses -join "`n")
            Write-Host "Blocked lists: $($blockNames -join ', ')"
            Write-Host "Sample: $($addresses[0..4] -join ', ')"
            return
        }

        [void](Remove-Rules)
        $desc = "Force Overwatch to '$Keep' (kept: $($keepNames -join '; '))"
        $i = 0
        for ($o = 0; $o -lt $addresses.Count; $o += $ChunkSize) {
            $i++
            $chunk = $addresses[$o..([math]::Min($o + $ChunkSize, $addresses.Count) - 1)]
            foreach ($dir in 'Outbound', 'Inbound') {
                $null = New-NetFirewallRule -DisplayName "OW Force $Keep - $dir $i" -Group $RuleGroup `
                    -Description $desc -Direction $dir -Action Block -Program $exe `
                    -RemoteAddress $chunk -Profile Any
            }
        }

        Write-Host "Blocked $($addresses.Count) ranges from $($blockNames.Count) lists for:" -ForegroundColor Green
        Write-Host "  $exe"
        Write-Host "Kept reachable: $($keepNames -join ', ')"
        Write-Host "Battle.net login/patch IPs kept: $($serviceIps.Count)"
        Write-Host 'Restart Overwatch if it is running. Turn off (-Off) before grouping with friends on other servers.'
    }
    default { Show-Status }
}
