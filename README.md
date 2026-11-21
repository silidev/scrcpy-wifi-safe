# scrcpy-wifi-safe

A PowerShell wrapper script that manages connections for scrcpy over Wi-Fi.

## Key Features

- **Android 11+ Dynamic Port Detection**: Detects dynamic ports assigned by Android Wireless Debugging using `adb mdns services`.
- **Port 5555 Fallback**: Uses standard port 5555 when mDNS is unavailable.
- **Fail-safe Recovery**: Checks connection state and restarts ADB server if connection becomes unresponsive.
- **No Background Hangs**: Enforces `--pause-on-exit=false` to avoid hanging background processes on errors.
- **Argument Forwarding**: Forwards parameters directly to scrcpy.

## Setup & Configuration

Configure the device IP by passing it as a CLI argument, setting the environment variable, or modifying the default in `scrcpy-wifi-safe.ps1`:

```powershell
# Direct CLI argument (supported by s.cmd, scrcpy-koh.cmd, and scrcpy-wifi-safe.ps1):
s 192.168.178.134

# Environment variable override:
$env:SCRCPY_DEVICE_IP = "192.168.178.39"
```

## Running

```powershell
# Via shim shortcut:
s 192.168.178.134

# Directly via PowerShell:
pwsh -ExecutionPolicy Bypass -File .\scrcpy-wifi-safe.ps1 192.168.178.134
```

Example in `scrcpy-koh.cmd`.
