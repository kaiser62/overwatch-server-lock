# Overwatch Server Lock - dark WinForms front end for ow-lock.ps1.
param(
    # Render the window to a PNG and exit (used for the README screenshot; no elevation needed).
    [string]$Screenshot
)

$ErrorActionPreference = 'Stop'
$core = Join-Path $PSScriptRoot 'ow-lock.ps1'
$iconPath = Join-Path $PSScriptRoot 'icon.ico'
if (-not (Test-Path $iconPath)) { $iconPath = Join-Path $PSScriptRoot '..\assets\icon.ico' }

# Firewall changes need admin; relaunch elevated with a hidden console.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $Screenshot) {
    Start-Process powershell -Verb RunAs -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
    return
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace OwLock -Name Dwm -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
'@
# Own taskbar identity, otherwise Windows groups the window under powershell.exe and shows its icon.
[void][OwLock.Dwm]::SetCurrentProcessExplicitAppUserModelID('kaiser62.OverwatchServerLock')
[Windows.Forms.Application]::EnableVisualStyles()

# --- theme -------------------------------------------------------------------
function Rgb($r, $g, $b) { [Drawing.Color]::FromArgb($r, $g, $b) }
$C = @{
    Bg         = Rgb 17 18 22
    Card       = Rgb 26 28 34
    Tile       = Rgb 32 35 42
    TileHover  = Rgb 42 46 55
    Border     = Rgb 50 54 64
    Text       = Rgb 236 238 242
    Muted      = Rgb 138 144 156
    Accent     = Rgb 249 158 26
    AccentDim  = Rgb 56 42 18
    AccentText = Rgb 22 20 16
    Ok         = Rgb 48 209 88
    Warn       = Rgb 255 159 10
    Err        = Rgb 255 69 58
}
function Font($size, $style = 'Regular', $family = 'Segoe UI') {
    New-Object Drawing.Font($family, [single]$size, [Drawing.FontStyle]$style)
}

# Region name (as known to ow-lock.ps1) -> an address in that datacenter that answers ping:
# a Blizzard-owned game server block where one replies, a Google Cloud address in the region otherwise.
$regionGroups = [ordered]@{
    'ASIA / PACIFIC' = [ordered]@{
        'Singapore'   = '34.1.128.4'
        'Japan'       = '34.84.0.0'
        'South Korea' = '121.254.137.1'
        'Taiwan'      = '5.42.160.1'
        'Australia'   = '158.115.196.1'
    }
    'AMERICAS' = [ordered]@{
        'NA West'     = '64.224.24.10'
        'NA Central'  = '64.224.0.10'
        'NA East'     = '34.11.0.1'
        'Brazil'      = '34.39.128.0'
    }
    'EUROPE / MIDDLE EAST' = [ordered]@{
        'Europe'      = '64.224.26.10'
        'Middle East' = '34.1.48.10'
    }
}
$pingIps = [ordered]@{}
foreach ($g in $regionGroups.Values) { foreach ($k in $g.Keys) { $pingIps[$k] = $g[$k] } }
$script:ping = @{}   # region -> last round trip in ms, -1 = no reply
$stateFile = Join-Path $env:ProgramData 'OverwatchServerLock\state.json'

# --- controls ----------------------------------------------------------------
function New-Label($text, $x, $y, $font, $color) {
    New-Object Windows.Forms.Label -Property @{
        Text = $text; Location = "$x,$y"; AutoSize = $true; Font = $font; ForeColor = $color; BackColor = 'Transparent'
    }
}

function New-FlatButton($text, $x, $y, $w, $h) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.SetBounds($x, $y, $w, $h)
    $b.FlatStyle = 'Flat'; $b.Cursor = 'Hand'; $b.TabStop = $false
    $b.Font = Font 10; $b.BackColor = $C.Tile; $b.ForeColor = $C.Text
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = $C.Border
    $b.FlatAppearance.MouseOverBackColor = $C.TileHover
    $b.FlatAppearance.MouseDownBackColor = $C.Border
    $b
}

$form = New-Object Windows.Forms.Form -Property @{
    Text = 'Overwatch Server Lock'; ClientSize = '440,700'; StartPosition = 'CenterScreen'
    FormBorderStyle = 'FixedSingle'; MaximizeBox = $false; BackColor = $C.Bg; ForeColor = $C.Text
    Font = Font 10
}
if (Test-Path $iconPath) { $form.Icon = New-Object Drawing.Icon $iconPath }
$form.Add_HandleCreated({
    $on = 1   # DWMWA_USE_IMMERSIVE_DARK_MODE
    [void][OwLock.Dwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$on, 4)
})

