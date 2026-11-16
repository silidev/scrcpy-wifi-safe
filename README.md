# scrcpy-wifi-safe

A PowerShell wrapper script that manages connections for scrcpy over Wi-Fi.

## Key Features

- **Android 11+ Dynamic Port Detection**: Detects dynamic ports assigned by Android Wireless Debugging using `adb mdns services`.
- **Port 5555 Fallback**: Uses standard port 5555 when mDNS is unavailable.
- **Fail-safe Recovery**: Checks connection state and restarts ADB server if connection becomes unresponsive.
- **No Background Hangs**: Enforces `--pause-on-exit=false` to avoid hanging background processes on errors.
- **Argument Forwarding**: Forwards parameters directly to scrcpy.

## Setup & Configuration

Configure the device IP in `scrcpy-wifi-safe.ps1` or set the environment variable:

```powershell
$env:SCRCPY_DEVICE_IP = "192.168.178.39"
```

## Running

```powershell
powershell -ExecutionPolicy Bypass -File .\scrcpy-wifi-safe.ps1
```

Example in scrcpy-koh.cmd
