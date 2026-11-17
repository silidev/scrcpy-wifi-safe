param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ScrcpyArgs
)

# This starts scrcpy over Wi-Fi. If connection fails or freezes, it safely cleans up,
# discovers updated dynamic ports via mDNS, restarts ADB if needed, and retries.
# Exclusively designed for PowerShell 7 (pwsh).

# Configuration
$deviceHost = if ($env:SCRCPY_DEVICE_IP) { $env:SCRCPY_DEVICE_IP } else { "192.168.178.39" }
$defaultPort = "5555"
$scrcpyPath = if ($env:SCRCPY_PATH) { $env:SCRCPY_PATH } elseif (Test-Path "C:\progs\scrcpy\scrcpy.exe") { "C:\progs\scrcpy\scrcpy.exe" } else { "scrcpy" }

# Timeout in seconds to consider scrcpy successfully running in background
Set-Variable -Name TIMEOUT_SECONDS -Value 5 -Option Constant
$maxAttempts = 3

function Show-WirelessDebuggingHelp {
    Write-Host ""
    Write-Host "Android 11+ Wireless Debugging Help:" -ForegroundColor Yellow
    Write-Host "1. On your phone, go to Settings > Developer Options > Wireless Debugging." -ForegroundColor Yellow
    Write-Host "2. Ensure it is toggled 'On' and connected to the same Wi-Fi network." -ForegroundColor Yellow
    Write-Host "3. If the IP address changed from $deviceHost, set `$env:SCRCPY_DEVICE_IP=<new_ip>`." -ForegroundColor Yellow
    Write-Host ""
}

# Safely invoke an ADB command with a timeout so it never hangs indefinitely
function Invoke-Adb {
    param(
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 5
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "adb"
    $psi.Arguments = $Arguments -join " "
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc) { return @() }

        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $hasExited = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $hasExited) {
            try { $proc.Kill() } catch { }
        }

        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 1000) | Out-Null
        $out = $stdoutTask.Result
        if (-not [string]::IsNullOrWhiteSpace($out)) {
            return ($out -split "`r?`n")
        }
        return @()
    } catch {
        return @()
    }
}

# Safely restarts ADB server with guaranteed timeout and force-kill fallback
function Restart-AdbServer {
    Write-Host "Restarting ADB server..." -ForegroundColor Cyan

    # Try graceful kill-server with 2-second timeout
    try {
        $p = Start-Process -FilePath "adb" -ArgumentList "kill-server" -NoNewWindow -PassThru -ErrorAction SilentlyContinue
        if ($p) {
            if (-not $p.WaitForExit(2000)) {
                try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    } catch { }

    # Force kill any lingering adb processes to guarantee port 5037 is freed
    Stop-Process -Name "adb" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # Start adb server cleanly with 4-second timeout
    try {
        $p = Start-Process -FilePath "adb" -ArgumentList "start-server" -NoNewWindow -PassThru -ErrorAction SilentlyContinue
        if ($p) {
            if (-not $p.WaitForExit(4000)) {
                try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    } catch { }
    Start-Sleep -Milliseconds 500
}

# Check if a specific endpoint is reachable and authorized
function Test-DeviceConnection {
    param([string]$Endpoint)
    if (-not $Endpoint) { return $false }
    $stateLines = Invoke-Adb -Arguments @("-s", $Endpoint, "get-state") -TimeoutSeconds 3
    $state = ($stateLines -join " ").Trim()
    return ($state -eq "device")
}

# Discover the endpoint (IP:Port) for $deviceHost
function Find-DeviceEndpoint {
    param([int]$MdnsTimeoutSeconds = 6)

    # 1. Check if already connected on any port for $deviceHost and alive
    $devicesOut = Invoke-Adb -Arguments @("devices") -TimeoutSeconds 3
    $connected = $devicesOut | Where-Object { $_ -match "$([regex]::Escape($deviceHost)):(\d+)\s+device" }
    if ($connected -match "($([regex]::Escape($deviceHost)):\d+)") {
        $candidate = $matches[1]
        if (Test-DeviceConnection -Endpoint $candidate) {
            return $candidate
        }
    }

    # 2. Check mDNS discovery (Android 11+ Wireless Debugging uses dynamic ports)
    Write-Host "Searching for $deviceHost via mDNS..."
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $MdnsTimeoutSeconds) {
        $mdns = Invoke-Adb -Arguments @("mdns", "services") -TimeoutSeconds 4
        $matchesList = @($mdns | Select-String -Pattern "$([regex]::Escape($deviceHost)):(\d+)")
        if ($matchesList.Count -gt 0) {
            # Pick the most recent match
            $found = $matchesList[-1].Matches[0].Value
            Write-Host "Discovered device port via mDNS: $found" -ForegroundColor Green
            return $found
        }
        Start-Sleep -Milliseconds 700
    }

    # 3. Fallback to default port
    return "$deviceHost`:$defaultPort"
}

# Connects to an endpoint via adb connect with a timeout and visible output
function Connect-AdbEndpoint {
    param(
        [string]$Endpoint,
        [int]$TimeoutSeconds = 6
    )

    Write-Host "Connecting to $Endpoint via adb..."
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "adb"
    $psi.Arguments = "connect $Endpoint"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc) { return $false }

        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $hasExited = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $hasExited) {
            try { $proc.Kill() } catch { }
            Write-Host "adb connect timed out after $TimeoutSeconds seconds." -ForegroundColor Yellow
            return $false
        }

        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 1000) | Out-Null
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result

        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            Write-Host $stdout.Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Host $stderr.Trim() -ForegroundColor Yellow
        }

        return ($stdout -match "connected to")
    } catch {
        Write-Host "Connection error: $_" -ForegroundColor Yellow
        return $false
    }
}