$title    = New-Label 'Overwatch Server Lock' 18 16 (Font 16 'Bold') $C.Text
$subtitle = New-Label 'Force matchmaking onto a single datacenter' 20 50 (Font 9.5) $C.Muted

# status card
$card = New-Object Windows.Forms.Panel -Property @{ Location = '20,84'; Size = '400,78'; BackColor = $C.Card }
$dot  = New-Label ([string][char]0x25CF) 14 12 (Font 20) $C.Muted
$stateText  = New-Label 'Checking...' 48 14 (Font 12.5 'Bold') $C.Text
$detailText = New-Label '' 50 46 (Font 9) $C.Muted
$card.Controls.AddRange(@($dot, $stateText, $detailText))

# region tiles, grouped
$btnUpdate = New-FlatButton 'Update IP lists' 300 174 120 24
$btnUpdate.Font = Font 8.5
$btnUpdate.ForeColor = $C.Muted
$pingFont = Font 8.5
# Paints the latest ping under the region name: green / amber / red by latency.
function Show-TilePing($tile, $e) {
    $ms = $script:ping[$tile.Tag]
    if ($null -eq $ms) { $text = '...'; $color = $C.Muted }
    elseif ($ms -lt 0) { $text = 'no reply'; $color = $C.Muted }
    else {
        $text = "$ms ms"
        $color = if ($ms -lt 80) { $C.Ok } elseif ($ms -lt 160) { $C.Warn } else { $C.Err }
    }
    [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $text, $pingFont, (New-Object Drawing.Point 9, 23), $color)
}

$groupLabels = @()
$tiles = @{}
$y = 180
foreach ($group in $regionGroups.Keys) {
    $groupLabels += New-Label $group 20 $y (Font 8.5 'Bold') $C.Muted
    $y += 22
    $i = 0
    foreach ($name in $regionGroups[$group].Keys) {
        $col = $i % 3
        if ($i -gt 0 -and $col -eq 0) { $y += 52 }
        $t = New-FlatButton $name (20 + $col * 136) $y 128 46
        $t.Tag = $name
        $t.TextAlign = 'TopLeft'
        $t.Padding = '4,3,0,0'
        $t.Add_Click({ Set-Selected $this.Tag })
        $t.Add_Paint({ param($sender, $e) Show-TilePing $sender $e })
        $tiles[$name] = $t
        $i++
    }
    $y += 60
}

# actions
$btnLock = New-FlatButton 'Lock' 20 $y 196 46
$btnLock.Font = Font 11 'Bold'
$btnLock.BackColor = $C.Accent; $btnLock.ForeColor = $C.AccentText
$btnLock.FlatAppearance.BorderSize = 0
$btnLock.FlatAppearance.MouseOverBackColor = Rgb 255 178 64
$btnLock.FlatAppearance.MouseDownBackColor = Rgb 220 136 16

$btnUnlock = New-FlatButton 'Unlock' 224 $y 196 46
$btnUnlock.Font = Font 11 'Bold'

$chkTemp = New-Object Windows.Forms.CheckBox -Property @{
    Text = 'Unlock automatically when this window closes'; Location = "20,$($y + 56)"; AutoSize = $true
    FlatStyle = 'Flat'; ForeColor = $C.Muted; BackColor = $C.Bg; Font = Font 9; Cursor = 'Hand'; TabStop = $false
}
$chkTemp.FlatAppearance.BorderColor = $C.Border
$chkTemp.FlatAppearance.CheckedBackColor = $C.Accent

# log
$logWrap = New-Object Windows.Forms.Panel -Property @{ Location = "20,$($y + 86)"; Size = '400,74'; BackColor = $C.Card; Padding = '10,8,6,6' }
$log = New-Object Windows.Forms.TextBox -Property @{
    Dock = 'Fill'; Multiline = $true; ReadOnly = $true; ScrollBars = 'None'; BorderStyle = 'None'; TabStop = $false
    BackColor = $C.Card; ForeColor = $C.Muted; Font = Font 8.5 'Regular' 'Consolas'; Text = 'Ready.'
}
$logWrap.Controls.Add($log)

$footer = New-Label 'Verify in a match: Ctrl+Shift+N shows the server IP' 20 ($y + 170) (Font 8.5) $C.Muted

$form.ClientSize = "440,$($y + 196)"
$form.Controls.AddRange(@($title, $subtitle, $card, $btnUpdate, $btnLock, $btnUnlock, $chkTemp, $logWrap, $footer) + $groupLabels)
$form.Controls.AddRange([Windows.Forms.Control[]]$tiles.Values)

