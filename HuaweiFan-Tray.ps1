#Requires -Version 5.1

<#
    HuaweiFan-Tray.ps1 - tray icon with the two fan gears.

    Right-click (or left-click) the icon:
        最高转速      manual mode, requests the firmware ceiling
        恢复自动控制  hands the fan back to the BIOS/EC
        退出          optionally restores automatic control first

    The icon turns red in manual mode and green under firmware control; the
    tooltip shows the current tachometer reading and chassis temperature.

    Transport: root\wmi:OemWMIMethod @ ACPI\PNP0C14\HWMI_0, method OemWMIfun.
    Needs an elevated session because the EC write path requires it.

    For headless use the same script accepts -Action Max|Auto|Status.
#>

[CmdletBinding()]
param(
    [ValidateSet('Tray', 'Max', 'Auto', 'Status')]
    [string] $Action = 'Tray',

    # Speed requested in manual mode. Values above ~5300 all reach the same
    # physical ceiling on this machine (measured 5280 RPM).
    [ValidateRange(1000, 25500)]
    [int] $MaxRpm = 12000
)

$ErrorActionPreference = 'Stop'

$current = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated session.'
}

# --- firmware transport ------------------------------------------------------

$oemWmi = Get-CimInstance -Namespace 'root\wmi' -ClassName OemWMIMethod |
    Where-Object { $_.InstanceName -eq 'ACPI\PNP0C14\HWMI_0' } |
    Select-Object -First 1
if (-not $oemWmi) {
    throw 'Huawei OemWMIMethod instance ACPI\PNP0C14\HWMI_0 was not found.'
}

function Invoke-Oem {
    param([Parameter(Mandatory)][byte[]] $Command)

    $buffer = [byte[]]::new(64)
    [Array]::Copy($Command, $buffer, $Command.Count)
    $result = Invoke-CimMethod -InputObject $oemWmi -MethodName OemWMIfun -Arguments @{ u8Input = $buffer }
    if (-not $result.u8Output) {
        throw 'Huawei BIOS WMI method returned no output.'
    }
    [byte[]] $result.u8Output
}

function Get-TachRpm {
    $out = Invoke-Oem -Command ([byte[]] @(0x02, 0x08, 0x00, 0x00))
    if ($out[0] -ne 0) { return $null }
    [int] $out[1] -bor ([int] $out[2] -shl 8)
}

function Get-TemperatureC {
    param([int] $Sensor = 0)
    $out = Invoke-Oem -Command ([byte[]] @(0x02, 0x02, $Sensor))
    if ($out[0] -ne 0) { return $null }
    [math]::Round([double] $out[2] + ([double] $out[3] / 10), 1)
}

function Send-FanCommand {
    param([byte[]] $Command, [string] $Description)

    $out = Invoke-Oem -Command $Command
    if ($out[0] -ne 0) {
        throw ('{0} failed with EC status 0x{1:X2}.' -f $Description, $out[0])
    }
}

$script:mode = 'Auto'

function Set-MaxMode {
    $low = [byte] ($MaxRpm -band 0xFF)
    $high = [byte] (($MaxRpm -shr 8) -band 0xFF)
    Send-FanCommand -Command ([byte[]] @(0x02, 0x11, 0x00, 0x01, 0x00, 0x00)) -Description 'Entering fan test mode'
    Send-FanCommand -Command ([byte[]] @(0x02, 0x11, 0x00, 0x01, $low, $high)) -Description "Setting $MaxRpm RPM"
    $script:mode = 'Max'
}

function Set-AutoMode {
    Send-FanCommand -Command ([byte[]] @(0x02, 0x11, 0x00, 0x00, 0x00, 0x00)) -Description 'Restoring vendor control'
    $script:mode = 'Auto'
}

# --- headless mode -----------------------------------------------------------

if ($Action -ne 'Tray') {
    switch ($Action) {
        'Max' { Set-MaxMode }
        'Auto' { Set-AutoMode }
        'Status' { }
    }
    "Mode {0} | {1} RPM | {2} C" -f $script:mode, (Get-TachRpm), (Get-TemperatureC)
    return
}

# --- tray icon ---------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$mutex = New-Object System.Threading.Mutex($false, 'Local\HuaweiFanTray')
if (-not $mutex.WaitOne(0)) {
    [void] [System.Windows.Forms.MessageBox]::Show('风扇托盘已经在运行了。', 'Huawei 风扇')
    return
}

