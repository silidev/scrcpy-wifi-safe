param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ScrcpyArgs
)

# This starts scrcpy but if that fails it kill the adb server and adb connects again and then starts scrcpy.
# Published here: https://github.com/Genymobile/scrcpy/wiki/Fail-safe-connection-over-Wifi
# Configuration
$deviceHost = if ($env:SCRCPY_DEVICE_IP) { $env:SCRCPY_DEVICE_IP } else { "192.168.178.39" }
$defaultPort = "5555"
$scrcpyPath = if ($env:SCRCPY_PATH) { $env:SCRCPY_PATH } elseif (Test-Path "C:\progs\scrcpy\scrcpy.exe") { "C:\progs\scrcpy\scrcpy.exe" } else { "scrcpy" }
# #### Timeout ####
# 5 works good
Set-Variable -Name TIMEOUT_SECONDS -Value 5 -Option Constant

function Show-WirelessDebuggingHelp {
    Write-Host ""
    Write-Host "Android 11+ Wireless Debugging" -ForegroundColor Yellow
    Write-Host "On the phone, go to Settings > Developer Options > Wireless Debugging and toggle it On." -ForegroundColor Yellow
    Write-Host ""
}

function Find-DeviceEndpoint {
    # 1. Check if already connected on any port for $deviceHost
    $connected = adb devices 2>$null | Where-Object { $_ -match "$([regex]::Escape($deviceHost)):(\d+)\s+device" }
    if ($connected -match "($([regex]::Escape($deviceHost)):\d+)") {
        return $matches[1]
    }

    # 2. Check mDNS discovery (Android 11+ Wireless Debugging uses dynamic ports)
    for ($i = 0; $i -lt 3; $i++) {
        $mdns = adb mdns services 2>$null
        $match = $mdns | Select-String -Pattern "$([regex]::Escape($deviceHost)):(\d+)"
        if ($match -and $match.Matches.Count -gt 0) {
            return $match.Matches[0].Value
        }
        if ($i -lt 2) { Start-Sleep -Milliseconds 600 }
    }

    # 3. Fallback to default port
    return "$deviceHost`:$defaultPort"
}

$deviceIp = Find-DeviceEndpoint

function Test-DeviceConnection {
    $script:deviceIp = Find-DeviceEndpoint
    $state = & adb -s $script:deviceIp get-state 2>&1
    return ($LASTEXITCODE -eq 0 -and $state -eq "device")
}

function Start-ScrcpyProcess {
    $argsList = @()
    if ($ScrcpyArgs) {
        $argsList += $ScrcpyArgs
    }
    if ($argsList -notcontains "-s" -and $argsList -notcontains "--serial") {
        $argsList = @("-s", $deviceIp) + $argsList
    }
    if ($argsList -notcontains "--pause-on-exit=false" -and $argsList -notcontains "--pause-on-exit=true") {
        $argsList += "--pause-on-exit=false"
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $scrcpyPath
    $psi.Arguments = $argsList -join " "
    $psi.UseShellExecute = $false

    $proc = [System.Diagnostics.Process]::Start($psi)
    
    # Wait for exit or timeout (milliseconds)
    $hasExited = $proc.WaitForExit($TIMEOUT_SECONDS * 1000)

    if (-not $hasExited) {
        if (-not $proc.HasExited) {
            # Process is still running after timeout -> successful connection running in background
            Write-Host "scrcpy launched successfully and running in background."
            return 0
        }
    }

    # Process exited within timeout period -> evaluation of exit code
    $code = $proc.ExitCode
    Write-Host "scrcpy exited within threshold (exit code: $code)"
    return $code
}

# Verify device is connected first; attempt connection if not yet established
if (-not (Test-DeviceConnection)) {
    Write-Host "Device $deviceIp not connected. Connecting via adb..."
    adb connect $deviceIp
    
    if (-not (Test-DeviceConnection)) {
        Write-Host "Connection failed. Retrying with adb restart..."
        adb kill-server
        Start-Sleep -Milliseconds 500
        $deviceIp = Find-DeviceEndpoint
        adb connect $deviceIp
        
        if (-not (Test-DeviceConnection)) {
            Write-Host "ERROR: Could not find any ADB device." -ForegroundColor Red
            Show-WirelessDebuggingHelp
            exit 1
        }
    }
}

$exitCode = Start-ScrcpyProcess

if ($exitCode -ne 0) {
    Write-Host "Connection failed. Retrying with adb connect..."
    $deviceIp = Find-DeviceEndpoint
    adb connect $deviceIp
    $exitCode = Start-ScrcpyProcess
    
    if ($exitCode -ne 0) {
        Write-Host "Still failing. Restarting adb server..."
        adb kill-server
        Start-Sleep -Milliseconds 500
        $deviceIp = Find-DeviceEndpoint
        adb connect $deviceIp
        $exitCode = Start-ScrcpyProcess
        if ($exitCode -ne 0) {
            Show-WirelessDebuggingHelp
            exit $exitCode
        }
    }
}