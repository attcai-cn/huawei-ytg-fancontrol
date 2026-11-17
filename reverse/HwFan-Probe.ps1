#Requires -Version 5.1

<#
    HwFan-Probe.ps1 - Reverse-engineering probe for Huawei YTG (QingYun) fan control.

    Transport: root\wmi:OemWMIMethod, instance ACPI\PNP0C14\HWMI_0, method OemWMIfun.
    64-byte input buffer -> BIOS WMAA -> EC through \_SB.PC00.LPCB.HWEC.ECCD.

    Verified layout on HUAWEI YTG-XXX / PCB M1010 / BIOS 1.08 (ACPI HUAWEI RPL-P):

      02 02 <sensor>                      read temperature (GTMP, EC 02 61)
                                          out[0]=status out[1]=sign out[2]=C out[3]=tenths
      02 08 <fan lo> <fan hi>             read tachometer (GFNS, EC 02 7C)
                                          out[0]=status out[1]=RPM lo out[2]=RPM hi
      02 11 <fan> 00 00 00                exit fan test mode (SFND, EC 04 01 00)
      02 11 <fan> 01 <rpm lo> <rpm hi>    enter test mode + set speed (SFND, EC 04 02)
                                          firmware divides the 16-bit value by 100,
                                          so the EC sees RPM/100 (100 RPM granularity)

    Only reads are performed unless -Apply is passed.

    Measured on this machine (2026-11-15):
      - one physical fan; Fan 1 tachometer always returns 0xFFFF (absent)
      - tachometer follows the request 1:1 up to about 5280 RPM, then saturates
      - the fan has inertia: allow 10-20 s before judging a new target
      - EC sensors are chassis/board level; sensor 0 reacts fastest to cooling
#>

