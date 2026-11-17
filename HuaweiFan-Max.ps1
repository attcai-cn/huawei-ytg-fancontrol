#Requires -Version 5.1

<#
    HuaweiFan-Max.ps1 - put the fan into manual test mode at full speed.

    This is the "high" gear. To go back to firmware control run
    Fan-Auto.cmd (or HuaweiFan-Tray.ps1 -Action Auto), the "auto" gear.

    Transport: root\wmi:OemWMIMethod @ ACPI\PNP0C14\HWMI_0, method OemWMIfun.

      02 11 <fan> 01 <rpm lo> <rpm hi>   manual mode + target speed
                                        firmware divides the 16-bit value by 100
                                        before writing RPM/100 to the EC

    Measured on HUAWEI YTG-XXX (single fan, i7-1360P): requests of 7400 RPM and
    above all saturate at about 5280 RPM, so the default target of 12000 is a
    safe "as fast as it physically goes" request. The setting persists until
    mode 0 is sent or the machine reboots.
#>

[CmdletBinding()]
param(
    # Target RPM. Values at or above ~5300 all reach the same physical ceiling.
    [ValidateRange(1000, 25500)]
    [int] $Rpm = 12000,

    # Seconds to watch the tachometer so the result is visible.
    [ValidateRange(0, 60)]
    [int] $SettleSeconds = 15
)

$ErrorActionPreference = 'Stop'

$current = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated (Administrator) PowerShell session.'
}

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
    param([int] $Sensor)
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

$low = [byte] ($Rpm -band 0xFF)
$high = [byte] (($Rpm -shr 8) -band 0xFF)

$before = Get-TachRpm
"Fan before : {0} RPM   (S0 {1} C)" -f $before, (Get-TemperatureC -Sensor 0)

# Enter manual mode first, then apply the target: the sequence the firmware expects.
Send-FanCommand -Command ([byte[]] @(0x02, 0x11, 0x00, 0x01, 0x00, 0x00)) -Description 'Entering fan test mode'
Send-FanCommand -Command ([byte[]] @(0x02, 0x11, 0x00, 0x01, $low, $high)) -Description "Setting $Rpm RPM"
"Fan manual : requested {0} RPM" -f $Rpm

if ($SettleSeconds -gt 0) {
    $deadline = (Get-Date).AddSeconds($SettleSeconds)
    do {
        Start-Sleep -Seconds 5
        "  {0:HH:mm:ss}  {1,5} RPM   S0 {2,5} C" -f (Get-Date), (Get-TachRpm), (Get-TemperatureC -Sensor 0)
    } while ((Get-Date) -lt $deadline)
}

"Fan now    : {0} RPM" -f (Get-TachRpm)
'Run Fan-Auto.cmd to hand the fan back to the firmware.'