[System.Windows.Forms.Application]::EnableVisualStyles()

# Bitmaps stay referenced so the icon handles remain valid for the process life.
$script:keepAlive = @()

function New-FanIcon {
    param([System.Drawing.Color] $Color)

    $bitmap = New-Object System.Drawing.Bitmap 32, 32
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $brush = New-Object System.Drawing.SolidBrush $Color
    $graphics.FillEllipse($brush, 1, 1, 30, 30)
    $brush.Dispose()

    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 2.4
    foreach ($blade in 0, 120, 240) {
        $angle = $blade * [math]::PI / 180
        $x1 = [single] (16 + 4 * [math]::Cos($angle))
        $y1 = [single] (16 + 4 * [math]::Sin($angle))
        $x2 = [single] (16 + 12 * [math]::Cos($angle))
        $y2 = [single] (16 + 12 * [math]::Sin($angle))
        $graphics.DrawLine($pen, $x1, $y1, $x2, $y2)
    }
    $pen.Dispose()
    $graphics.FillEllipse([System.Drawing.Brushes]::White, 13, 13, 6, 6)
    $graphics.Dispose()

    $script:keepAlive += $bitmap
    [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
}

$iconMax = New-FanIcon -Color ([System.Drawing.Color]::FromArgb(0xD9, 0x35, 0x3D))
$iconAuto = New-FanIcon -Color ([System.Drawing.Color]::FromArgb(0x2E, 0x9E, 0x6B))

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$statusItem = New-Object System.Windows.Forms.ToolStripMenuItem '状态：读取中…'
$statusItem.Enabled = $false
$maxItem = New-Object System.Windows.Forms.ToolStripMenuItem '最高转速'
$autoItem = New-Object System.Windows.Forms.ToolStripMenuItem '恢复自动控制'
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem '退出'

[void] $menu.Items.Add($statusItem)
[void] $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void] $menu.Items.Add($maxItem)
[void] $menu.Items.Add($autoItem)
[void] $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void] $menu.Items.Add($exitItem)

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = $iconAuto
$notify.Text = 'Huawei 风扇'
$notify.ContextMenuStrip = $menu
$notify.Visible = $true

function Update-Tray {
    try {
        $rpm = Get-TachRpm
        $temp = Get-TemperatureC
        $label = if ($script:mode -eq 'Max') { '最高转速' } else { '自动控制' }

        $notify.Text = 'Huawei 风扇 · {0} · {1} RPM · {2} ℃' -f $label, $rpm, $temp
        $statusItem.Text = '状态：{0}　{1} RPM　{2} ℃' -f $label, $rpm, $temp
        $maxItem.Checked = ($script:mode -eq 'Max')
        $autoItem.Checked = ($script:mode -eq 'Auto')
        $notify.Icon = if ($script:mode -eq 'Max') { $iconMax } else { $iconAuto }
    }
    catch {
        $notify.Text = 'Huawei 风扇 · 读取失败'
        $statusItem.Text = '状态：读取失败'
    }
}

$maxItem.add_Click({
        try {
            Set-MaxMode
            Update-Tray
            $notify.ShowBalloonTip(1500, 'Huawei 风扇', '已切到最高转速', [System.Windows.Forms.ToolTipIcon]::None)
        }
        catch {
            [void] [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '切换失败',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })

$autoItem.add_Click({
        try {
            Set-AutoMode
            Update-Tray
            $notify.ShowBalloonTip(1500, 'Huawei 风扇', '已恢复固件自动控制', [System.Windows.Forms.ToolTipIcon]::None)
        }
        catch {
            [void] [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '恢复失败',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })

$exitItem.add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show(
            '退出前是否恢复固件自动控制？',
            'Huawei 风扇',
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            try { Set-AutoMode } catch { }
        }
        $notify.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })

$menu.add_Opening({ Update-Tray })
$notify.add_MouseClick({
        param($sender, $eventArgs)
        if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $menu.Show([System.Windows.Forms.Cursor]::Position)
        }
    })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.add_Tick({ Update-Tray })
$timer.Start()

Update-Tray
[System.Windows.Forms.Application]::Run()

$timer.Stop()
$notify.Visible = $false
$notify.Dispose()
$mutex.ReleaseMutex()