[CmdletBinding()]
param(
    [ValidateSet('Status', 'Monitor', 'SetRpm', 'Calibrate')]
    [string] $Action = 'Status',

    # Target RPM for -Action SetRpm. Firmware granularity is 100 RPM.
    [ValidateRange(0, 25500)]
    [int] $Rpm = 3800,

    # How long to hold the manual target before restoring vendor control.
    [ValidateRange(1, 120)]
    [int] $HoldSeconds = 15,

    [ValidateRange(1, 10)]
    [int] $SampleSeconds = 2,

    # Required before any write command is issued.
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'

$wrapperInstance = 'ACPI\PNP0C14\HWMI_0'

function Get-OemWmiInstance {
    $instance = Get-CimInstance -Namespace 'root\wmi' -ClassName OemWMIMethod |
        Where-Object { $_.InstanceName -eq $wrapperInstance } |
        Select-Object -First 1
    if (-not $instance) {
        throw "Huawei OemWMIMethod instance $wrapperInstance was not found."
    }
    $instance
}

$script:OemWmi = Get-OemWmiInstance

function Invoke-HuaweiOem {
    param([Parameter(Mandatory)][byte[]] $Command)

    if ($Command.Count -gt 64) {
        throw 'The Huawei WMI input buffer is limited to 64 bytes.'
    }
    $buffer = [byte[]]::new(64)
    [Array]::Copy($Command, $buffer, $Command.Count)
    $result = Invoke-CimMethod -InputObject $script:OemWmi -MethodName OemWMIfun -Arguments @{ u8Input = $buffer }
    if (-not $result.u8Output) {
        throw 'Huawei BIOS WMI method returned no output.'
    }
    [byte[]] $result.u8Output
}

function Get-HuaweiTemperature {
    param([ValidateRange(0, 15)][int] $Sensor = 5)

    $out = Invoke-HuaweiOem -Command ([byte[]] @(0x02, 0x02, $Sensor))
    if ($out[0] -ne 0) { return $null }
    $value = [double] $out[2] + ([double] $out[3] / 10)
    if ($out[1] -eq 1) { $value = -$value }
    [math]::Round($value, 1)
}

function Get-HuaweiTach {
    param([ValidateRange(0, 3)][int] $Fan = 0)

    $out = Invoke-HuaweiOem -Command ([byte[]] @(0x02, 0x08, $Fan, 0x00))
    if ($out[0] -ne 0) { return $null }
    [int] $out[1] -bor ([int] $out[2] -shl 8)
}

function Set-HuaweiFanMode {
    param([ValidateSet(0, 1)][int] $Mode)
    $out = Invoke-HuaweiOem -Command ([byte[]] @(0x02, 0x11, 0x00, $Mode, 0x00, 0x00))
    if ($out[0] -ne 0) {
        throw ('Fan mode {0} failed with EC status 0x{1:X2}.' -f $Mode, $out[0])
    }
}

function Set-HuaweiFanRpm {
    param(
        [ValidateRange(0, 1)][int] $Fan = 0,
        [ValidateRange(0, 25500)][int] $TargetRpm
    )

    $low = [byte] ($TargetRpm -band 0xFF)
    $high = [byte] (($TargetRpm -shr 8) -band 0xFF)
    # Firmware: ECCM(0x04, 0x02, 0x02, {fan, (high*256+low)/100}).
    $out = Invoke-HuaweiOem -Command ([byte[]] @(0x02, 0x11, $Fan, 0x01, $low, $high))
    if ($out[0] -ne 0) {
        throw ('Setting fan {0} to {1} RPM failed with EC status 0x{2:X2}.' -f $Fan, $TargetRpm, $out[0])
    }
}

function Show-HuaweiSensors {
    $temperatures = foreach ($sensor in 0, 5, 7, 8) {
        $value = Get-HuaweiTemperature -Sensor $sensor
        if ($null -ne $value) { [pscustomobject]@{ Sensor = $sensor; Celsius = $value } }
    }
    $fans = foreach ($fan in 0, 1) {
        [pscustomobject]@{ Fan = $fan; Rpm = Get-HuaweiTach -Fan $fan }
    }
    "Temperatures: " + (($temperatures | ForEach-Object { "S$($_.Sensor)=$($_.Celsius)C" }) -join '  ')
    "Tachometers : " + (($fans | ForEach-Object { if ($_.Rpm -eq 65535) { "Fan$($_.Fan)=absent" } else { "Fan$($_.Fan)=$($_.Rpm)RPM" } }) -join '  ')
}

$isAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

switch ($Action) {
    'Status' {
        Show-HuaweiSensors
    }

    'Monitor' {
        for ($i = 0; $i -lt 5; $i++) {
            "{0:HH:mm:ss}  S5={1,5}C  S7={2,5}C  Fan0={3,5}" -f (Get-Date), (Get-HuaweiTemperature -Sensor 5),
                (Get-HuaweiTemperature -Sensor 7), (Get-HuaweiTach -Fan 0)
            Start-Sleep -Seconds $SampleSeconds
        }
    }

    'SetRpm' {
        if (-not $Apply) { throw 'Write actions require -Apply.' }
        if (-not $isAdministrator) { throw 'Write actions require an Administrator shell.' }

        $manual = $false
        try {
            Show-HuaweiSensors
            "Entering fan test mode; target $Rpm RPM ..."
            Set-HuaweiFanMode -Mode 1
            $manual = $true
            Set-HuaweiFanRpm -Fan 0 -TargetRpm $Rpm

                $deadline = (Get-Date).AddSeconds($HoldSeconds)
            while ((Get-Date) -lt $deadline) {
                $temp = Get-HuaweiTemperature -Sensor 5
                $tach = Get-HuaweiTach -Fan 0
                "{0:HH:mm:ss}  target {1,5}  tach {2,5}  S0 {3,5}C  S5 {4,5}C  S8 {5,5}C" -f (Get-Date), $Rpm, $tach,
                    (Get-HuaweiTemperature -Sensor 0), $temp, (Get-HuaweiTemperature -Sensor 8)
                if ($temp -ge 88) { throw "Emergency temperature reached: $temp C." }
                Start-Sleep -Seconds $SampleSeconds
            }
        }
        finally {
            if ($manual) {
                Set-HuaweiFanMode -Mode 0
                Start-Sleep -Seconds 3
                "Vendor control restored; tach now $(Get-HuaweiTach -Fan 0) RPM at $(Get-HuaweiTemperature -Sensor 5) C."
            }
        }
    }

    'Calibrate' {
        if (-not $Apply) { throw 'Write actions require -Apply.' }
        if (-not $isAdministrator) { throw 'Write actions require an Administrator shell.' }

        $levels = 3200, 5100, 7400, 9300, 12000
        $samples = 5
        $results = @()
        $manual = $false
        try {
            Show-HuaweiSensors
            Set-HuaweiFanMode -Mode 1
            $manual = $true
            foreach ($level in $levels) {
                Set-HuaweiFanRpm -Fan 0 -TargetRpm $level
                $readings = @()
                for ($i = 0; $i -lt $samples; $i++) {
                    Start-Sleep -Seconds $SampleSeconds
                    $readings += Get-HuaweiTach -Fan 0
                }
                $average = [math]::Round((($readings | Measure-Object -Average).Average), 0)
                $results += [pscustomobject]@{
                    Request = $level
                    AverageRPM = $average
                    Samples = ($readings -join '/')
                    TemperatureC = Get-HuaweiTemperature -Sensor 5
                }
            }
        }
        finally {
            if ($manual) {
                Set-HuaweiFanMode -Mode 0
                Start-Sleep -Seconds 3
                "Vendor control restored; tach now $(Get-HuaweiTach -Fan 0) RPM."
            }
        }
        $results | Format-Table -AutoSize
    }
}
