#requires -version 5.1
<#
.SYNOPSIS
    RTL8125D Low-Latency Tuner

.DESCRIPTION
    A small Windows Forms GUI for applying and verifying a low-latency profile
    for the Realtek RTL8125D (PCI VEN_10EC / DEV_8125 / REV_0C).

    The profile includes both standard adapter properties and several hidden /
    internal Realtek registry parameters that were found in the Realtek
    NetAdapterCx driver package and tested on RTL8125D hardware.

.NOTES
    - Administrator rights are required.
    - A registry backup is created automatically before applying the profile.
    - Applying the profile briefly restarts the network adapter.
    - PCIe ASPM is disabled globally for the ACTIVE Windows power plan.
    - Hidden/internal driver parameters may behave differently with other
      driver versions. Test your own system.
#>

param()

$ErrorActionPreference = "Stop"
$script:LogFile = Join-Path $env:TEMP "RTL8125D-LowLatency-Tuner.log"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

function Write-TunerLog {
    param([string]$Message)

    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue

    if ($script:LogBox -and -not $script:LogBox.IsDisposed) {
        $script:LogBox.AppendText($line + [Environment]::NewLine)
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
    }
}

# -----------------------------------------------------------------------------
# Administrator elevation
# -----------------------------------------------------------------------------

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    # File-based launch: self-elevate.
    if ($PSCommandPath) {
        $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $PSCommandPath

        try {
            Start-Process -FilePath $exe -Verb RunAs -ArgumentList $arg | Out-Null
        }
        catch {
            Write-TunerLog ("Administrator elevation failed: " + $_.Exception.Message)
        }
        exit
    }

    # irm | iex launch: there is no physical script path to elevate.
    Write-Host ""
    Write-Host "RTL8125D Low-Latency Tuner requires an elevated PowerShell window." -ForegroundColor Yellow
    Write-Host "Open PowerShell as Administrator and run the command again." -ForegroundColor Yellow
    Write-Host ""
    return
}

# -----------------------------------------------------------------------------
# Windows Forms
# -----------------------------------------------------------------------------

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
}
catch {
    Write-TunerLog ("Windows Forms could not be loaded: " + $_.Exception.Message)
    throw
}

# -----------------------------------------------------------------------------
# Adapter discovery / compatibility
# -----------------------------------------------------------------------------