# --- behaviour ---------------------------------------------------------------
$script:selected = 'Singapore'
$script:job = $null
$script:tempOwned = $false   # this window holds a temporary lock and ends it on close

function Set-Selected([string]$name) {
    $script:selected = $name
    foreach ($t in $tiles.Values) {
        $on = $t.Tag -eq $name
        $t.BackColor = if ($on) { $C.AccentDim } else { $C.Tile }
        $t.ForeColor = if ($on) { $C.Accent } else { $C.Text }
        $t.FlatAppearance.BorderColor = if ($on) { $C.Accent } else { $C.Border }
        $t.FlatAppearance.MouseOverBackColor = if ($on) { $C.AccentDim } else { $C.TileHover }
        $t.Font = if ($on) { Font 10 'Bold' } else { Font 10 }
    }
    $btnLock.Text = "Lock to $name"
}

function Set-State([string]$text, [string]$detail, $color) {
    $stateText.Text = $text; $detailText.Text = $detail; $dot.ForeColor = $color
}

function Update-Status {
    $rules = @(Get-NetFirewallRule -Group 'OW-ForceServer' -ErrorAction SilentlyContinue)
    if (-not $rules.Count) {
        Set-State 'Unlocked' 'Matchmaking can use any datacenter' $C.Warn
        $script:tempOwned = $false
        return
    }
    $name = $rules[0].DisplayName -replace '^OW Force (.+?) - \w+ \d+$', '$1'
    $ranges = ($rules | Where-Object Direction -eq 'Outbound' | Get-NetFirewallAddressFilter |
        ForEach-Object { @($_.RemoteAddress).Count } | Measure-Object -Sum).Sum
    $state = $null
    try { $state = Get-Content $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { }
    $script:tempOwned = [bool]($state -and $state.Owner -and [int]$state.Owner.Pid -eq $PID)
    $detail = if ($script:tempOwned) { 'unlocks when this window closes' }
              elseif ($state -and $state.Owner) { 'temporary lock' }
              elseif (Get-ScheduledTask -TaskName 'OverwatchServerLock-Refresh' -ErrorAction SilentlyContinue) { 'login IPs auto-refresh' }
              else { 'login IP refresh off' }
    Set-State "Locked to $name" "$ranges ranges blocked, $detail" $C.Ok
    if ($tiles.Contains($name)) { Set-Selected $name }
}

function Set-Busy([bool]$busy, [string]$text, [string]$detail) {
    # Not $c: PowerShell names are case-insensitive and $C is the theme.
    foreach ($ctl in @($btnLock, $btnUnlock, $btnUpdate, $chkTemp) + @($tiles.Values)) { $ctl.Enabled = -not $busy }
    $form.UseWaitCursor = $busy
    if ($busy) { Set-State $text $detail $C.Accent; $log.Text = '' }
}

# All work runs on one long-lived background runspace: the window stays responsive, and the slow
# first-use module loads (firewall, scheduled tasks) happen once, in a warm-up while the user picks a region.
$runspace = [runspacefactory]::CreateRunspace()
$runspace.Open()
$runCore = { param($core, $p) & $core @p *>&1 | ForEach-Object { "$_" } }
$timer = New-Object Windows.Forms.Timer -Property @{ Interval = 120 }
$script:pending = $null

function Invoke-Background([scriptblock]$body, [object[]]$arguments, [bool]$quiet) {
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($body)
    foreach ($a in $arguments) { [void]$ps.AddArgument($a) }
    $script:job = @{ PS = $ps; Handle = $ps.BeginInvoke(); Quiet = $quiet }
    $timer.Start()
}

function Start-Core([hashtable]$params, [string]$busyText, [string]$detail) {
    if ($script:job -and -not $script:job.Quiet) { return }
    Set-Busy $true $busyText $detail
    if ($script:job) { $script:pending = $params; return }   # warm-up still running; start right after
    Invoke-Background $runCore @($core, $params) $false
}

$timer.Add_Tick({
    if (-not $script:job.Handle.IsCompleted) { return }
    $timer.Stop()
    $done = $script:job
    $script:job = $null

    if ($done.Quiet) {
        try { [void]$done.PS.EndInvoke($done.Handle) } catch { } finally { $done.PS.Dispose() }
        if ($script:pending) {
            $p = $script:pending; $script:pending = $null
            Invoke-Background $runCore @($core, $p) $false
        }
        return
    }

    $failed = $false
    try {
        $out = @($done.PS.EndInvoke($done.Handle))
        $out += @($done.PS.Streams.Error | ForEach-Object { "ERROR: $($_.Exception.Message)" })
        $log.Text = $out -join "`r`n"
    }
    catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        $log.Text = "ERROR: $($e.Message)"
        $failed = $true
    }
    finally {
        $done.PS.Dispose()
        Set-Busy $false '' ''
        Update-Status
        if ($failed) { $dot.ForeColor = $C.Err }
    }
})