function Start-ScrcpyProcess {
    param([string]$TargetEndpoint)

    $argsList = @()
    if ($ScrcpyArgs) {
        $argsList += $ScrcpyArgs
    }
    if ($argsList -notcontains "-s" -and $argsList -notcontains "--serial") {
        $argsList = @("-s", $TargetEndpoint) + $argsList
    }
    if ($argsList -notcontains "--pause-on-exit=false" -and $argsList -notcontains "--pause-on-exit=true") {
        $argsList += "--pause-on-exit=false"
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $scrcpyPath
    $psi.Arguments = $argsList -join " "
    $psi.UseShellExecute = $false

    $proc = [System.Diagnostics.Process]::Start($psi)

    # Wait for exit or timeout (milliseconds)
    $hasExited = $proc.WaitForExit($TIMEOUT_SECONDS * 1000)

    if (-not $hasExited) {
        if (-not $proc.HasExited) {
            # Process is still running after timeout -> successful connection running in background
            Write-Host "scrcpy launched successfully and running in background." -ForegroundColor Green
            return 0
        }
    }

    # Process exited within timeout period -> evaluation of exit code
    $code = $proc.ExitCode
    Write-Host "scrcpy exited within threshold (exit code: $code)" -ForegroundColor Yellow
    return $code
}

# --- Main Retry Loop ---
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    if ($attempt -gt 1) {
        Write-Host "`n--- Retry attempt $attempt of $maxAttempts ---" -ForegroundColor Cyan
    }

    # Find endpoint (give mDNS a bit more time on retries since ADB was restarted)
    $mdnsWait = if ($attempt -eq 1) { 5 } else { 8 }
    $deviceIp = Find-DeviceEndpoint -MdnsTimeoutSeconds $mdnsWait

    # Verify connection status
    $isConnected = Test-DeviceConnection -Endpoint $deviceIp
    if (-not $isConnected) {
        $connectOk = Connect-AdbEndpoint -Endpoint $deviceIp -TimeoutSeconds 6
        $isConnected = $connectOk -or (Test-DeviceConnection -Endpoint $deviceIp)
    } else {
        Write-Host "Device $deviceIp already connected." -ForegroundColor Green
    }

    if ($isConnected) {
        $exitCode = Start-ScrcpyProcess -TargetEndpoint $deviceIp
        if ($exitCode -eq 0) {
            exit 0
        }
    }

    # If connection or scrcpy failed, clean up before retrying
    if ($attempt -lt $maxAttempts) {
        Write-Host "Connection attempt $attempt failed. Retrying..." -ForegroundColor Yellow
        if ($deviceIp) {
            # Disconnect stale endpoint so it doesn't linger in ADB device cache
            Invoke-Adb -Arguments @("disconnect", $deviceIp) -TimeoutSeconds 2 | Out-Null
        }
        Restart-AdbServer
        Start-Sleep -Milliseconds 800
    }
}

Write-Host "`nERROR: Could not establish a connection to $deviceHost after $maxAttempts attempts." -ForegroundColor Red
Show-WirelessDebuggingHelp
exit 1