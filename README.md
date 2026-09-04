# RTL8125D Low-Latency Tuner

A small Windows GUI that applies and verifies a low-latency profile for the **Realtek RTL8125D 2.5GbE controller**.

## Supported hardware

The public build intentionally enables the **Apply Profile** button only when it detects:

```text
PCI\VEN_10EC&DEV_8125 ... REV_0C
```

That is the RTL8125D revision this profile was developed and tested on.

Other RTL8125-family revisions may expose similar driver parameters, but they are **not automatically modified** by this release.

## Tested profile

The profile currently applies:

### Receive / CPU distribution
- Receive Side Scaling (RSS): enabled
- RSS queues requested: 4
- Effective queues observed on the tested RTL8125D: 3

### Latency / batching
- Interrupt Moderation: disabled
- Hidden Interrupt Moderation Level: Low (kept in registry)
- Flow Control: disabled
- Receive Segment Coalescing (IPv4/IPv6): disabled
- Large Send Offload v2 (IPv4/IPv6): disabled
- Priority / VLAN: disabled
- Checksum offloads are intentionally left enabled

### Hidden / internal Realtek parameters
- `TxOptimizeThreshold = 500`
- `RxOptimizeThreshold = 500`
- `RxProcMax = 64`
- `TxProcMax = 64`
- `TxDesFetchNum8125 = 4`
- `*IdleRestriction = 1`
- `PowerDownPll = 0`

### Power management
- Power Saving Mode: disabled
- Energy Efficient Ethernet: disabled
- Advanced EEE: disabled
- Green Ethernet: disabled
- Gigabit Lite: disabled
- WDF Idle in Working State: disabled
- WDF Directed Power / DFx: disabled
- PCIe Link State Power Management / ASPM: disabled for AC and DC in the **active Windows power plan**

## Important

This is an enthusiast tuning tool, not an official Realtek utility.

Several parameters are hidden/internal Realtek driver settings. Their exact behavior is not publicly documented and may differ between driver versions.

Use it only if you understand that:

- administrator rights are required;
- your network connection is briefly interrupted while the adapter restarts;
- the tool modifies the adapter's registry configuration;
- PCIe ASPM is changed globally for the active Windows power plan;
- results can differ between systems, switches, routers, driver versions and workloads.

A registry backup of the Realtek driver key is created automatically before the profile is applied.

Backups are stored in:

```text
%USERPROFILE%\Documents\RTL8125D-Tuner\Backups
```

## Running the GUI

Download the release ZIP, extract it, then run:

```text
Start-RTL8125D-Tuner.cmd
```

Accept the Windows UAC prompt.

You can also run the PowerShell file directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\RTL8125D-LowLatency-Tuner.ps1"
```

## PowerShell one-liner

After hosting `RTL8125D-LowLatency-Tuner.ps1` at a public raw HTTPS URL (for example GitHub Raw), users can launch it from an **Administrator PowerShell** window with:

```powershell
irm "https://raw.githubusercontent.com/USER/REPOSITORY/main/RTL8125D-LowLatency-Tuner.ps1" | iex
```

When launched through `irm | iex`, PowerShell must already be elevated because a piped script has no physical local path from which it can self-elevate.

## GUI functions

- **Apply Profile** — applies the tested low-latency configuration
- **Refresh Status** — compares current values against the profile
- **Restart Adapter** — reinitializes the Realtek adapter
- **Cloudflare Speed Test** — opens `speed.cloudflare.com`
- **Create Registry Backup** — exports the active Realtek driver registry key
- **Status** tab — shows current vs target values
- **Log** tab — shows actions and warnings

A startup/runtime log is also written to:

```text
%TEMP%\RTL8125D-LowLatency-Tuner.log
```

## Why the hardware lock?

The RTL8125 family contains multiple hardware revisions. Some of the values used here are specifically tied to RTL8125 driver internals.

For a public release it is safer to **refuse automatic application on an untested revision** than to assume every RTL8125 variant behaves identically.

The status view can still help identify the installed adapter and driver.

## No performance guarantee

The tested system showed better consistency and lower loaded-latency behavior with this profile, but that does not mean every system will improve.

Always compare before/after behavior on your own network and workload.