$btnLock.Add_Click({
    $p = @{ On = $true; Keep = $script:selected }
    if ($chkTemp.Checked) { $p.OwnerPid = $PID }
    Start-Core $p "Locking to $($script:selected)..." 'Updating firewall rules...'
})
$btnUnlock.Add_Click({ Start-Core @{ Off = $true } 'Unlocking...' 'Removing firewall rules...' })
$btnUpdate.Add_Click({
    Start-Core @{ Update = $true } 'Updating IP lists...' 'Checking Google for newer cloud IP ranges...'
})
# Live ping: one async ICMP round to every region, then wait 10 s. Polled from a UI timer so no
# PowerShell code runs on thread-pool threads.
$pingTimer = New-Object Windows.Forms.Timer -Property @{ Interval = 400 }
$script:pingRound = $null
$script:nextPing = [datetime]::MinValue
function Start-PingRound {
    $script:pingRound = @{}
    foreach ($k in $pingIps.Keys) {
        $pinger = New-Object Net.NetworkInformation.Ping
        $script:pingRound[$k] = @{ Pinger = $pinger; Task = $pinger.SendPingAsync($pingIps[$k], 2000) }
    }
}
$pingTimer.Add_Tick({
    if (-not $script:pingRound) {
        if ((Get-Date) -ge $script:nextPing) { Start-PingRound }
        return
    }
    foreach ($r in $script:pingRound.Values) { if (-not $r.Task.IsCompleted) { return } }
    foreach ($k in $script:pingRound.Keys) {
        $r = $script:pingRound[$k]
        $ok = $r.Task.Status -eq 'RanToCompletion' -and $r.Task.Result.Status -eq 'Success'
        $script:ping[$k] = if ($ok) { [int]$r.Task.Result.RoundtripTime } else { -1 }
        $r.Pinger.Dispose()
        $tiles[$k].Invalidate()
    }
    $script:pingRound = $null
    $script:nextPing = (Get-Date).AddSeconds(10)
})

# A temporary lock ends with the window. If this process dies instead, the SYSTEM refresh task
# notices the PID is gone and unlocks within a couple of minutes.
$form.Add_FormClosing({
    param($sender, $e)
    if ($script:job -and -not $script:job.Quiet) {
        $e.Cancel = $true
        $log.Text = 'Wait for the current action to finish, then close.'
        return
    }
    if ($script:tempOwned) {
        Set-Busy $true 'Unlocking...' 'Temporary lock ends with this window'
        $form.Refresh()
        try { & $core -Off *> $null } catch { }
    }
})
$form.Add_FormClosed({ $pingTimer.Stop(); $runspace.Dispose() })

Set-Selected 'Singapore'
Update-Status
$form.Add_Shown({
    $form.ActiveControl = $title
    if (-not $Screenshot) {
        Invoke-Background {
            Import-Module NetSecurity, ScheduledTasks
            $null = Get-NetFirewallRule -Group 'OW-ForceServer' -ErrorAction SilentlyContinue
            $null = Get-ScheduledTask -TaskName 'OverwatchServerLock-Refresh' -ErrorAction SilentlyContinue
        } @() $true
        $pingTimer.Start()
    }
})

if ($Screenshot) {
    foreach ($k in $pingIps.Keys) {
        try { $r = (New-Object Net.NetworkInformation.Ping).Send($pingIps[$k], 1500) } catch { $r = $null }
        $script:ping[$k] = if ($r -and $r.Status -eq 'Success') { [int]$r.RoundtripTime } else { -1 }
    }
    $form.Add_Shown({
        $form.ActiveControl = $title
        $form.Refresh()
        $full = New-Object Drawing.Bitmap $form.Width, $form.Height
        $form.DrawToBitmap($full, (New-Object Drawing.Rectangle 0, 0, $form.Width, $form.Height))
        # keep only the client area; DrawToBitmap paints a classic (light) title bar
        $origin = $form.PointToScreen([Drawing.Point]::Empty)
        $client = New-Object Drawing.Rectangle ($origin.X - $form.Left), ($origin.Y - $form.Top), $form.ClientSize.Width, $form.ClientSize.Height
        $full.Clone($client, $full.PixelFormat).Save($Screenshot, [Drawing.Imaging.ImageFormat]::Png)
        $form.Close()
    })
}
[void]$form.ShowDialog()