function Get-RealtekContext {
    # Find a PCI Realtek RTL8125 device by hardware ID, not by localized adapter name.
    $pnpCandidates = Get-PnpDevice -Class Net -ErrorAction Stop | Where-Object {
        $_.InstanceId -like "PCI\VEN_10EC&DEV_8125*"
    }

    if (-not $pnpCandidates) {
        throw "No Realtek RTL8125-family PCIe network adapter was found."
    }

    $pnp = $pnpCandidates | Select-Object -First 1

    $hardwareIds = @(
        (Get-PnpDeviceProperty `
            -InstanceId $pnp.InstanceId `
            -KeyName "DEVPKEY_Device_HardwareIds" `
            -ErrorAction Stop).Data
    )

    $supported = $false
    foreach ($id in $hardwareIds) {
        if ($id -match 'PCI\\VEN_10EC&DEV_8125&.*REV_0C') {
            $supported = $true
            break
        }
    }

    # Match the Windows network adapter to the PnP device.
    $adapter = Get-NetAdapter -IncludeHidden -ErrorAction Stop |
        Where-Object { $_.InterfaceDescription -eq $pnp.FriendlyName } |
        Select-Object -First 1

    if (-not $adapter) {
        # Fallback for drivers that expose a slightly different PnP friendly name.
        $adapter = Get-NetAdapter -IncludeHidden -ErrorAction Stop |
            Where-Object { $_.InterfaceDescription -like "*Realtek*2.5GbE*" } |
            Select-Object -First 1
    }

    if (-not $adapter) {
        throw "The RTL8125 device was found, but its Windows network-adapter interface could not be resolved."
    }

    $driverKey = (Get-PnpDeviceProperty `
        -InstanceId $pnp.InstanceId `
        -KeyName "DEVPKEY_Device_Driver" `
        -ErrorAction Stop).Data

    $driverVersion = $null
    try {
        $driverVersion = (Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
            Where-Object { $_.DeviceID -eq $pnp.InstanceId } |
            Select-Object -First 1).DriverVersion
    }
    catch {
        $driverVersion = "Unknown"
    }

    [PSCustomObject]@{
        Adapter       = $adapter
        Pnp           = $pnp
        HardwareIds   = $hardwareIds
        Supported     = $supported
        DriverVersion = $driverVersion
        DriverPath    = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$driverKey"
        WdfPath       = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($pnp.InstanceId)\Device Parameters\WDF"
    }
}

# -----------------------------------------------------------------------------
# Read helpers
# -----------------------------------------------------------------------------

function Get-RegistryValueText {
    param(
        [string]$Path,
        [string]$Name
    )

    try {
        $obj = Get-ItemProperty -Path $Path -ErrorAction Stop
        $prop = $obj.PSObject.Properties[$Name]

        if ($null -eq $prop) {
            return "<missing>"
        }

        return [string]$prop.Value
    }
    catch {
        return "<missing>"
    }
}

function Get-AdvancedValueText {
    param(
        [string]$AdapterName,
        [string]$Keyword
    )

    try {
        $p = Get-NetAdapterAdvancedProperty `
            -Name $AdapterName `
            -RegistryKeyword $Keyword `
            -ErrorAction Stop

        if ($null -eq $p) {
            return "<missing>"
        }

        if ($p.RegistryValue -is [System.Array]) {
            return ($p.RegistryValue -join ",")
        }

        return [string]$p.RegistryValue
    }
    catch {
        return "<missing>"
    }
}

function Get-AspmText {
    try {
        $values = New-Object System.Collections.Generic.List[int]
        $output = powercfg /query SCHEME_CURRENT SUB_PCIEXPRESS ASPM 2>$null

        foreach ($line in $output) {
            $match = [regex]::Match([string]$line, "0x([0-9A-Fa-f]{8})")

            if ($match.Success) {
                $values.Add([Convert]::ToInt32($match.Groups[1].Value, 16))
            }
        }

        if ($values.Count -ge 2) {
            return ("{0}/{1}" -f $values[$values.Count - 2], $values[$values.Count - 1])
        }

        return "?"
    }
    catch {
        return "?"
    }
}

# -----------------------------------------------------------------------------
# Status grid
# -----------------------------------------------------------------------------

function Add-StatusRow {
    param(
        [string]$Setting,
        [string]$Current,
        [string]$Target,
        [Nullable[bool]]$ForceState = $null
    )

    if ($null -ne $ForceState) {
        $ok = [bool]$ForceState
    }
    else {
        $ok = ([string]$Current -eq [string]$Target)
    }

    $state = if ($ok) { "OK" } else { "Mismatch" }

    $index = $script:Grid.Rows.Add($Setting, $Current, $Target, $state)
    $row = $script:Grid.Rows[$index]

    if ($ok) {
        $row.Cells[3].Style.ForeColor = [System.Drawing.Color]::FromArgb(90, 205, 125)
    }
    else {
        $row.Cells[3].Style.ForeColor = [System.Drawing.Color]::FromArgb(235, 175, 70)
    }
}

# -----------------------------------------------------------------------------
# Backup / adapter restart
# -----------------------------------------------------------------------------

function Backup-RealtekRegistry {
    param($Context)

    $dir = Join-Path $env:USERPROFILE "Documents\RTL8125D-Tuner\Backups"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $file = Join-Path $dir ("Realtek_{0}.reg" -f (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
    $regPath = $Context.DriverPath -replace "^HKLM:\\", "HKLM\"

    & reg.exe export "$regPath" "$file" /y | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "The Realtek registry key could not be backed up."
    }

    Write-TunerLog "Registry backup created: $file"
    return $file
}

function Restart-RealtekAdapter {
    param($Context)

    Write-TunerLog "Restarting network adapter..."

    Disable-NetAdapter `
        -Name $Context.Adapter.Name `
        -Confirm:$false `
        -ErrorAction Stop

    Start-Sleep -Seconds 2

    Enable-NetAdapter `
        -Name $Context.Adapter.Name `
        -Confirm:$false `
        -ErrorAction Stop

    Start-Sleep -Seconds 5

    Write-TunerLog "Network adapter is back online."
}

# -----------------------------------------------------------------------------
# Status refresh
# -----------------------------------------------------------------------------

function Refresh-TunerStatus {
    try {
        $script:Grid.Rows.Clear()
        $ctx = Get-RealtekContext

        $script:AdapterLabel.Text = "{0}  |  {1}" -f $ctx.Adapter.Name, $ctx.Adapter.InterfaceDescription
        $script:LinkLabel.Text = "Status: {0}    Link: {1}" -f $ctx.Adapter.Status, $ctx.Adapter.LinkSpeed

        $primaryHardwareId = ($ctx.HardwareIds | Select-Object -First 1)
        $script:HardwareLabel.Text = "Hardware: {0}    Driver: {1}" -f $primaryHardwareId, $ctx.DriverVersion

        if ($ctx.Supported) {
            $script:CompatibilityLabel.Text = "Compatible RTL8125D / REV_0C detected"
            $script:CompatibilityLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 205, 125)
            $script:ApplyButton.Enabled = $true
        }
        else {
            $script:CompatibilityLabel.Text = "RTL8125-family adapter detected, but this revision is NOT the tested RTL8125D REV_0C"
            $script:CompatibilityLabel.ForeColor = [System.Drawing.Color]::FromArgb(235, 175, 70)
            $script:ApplyButton.Enabled = $false
        }

        $advancedTargets = @(
            @("*InterruptModeration", "0", "Interrupt Moderation"),
            @("*FlowControl",         "0", "Flow Control"),
            @("*RscIPv4",             "0", "RSC IPv4"),
            @("*RscIPv6",             "0", "RSC IPv6"),
            @("*LsoV2IPv4",           "0", "LSO IPv4"),
            @("*LsoV2IPv6",           "0", "LSO IPv6"),
            @("*PriorityVLANTag",      "0", "Priority / VLAN"),
            @("*EEE",                  "0", "Energy Efficient Ethernet"),
            @("AdvancedEEE",           "0", "Advanced EEE"),
            @("EnableGreenEthernet",   "0", "Green Ethernet"),
            @("GigaLite",              "0", "Gigabit Lite"),
            @("PowerSavingMode",       "0", "Power Saving Mode")
        )

        foreach ($item in $advancedTargets) {
            $current = Get-AdvancedValueText `
                -AdapterName $ctx.Adapter.Name `
                -Keyword $item[0]

            Add-StatusRow `
                -Setting $item[2] `
                -Current $current `
                -Target $item[1]
        }

        $registryTargets = @(
            @("*RSS",                      "1",   "Receive Side Scaling (RSS)"),
            @("*NumRssQueues",             "4",   "RSS Queues (requested)"),
            @("InterruptModerationLevel", "0",   "Moderation Level (Low)"),
            @("TxOptimizeThreshold",      "500", "Tx Optimize Threshold"),
            @("RxOptimizeThreshold",      "500", "Rx Optimize Threshold"),
            @("RxProcMax",                "64",  "Rx Processing Budget"),
            @("TxProcMax",                "64",  "Tx Processing Budget"),
            @("TxDesFetchNum8125",        "4",   "Tx Descriptor Fetch"),
            @("*IdleRestriction",         "1",   "Idle Power-Down Restriction"),
            @("PowerDownPll",             "0",   "PLL Power-Down")
        )

        foreach ($item in $registryTargets) {
            $current = Get-RegistryValueText `
                -Path $ctx.DriverPath `
                -Name $item[0]

            Add-StatusRow `
                -Setting $item[2] `
                -Current $current `
                -Target $item[1]
        }

        if (Test-Path $ctx.WdfPath) {
            Add-StatusRow `
                -Setting "WDF Idle in Working State" `
                -Current (Get-RegistryValueText -Path $ctx.WdfPath -Name "IdleInWorkingState") `
                -Target "0"

            Add-StatusRow `
                -Setting "WDF Directed Power / DFx" `
                -Current (Get-RegistryValueText -Path $ctx.WdfPath -Name "WdfDirectedPowerTransitionEnable") `
                -Target "0"
        }

        Add-StatusRow `
            -Setting "PCIe ASPM AC/DC" `
            -Current (Get-AspmText) `
            -Target "0/0"

        try {
            $rss = Get-NetAdapterRss -Name $ctx.Adapter.Name -ErrorAction Stop

            # 3 queues is the observed effective result on the tested RTL8125D
            # even though 4 is requested through the Realtek keyword.
            Add-StatusRow `
                -Setting "RSS Effective Queues" `
                -Current ([string]$rss.NumberOfReceiveQueues) `
                -Target "3"
        }
        catch {
            Add-StatusRow `
                -Setting "RSS Effective Queues" `
                -Current "?" `
                -Target "3"
        }

        try {
            $stats = Get-NetAdapterStatistics -Name $ctx.Adapter.Name -ErrorAction Stop

            $text = "RXerr={0} RXdrop={1} TXerr={2} TXdrop={3}" -f `
                $stats.ReceivedPacketErrors, `
                $stats.ReceivedDiscardedPackets, `
                $stats.OutboundPacketErrors, `
                $stats.OutboundDiscardedPackets

            $clean = (
                $stats.ReceivedPacketErrors -eq 0 -and
                $stats.ReceivedDiscardedPackets -eq 0 -and
                $stats.OutboundPacketErrors -eq 0 -and
                $stats.OutboundDiscardedPackets -eq 0
            )

            Add-StatusRow `
                -Setting "Errors / Discards" `
                -Current $text `
                -Target "all 0" `
                -ForceState $clean
        }
        catch {
            Add-StatusRow `
                -Setting "Errors / Discards" `
                -Current "?" `
                -Target "all 0"
        }

        $bad = 0

        foreach ($row in $script:Grid.Rows) {
            if ($row.Cells[3].Value -eq "Mismatch") {
                $bad++
            }
        }

        if ($bad -eq 0) {
            $script:StateLabel.Text = "Tested low-latency profile is fully active"
            $script:StateLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 205, 125)
        }
        else {
            $script:StateLabel.Text = "$bad profile mismatch(es) detected"
            $script:StateLabel.ForeColor = [System.Drawing.Color]::FromArgb(235, 175, 70)
        }

        Write-TunerLog "Status refreshed."
    }
    catch {
        $script:StateLabel.Text = "Error / adapter not found"
        $script:StateLabel.ForeColor = [System.Drawing.Color]::FromArgb(225, 90, 90)
        $script:CompatibilityLabel.Text = $_.Exception.Message
        $script:CompatibilityLabel.ForeColor = [System.Drawing.Color]::FromArgb(225, 90, 90)
        $script:ApplyButton.Enabled = $false

        Write-TunerLog ("Status error: " + $_.Exception.Message)
    }
}

# -----------------------------------------------------------------------------
# Apply profile
# -----------------------------------------------------------------------------

function Apply-LowLatencyProfile {
    try {
        $ctx = Get-RealtekContext

        if (-not $ctx.Supported) {
            [System.Windows.Forms.MessageBox]::Show(
                "This profile is currently locked to the tested RTL8125D hardware revision:`n`nPCI VEN_10EC / DEV_8125 / REV_0C`n`nYour detected adapter is not REV_0C. No changes were made.",
                "Unsupported RTL8125 Revision",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Apply the tested RTL8125D low-latency profile?`n`n" +
            "- A registry backup will be created automatically.`n" +
            "- The network adapter will restart briefly.`n" +
            "- PCIe ASPM will be disabled globally for the ACTIVE Windows power plan.`n" +
            "- Hidden/internal Realtek driver parameters will be changed.`n`n" +
            "Continue?",
            "Apply Low-Latency Profile",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-TunerLog "Profile application cancelled by user."
            return
        }

        $script:ApplyButton.Enabled = $false
        $script:RefreshButton.Enabled = $false
        $script:RestartButton.Enabled = $false

        $script:StateLabel.Text = "Applying profile..."
        $script:StateLabel.ForeColor = [System.Drawing.Color]::FromArgb(235, 175, 70)
        [System.Windows.Forms.Application]::DoEvents()

        [void](Backup-RealtekRegistry -Context $ctx)

        # Standard Realtek / NDIS / NetAdapterCx properties.
        # -NoRestart prevents a separate adapter reset for each property.
        $advanced = [ordered]@{
            "*InterruptModeration" = "0"
            "*FlowControl"         = "0"
            "*RscIPv4"             = "0"
            "*RscIPv6"             = "0"
            "*LsoV2IPv4"           = "0"
            "*LsoV2IPv6"           = "0"
            "*PriorityVLANTag"     = "0"
            "*EEE"                 = "0"
            "AdvancedEEE"          = "0"
            "EnableGreenEthernet"  = "0"
            "GigaLite"             = "0"
            "PowerSavingMode"      = "0"
        }

        foreach ($entry in $advanced.GetEnumerator()) {
            try {
                Set-NetAdapterAdvancedProperty `
                    -Name $ctx.Adapter.Name `
                    -RegistryKeyword $entry.Key `
                    -RegistryValue $entry.Value `
                    -NoRestart `
                    -ErrorAction Stop

                Write-TunerLog ("{0} = {1}" -f $entry.Key, $entry.Value)
            }
            catch {
                # Different driver packages may omit some exposed properties.
                Write-TunerLog ("WARNING {0}: {1}" -f $entry.Key, $_.Exception.Message)
            }
        }

        # Hidden/internal Realtek values.
        $hidden = @(
            @("*RSS",                      "String", "1"),
            @("*NumRssQueues",             "String", "4"),
            @("InterruptModerationLevel", "String", "0"),
            @("TxOptimizeThreshold",      "DWord",  500),
            @("RxOptimizeThreshold",      "DWord",  500),
            @("RxProcMax",                "DWord",  64),
            @("TxProcMax",                "DWord",  64),
            @("TxDesFetchNum8125",        "DWord",  4),
            @("*IdleRestriction",         "String", "1"),
            @("PowerDownPll",             "DWord",  0)
        )

        foreach ($entry in $hidden) {
            New-ItemProperty `
                -Path $ctx.DriverPath `
                -Name $entry[0] `
                -PropertyType $entry[1] `
                -Value $entry[2] `
                -Force | Out-Null

            Write-TunerLog ("{0} = {1}" -f $entry[0], $entry[2])
        }

        # WDF / Directed Power Framework.
        if (Test-Path $ctx.WdfPath) {
            New-ItemProperty `
                -Path $ctx.WdfPath `
                -Name "IdleInWorkingState" `
                -PropertyType DWord `
                -Value 0 `
                -Force | Out-Null

            New-ItemProperty `
                -Path $ctx.WdfPath `
                -Name "WdfDirectedPowerTransitionEnable" `
                -PropertyType DWord `
                -Value 0 `
                -Force | Out-Null

            Write-TunerLog "WDF IdleInWorkingState = 0"
            Write-TunerLog "WDF Directed Power / DFx = 0"
        }

        # Windows power-plan PCIe Link State Power Management.
        powercfg /setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0 | Out-Null
        powercfg /setdcvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0 | Out-Null
        powercfg /setactive SCHEME_CURRENT | Out-Null

        Write-TunerLog "PCIe ASPM AC/DC = 0/0"

        # One adapter restart at the end.
        Restart-RealtekAdapter -Context $ctx

        Write-TunerLog "Low-latency profile applied successfully."
        Refresh-TunerStatus
    }
    catch {
        Write-TunerLog ("Profile error: " + $_.Exception.Message)

        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "RTL8125D Tuner - Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        try {
            $ctx = Get-RealtekContext
            $script:ApplyButton.Enabled = $ctx.Supported
        }
        catch {
            $script:ApplyButton.Enabled = $false
        }

        $script:RefreshButton.Enabled = $true
        $script:RestartButton.Enabled = $true
    }
}

# -----------------------------------------------------------------------------
# GUI
# -----------------------------------------------------------------------------

try {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "RTL8125D Low-Latency Tuner"
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object System.Drawing.Size(1080, 800)
    $form.MinimumSize = New-Object System.Drawing.Size(900, 680)
    $form.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 31)
    $form.ForeColor = [System.Drawing.Color]::Gainsboro
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    # Header
    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = [System.Windows.Forms.DockStyle]::Top
    $header.Height = 140
    $header.BackColor = [System.Drawing.Color]::FromArgb(31, 34, 40)
    $form.Controls.Add($header)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "RTL8125D Low-Latency"
    $title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 18)
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(18, 12)
    $header.Controls.Add($title)

    $script:StateLabel = New-Object System.Windows.Forms.Label
    $script:StateLabel.Text = "Loading status..."
    $script:StateLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
    $script:StateLabel.AutoSize = $true
    $script:StateLabel.Location = New-Object System.Drawing.Point(20, 48)
    $header.Controls.Add($script:StateLabel)

    $script:CompatibilityLabel = New-Object System.Windows.Forms.Label
    $script:CompatibilityLabel.Text = "Detecting hardware..."
    $script:CompatibilityLabel.AutoSize = $true
    $script:CompatibilityLabel.Location = New-Object System.Drawing.Point(20, 70)
    $header.Controls.Add($script:CompatibilityLabel)

    $script:AdapterLabel = New-Object System.Windows.Forms.Label
    $script:AdapterLabel.Text = "Adapter: ..."
    $script:AdapterLabel.AutoSize = $true
    $script:AdapterLabel.ForeColor = [System.Drawing.Color]::Silver
    $script:AdapterLabel.Location = New-Object System.Drawing.Point(20, 92)
    $header.Controls.Add($script:AdapterLabel)

    $script:HardwareLabel = New-Object System.Windows.Forms.Label
    $script:HardwareLabel.Text = "Hardware: ..."
    $script:HardwareLabel.AutoSize = $true
    $script:HardwareLabel.ForeColor = [System.Drawing.Color]::Silver
    $script:HardwareLabel.Location = New-Object System.Drawing.Point(20, 114)
    $header.Controls.Add($script:HardwareLabel)

    $script:LinkLabel = New-Object System.Windows.Forms.Label
    $script:LinkLabel.Text = ""
    $script:LinkLabel.AutoSize = $true
    $script:LinkLabel.ForeColor = [System.Drawing.Color]::Silver
    $script:LinkLabel.Location = New-Object System.Drawing.Point(790, 92)
    $header.Controls.Add($script:LinkLabel)

    # Buttons
    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $buttonPanel.Height = 60
    $buttonPanel.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 8)
    $buttonPanel.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 31)
    $form.Controls.Add($buttonPanel)

    function New-TunerButton {
        param(
            [string]$Text,
            [int]$Width
        )

        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Text
        $button.Width = $Width
        $button.Height = 36
        $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 86, 96)
        $button.BackColor = [System.Drawing.Color]::FromArgb(43, 47, 55)
        $button.ForeColor = [System.Drawing.Color]::White
        $button.Cursor = [System.Windows.Forms.Cursors]::Hand

        return $button
    }

    $script:ApplyButton = New-TunerButton -Text "Apply Profile" -Width 155
    $script:RefreshButton = New-TunerButton -Text "Refresh Status" -Width 155
    $script:RestartButton = New-TunerButton -Text "Restart Adapter" -Width 155
    $speedButton = New-TunerButton -Text "Cloudflare Speed Test" -Width 175
    $backupButton = New-TunerButton -Text "Create Registry Backup" -Width 180

    [void]$buttonPanel.Controls.Add($script:ApplyButton)
    [void]$buttonPanel.Controls.Add($script:RefreshButton)
    [void]$buttonPanel.Controls.Add($script:RestartButton)
    [void]$buttonPanel.Controls.Add($speedButton)
    [void]$buttonPanel.Controls.Add($backupButton)

    # Tabs
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
    $form.Controls.Add($tabs)

    $tabs.BringToFront()
    $buttonPanel.BringToFront()
    $header.BringToFront()

    $statusTab = New-Object System.Windows.Forms.TabPage
    $statusTab.Text = "Status"
    $statusTab.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 31)
    [void]$tabs.TabPages.Add($statusTab)

    $logTab = New-Object System.Windows.Forms.TabPage
    $logTab.Text = "Log"
    $logTab.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 31)
    [void]$tabs.TabPages.Add($logTab)

    # Status grid
    $script:Grid = New-Object System.Windows.Forms.DataGridView
    $script:Grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:Grid.ReadOnly = $true
    $script:Grid.AllowUserToAddRows = $false
    $script:Grid.AllowUserToDeleteRows = $false
    $script:Grid.AllowUserToResizeRows = $false
    $script:Grid.RowHeadersVisible = $false
    $script:Grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    $script:Grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $script:Grid.MultiSelect = $false
    $script:Grid.BackgroundColor = [System.Drawing.Color]::FromArgb(24, 26, 31)
    $script:Grid.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $script:Grid.GridColor = [System.Drawing.Color]::FromArgb(55, 59, 68)
    $script:Grid.EnableHeadersVisualStyles = $false
    $script:Grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(38, 42, 49)
    $script:Grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $script:Grid.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(28, 31, 36)
    $script:Grid.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gainsboro
    $script:Grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(53, 67, 82)
    $script:Grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $script:Grid.RowTemplate.Height = 27

    [void]$script:Grid.Columns.Add("Setting", "Setting")
    [void]$script:Grid.Columns.Add("Current", "Current")
    [void]$script:Grid.Columns.Add("Target", "Target")
    [void]$script:Grid.Columns.Add("State", "Status")

    $script:Grid.Columns[0].FillWeight = 38
    $script:Grid.Columns[1].FillWeight = 27
    $script:Grid.Columns[2].FillWeight = 18
    $script:Grid.Columns[3].FillWeight = 17

    $statusTab.Controls.Add($script:Grid)

    # Log
    $script:LogBox = New-Object System.Windows.Forms.TextBox
    $script:LogBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:LogBox.Multiline = $true
    $script:LogBox.ReadOnly = $true
    $script:LogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:LogBox.BackColor = [System.Drawing.Color]::FromArgb(20, 22, 26)
    $script:LogBox.ForeColor = [System.Drawing.Color]::Gainsboro
    $script:LogBox.Font = New-Object System.Drawing.Font("Consolas", 9.5)

    $logTab.Controls.Add($script:LogBox)

    # Events
    $script:ApplyButton.Add_Click({
        Apply-LowLatencyProfile
    })

    $script:RefreshButton.Add_Click({
        Refresh-TunerStatus
    })

    $script:RestartButton.Add_Click({
        try {
            $ctx = Get-RealtekContext
            Restart-RealtekAdapter -Context $ctx
            Refresh-TunerStatus
        }
        catch {
            Write-TunerLog ("Adapter restart failed: " + $_.Exception.Message)
        }
    })

    $speedButton.Add_Click({
        Start-Process "https://speed.cloudflare.com"
    })

    $backupButton.Add_Click({
        try {
            $file = Backup-RealtekRegistry -Context (Get-RealtekContext)

            [System.Windows.Forms.MessageBox]::Show(
                "Backup saved to:`n$file",
                "Registry Backup",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
        catch {
            Write-TunerLog ("Backup failed: " + $_.Exception.Message)
        }
    })

    $form.Add_Shown({
        Write-TunerLog "RTL8125D Low-Latency Tuner started."
        Refresh-TunerStatus
    })

    [void]$form.ShowDialog()
}
catch {
    Write-TunerLog ("GUI error: " + $_.Exception.ToString())

    try {
        [System.Windows.Forms.MessageBox]::Show(
            "The tuner could not be started.`n`n$($_.Exception.Message)`n`nLog file:`n$script:LogFile",
            "RTL8125D Tuner - Startup Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    catch {
        Write-Host $_.Exception.ToString()
    }

    exit 1
}
