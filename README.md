RTL8125D Low-Latency Tuner
A Windows tuning utility for the Realtek RTL8125D 2.5GbE controller, focused on reducing latency, jitter, packet batching and unnecessary power-state transitions.
> [!IMPORTANT]
> ## Realtek NetAdapterCx driver required
>
> This tool was developed and tested specifically with the **Realtek NetAdapterCx driver**.
>
> Supported/tested driver family:
>
> ```text
> rt25cx21x64
> ```
>
> The classic Realtek NDIS driver:
>
> ```text
> rt640x64
> ```
>
> is **currently not supported or tested** by this project.
>
> Some standard adapter settings may also exist under the classic NDIS driver, but the hidden/internal Realtek parameters used by this profile were derived from and tested with the **NetAdapterCx driver**. Do not assume that those internal parameters behave identically under NDIS.
> [!WARNING]
> The current public profile is also limited to the tested **RTL8125D / REV_0C** hardware revision.
>
> Tested hardware ID family:
>
> ```text
> PCI\VEN_10EC&DEV_8125&...&REV_0C
> ```
---
Tested configuration
Realtek RTL8125D
Hardware revision: `REV_0C`
Realtek NetAdapterCx driver
Driver module family: `rt25cx21x64`
Windows 11
2.5 GbE link
---
How to check whether you are using NetAdapterCx or classic NDIS
Open PowerShell and run:
```powershell
Get-CimInstance Win32_PnPSignedDriver |
Where-Object {
    $_.DeviceClass -eq "NET" -and
    $_.DeviceName -like "*Realtek*"
} |
Format-List DeviceName,InfName,DriverVersion,DriverProviderName
```
You can also inspect the installed Realtek driver package:
```powershell
pnputil /enum-drivers | findstr /i "Realtek rt25cx rt640"
```
Typical driver families:
```text
NetAdapterCx:
rt25cx21x64.inf
rt25cx21x64.sys

Classic NDIS:
rt640x64.inf
rt640x64.sys
```
If your system uses the classic `rt640x64` driver, this profile should currently be treated as unsupported.
---
What the tool changes
Receive / CPU distribution
Receive Side Scaling (RSS): enabled
RSS queues requested: `4`
Effective queues observed on the tested RTL8125D: `3`
Latency / packet batching
Interrupt Moderation: disabled
Hidden Interrupt Moderation Level: `Low` retained in registry
Flow Control: disabled
Receive Segment Coalescing (IPv4/IPv6): disabled
Large Send Offload v2 (IPv4/IPv6): disabled
Priority / VLAN: disabled
Checksum offloads: intentionally left enabled
Hidden / internal Realtek parameters
```text
TxOptimizeThreshold = 500
RxOptimizeThreshold = 500

RxProcMax = 64
TxProcMax = 64

TxDesFetchNum8125 = 4

*IdleRestriction = 1
PowerDownPll = 0
```
These are not ordinary Windows tuning values. Several are hidden/internal Realtek driver parameters.
Power management
Power Saving Mode: disabled
Energy Efficient Ethernet: disabled
Advanced EEE: disabled
Green Ethernet: disabled
Gigabit Lite: disabled
WDF Idle in Working State: disabled
WDF Directed Power / DFx: disabled
PCIe Link State Power Management / ASPM: disabled for AC and DC in the active Windows power plan
---
Why NetAdapterCx matters
The Realtek NetAdapterCx and classic NDIS drivers are not simply two filenames for the same implementation.
The profile in this project was derived from the Realtek NetAdapterCx driver package and its internal configuration.
In particular, the project uses settings related to:
```text
WDF power management
Directed Power / DFx
hidden RSS configuration
RTL8125-specific descriptor / processing parameters
internal Realtek power-management behavior
```
The classic NDIS driver uses a different driver architecture and may expose, interpret or ignore some of these values differently.
For that reason:
NetAdapterCx is currently a requirement, not just a recommendation.
---
Important
This is an enthusiast tuning tool, not an official Realtek utility.
Several parameters used by this profile are undocumented or internal Realtek driver settings. Their exact behavior is not publicly documented and may change between driver versions.
Use it only if you understand that:
administrator rights are required;
your network connection is briefly interrupted while the adapter restarts;
the tool modifies the adapter's registry configuration;
PCIe ASPM is changed globally for the active Windows power plan;
hidden/internal driver parameters are modified;
results may differ between systems, switches, routers, driver versions and workloads.
A registry backup of the Realtek driver key is created automatically before the profile is applied.
Backups are stored in:
```text
%USERPROFILE%\Documents\RTL8125D-Tuner\Backups
```
---
Running the GUI
Download the release ZIP, extract it, then run:
```text
Start-RTL8125D-Tuner.cmd
```
Accept the Windows UAC prompt.
You can also run the PowerShell file directly:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\RTL8125D-LowLatency-Tuner.ps1"
```
---
PowerShell one-liner
After hosting `RTL8125D-LowLatency-Tuner.ps1` at a public raw HTTPS URL, such as GitHub Raw, users can launch it from an Administrator PowerShell window with:
```powershell
irm "https://raw.githubusercontent.com/USER/REPOSITORY/main/RTL8125D-LowLatency-Tuner.ps1" | iex
```
When launched through `irm | iex`, PowerShell must already be elevated because a piped script has no physical local path from which it can self-elevate.
---
GUI functions
Apply Profile — applies the tested low-latency configuration
Refresh Status — compares current values against the profile
Restart Adapter — reinitializes the Realtek adapter
Cloudflare Speed Test — opens `speed.cloudflare.com`
Create Registry Backup — exports the active Realtek driver registry key
Status tab — shows current vs target values
Log tab — shows actions and warnings
A startup/runtime log is also written to:
```text
%TEMP%\RTL8125D-LowLatency-Tuner.log
```
---
Why the RTL8125D revision lock?
The RTL8125 family contains multiple hardware revisions.
Some of the parameters used here are specifically tied to RTL8125 driver internals. For a public release it is safer to refuse automatic application on an untested revision than to assume every RTL8125 variant behaves identically.
Current tested revision:
```text
DEV_8125
REV_0C
```
---
No performance guarantee
The tested system showed improved consistency and lower loaded-latency behavior with this profile, including reduced latency variation under network load.
That does not mean every system will improve.
Always compare before/after behavior on your own hardware, driver version, network and workload.
