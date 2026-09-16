# 1gbEthernetSpeedMonitor

*[Читать на русском](README.ru.md)*

A PowerShell script that watches the link speed of a network adapter and automatically recovers it when the adapter negotiates a lower speed than expected (e.g. an adapter that should link at 1 Gbps but drops to 100 Mbps).

## What it does

- Periodically checks the link speed of a chosen (or auto-detected) network adapter.
- If the speed drops below a configurable threshold (default: 1 Gbps), it logs the event and runs `Restart-NetAdapter` to force renegotiation with the switch/router.
- Restarts are rate-limited by a cooldown period to avoid flapping the adapter repeatedly.
- If, after a restart, the adapter still negotiates below the threshold, it can optionally force the adapter's "Speed & Duplex" advanced property to its highest non-auto value instead of relying on auto-negotiation.
- Logs the time since the system last resumed from sleep (via the Kernel-Power event 107), to help correlate speed drops with sleep/wake cycles.
- Writes all events to both the console and a log file.
- Auto-detects the system UI language and writes log messages in Russian if the OS language is Russian, or in English otherwise.
- Auto-selects the "right" physical Ethernet adapter: among active, non-virtual adapters with `PhysicalMediaType` equal to `802.3` (true wired Ethernet — this reliably excludes Wi-Fi, Bluetooth PAN, virtual/tunnel adapters, etc.), it picks the one with the highest currently negotiated link speed and logs which adapter was chosen. If the system has several Ethernet adapters and auto-detection doesn't pick the one you want, pass its name explicitly via `-AdapterName`.

## Requirements

- Windows with PowerShell.
- Administrator privileges (required by `Restart-NetAdapter`).

## Usage

Run from an elevated PowerShell prompt:

```powershell
.\1gbEthernetSpeedMonitor.ps1
```

By default, the script auto-selects the fastest active, physical, wired Ethernet adapter (see [How it works](#how-it-works)). If you have multiple Ethernet adapters and want to monitor a specific one, pass its name via `-AdapterName`.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-AdapterName` | auto-detected | Name of the adapter to monitor. Useful when the machine has several Ethernet adapters. If omitted, the fastest active physical Ethernet adapter is auto-detected. |
| `-IntervalSeconds` | `15` | How often to check the link speed, in seconds. |
| `-MinSpeedBps` | `1000000000` (1 Gbps) | Minimum acceptable link speed, in bits per second. |
| `-CooldownSeconds` | `90` | Minimum time between adapter restarts, in seconds, to prevent repeated restarts. |
| `-ForceGigabit` | `$true` | If the speed is still below the threshold after a restart, force the "Speed & Duplex" property to its highest value instead of auto-negotiation. |
| `-LogPath` | `1gbEthernetSpeedMonitor.log` next to the script | Path to the log file. |

### Example

```powershell
.\1gbEthernetSpeedMonitor.ps1 -AdapterName "Ethernet" -IntervalSeconds 10 -MinSpeedBps 1000000000 -CooldownSeconds 60
```

## Sample output

```
[2026-09-16 10:00:00] Auto-detected adapter 'Ethernet' (current speed: 1 Gbps).
[2026-09-16 10:00:00] Starting monitoring of adapter 'Ethernet'. Threshold: 1 Gbps. Check interval: 15 sec. Restart cooldown: 90 sec.
[2026-09-16 10:05:15] Speed drop detected: 100 Mbps (below threshold 1 Gbps).
[2026-09-16 10:05:15] 320 sec have passed since the system last resumed from sleep.
[2026-09-16 10:05:15] Running Restart-NetAdapter for 'Ethernet'...
[2026-09-16 10:05:22] After restart: speed 1 Gbps, status Up.
```

## How it works

1. Verifies the script is running as Administrator.
2. Resolves the target adapter (explicit name or auto-detection).
3. Enters an infinite loop:
   - Reads the adapter's current link speed.
   - If it's below the threshold, logs the drop, checks time since last sleep/wake, and — respecting the cooldown — restarts the adapter.
   - If the speed is still too low after the restart and `-ForceGigabit` is enabled, forces the highest available speed/duplex value via the adapter's advanced registry properties.
   - Sleeps for `IntervalSeconds` and repeats.

## Notes

- The script reads/sets the adapter's "Speed & Duplex" property by its registry keyword (`*SpeedDuplex`) rather than by localized display name, since display text is language-dependent while the underlying codes are not.
- Log entries are timestamped and written both to the console and to the log file specified by `-LogPath`.
- The log language is picked once at startup based on `Get-UICulture` and does not change while the script is running.
