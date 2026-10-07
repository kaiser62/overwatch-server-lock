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
'@
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

# Display name -> regex matched against IP list file names.
$regions = [ordered]@{
    'Singapore'   = 'Singapore'
    'Japan'       = 'Japan'
    'South Korea' = 'Korea'
    'Taiwan'      = 'Taiwan'
    'Australia'   = 'Australia'
    'Middle East' = 'ME\.txt|Bahrain|Qatar|KSA'
}

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
    Text = 'Overwatch Server Lock'; ClientSize = '440,486'; StartPosition = 'CenterScreen'
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

# region tiles
$regionLabel = New-Label 'REGION' 20 180 (Font 8.5 'Bold') $C.Muted
$tiles = @{}
$i = 0
foreach ($name in $regions.Keys) {
    $col = $i % 3; $row = [math]::Floor($i / 3)
    $t = New-FlatButton $name (20 + $col * 136) (202 + $row * 50) 128 42
    $t.Tag = $name
    $t.Add_Click({ Set-Selected $this.Tag })
    $tiles[$name] = $t
    $i++
}

# actions
$btnLock = New-FlatButton 'Lock' 20 314 196 46
$btnLock.Font = Font 11 'Bold'
$btnLock.BackColor = $C.Accent; $btnLock.ForeColor = $C.AccentText
$btnLock.FlatAppearance.BorderSize = 0
$btnLock.FlatAppearance.MouseOverBackColor = Rgb 255 178 64
$btnLock.FlatAppearance.MouseDownBackColor = Rgb 220 136 16

$btnUnlock = New-FlatButton 'Unlock' 224 314 196 46
$btnUnlock.Font = Font 11 'Bold'

# log
$logWrap = New-Object Windows.Forms.Panel -Property @{ Location = '20,374'; Size = '400,74'; BackColor = $C.Card; Padding = '10,8,6,6' }
$log = New-Object Windows.Forms.TextBox -Property @{
    Dock = 'Fill'; Multiline = $true; ReadOnly = $true; ScrollBars = 'None'; BorderStyle = 'None'; TabStop = $false
    BackColor = $C.Card; ForeColor = $C.Muted; Font = Font 8.5 'Regular' 'Consolas'; Text = 'Ready.'
}
$logWrap.Controls.Add($log)

$footer = New-Label 'Verify in a match: Ctrl+Shift+N shows the server IP' 20 458 (Font 8.5) $C.Muted

$form.Controls.AddRange(@($title, $subtitle, $card, $regionLabel, $btnLock, $btnUnlock, $logWrap, $footer))
$form.Controls.AddRange([Windows.Forms.Control[]]$tiles.Values)

# --- behaviour ---------------------------------------------------------------
$script:selected = 'Singapore'
$script:job = $null

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
        return
    }
    $keep = $rules[0].DisplayName -replace '^OW Force (.+?) - \w+ \d+$', '$1'
    $name = @($regions.Keys | Where-Object { $regions[$_] -eq $keep })[0]
    if (-not $name) { $name = $keep }
    $ranges = ($rules | Where-Object Direction -eq 'Outbound' | Get-NetFirewallAddressFilter |
        ForEach-Object { @($_.RemoteAddress).Count } | Measure-Object -Sum).Sum
    Set-State "Locked to $name" "$ranges ranges blocked for Overwatch.exe" $C.Ok
    if ($tiles.Contains($name)) { Set-Selected $name }
}

function Set-Busy([bool]$busy, [string]$text) {
    foreach ($c in @($btnLock, $btnUnlock) + @($tiles.Values)) { $c.Enabled = -not $busy }
    $form.UseWaitCursor = $busy
    if ($busy) { Set-State $text 'Fetching server lists and updating firewall...' $C.Accent; $log.Text = '' }
}

# Run ow-lock.ps1 on a background runspace so the window stays responsive.
$timer = New-Object Windows.Forms.Timer -Property @{ Interval = 120 }
function Start-Core([hashtable]$params, [string]$busyText) {
    if ($script:job) { return }
    Set-Busy $true $busyText
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($core, $p)
        & $core @p *>&1 | ForEach-Object { "$_" }
    }).AddArgument($core).AddArgument($params)
    $script:job = @{ PS = $ps; Handle = $ps.BeginInvoke() }
    $timer.Start()
}

$timer.Add_Tick({
    if (-not $script:job.Handle.IsCompleted) { return }
    $timer.Stop()
    $failed = $false
    try {
        $out = @($script:job.PS.EndInvoke($script:job.Handle))
        $out += @($script:job.PS.Streams.Error | ForEach-Object { "ERROR: $($_.Exception.Message)" })
        $log.Text = $out -join "`r`n"
    }
    catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        $log.Text = "ERROR: $($e.Message)"
        $failed = $true
    }
    finally {
        $script:job.PS.Dispose(); $script:job = $null
        Set-Busy $false ''
        Update-Status
        if ($failed) { $dot.ForeColor = $C.Err }
    }
})

$btnLock.Add_Click({ Start-Core @{ On = $true; Keep = $regions[$script:selected] } "Locking to $($script:selected)..." })
$btnUnlock.Add_Click({ Start-Core @{ Off = $true } 'Unlocking...' })

Set-Selected 'Singapore'
Update-Status
$form.Add_Shown({ $form.ActiveControl = $title })

if ($Screenshot) {
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
