param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ScrcpyArgs
)

# This starts scrcpy over Wi-Fi. If connection fails or freezes, it safely cleans up,
# discovers updated dynamic ports via mDNS, restarts ADB if needed, and retries.
# Exclusively designed for PowerShell 7 (pwsh) with minimal latency timeouts.

# Configuration
$deviceHost = if ($env:SCRCPY_DEVICE_IP) { $env:SCRCPY_DEVICE_IP } else { "192.168.178.200" }
$defaultPort = "5555"
$scrcpyPath = if ($env:SCRCPY_PATH) { $env:SCRCPY_PATH } elseif (Test-Path "C:\progs\scrcpy\scrcpy.exe") { "C:\progs\scrcpy\scrcpy.exe" } else { "scrcpy" }

# Timeout in seconds to consider scrcpy successfully running in background
$timeoutSeconds = 2
$maxAttempts = 3
$maxPingLatencyMs = if ($env:SCRCPY_MAX_PING_MS) { [int]$env:SCRCPY_MAX_PING_MS } else { 200 }
$pingBufferSize = 1400

# Ping pre-check: verify network quality before proceeding
Write-Host "Prüfe Verbindung zu $deviceHost (Ping -l $pingBufferSize)..."
$pingSuccess = $false
$pingLatency = $null
$pingError = $null

try {
    $pingSender = [System.Net.NetworkInformation.Ping]::new()
    $pingBuffer = [byte[]]::new($pingBufferSize)
    $pingReply = $pingSender.Send($deviceHost, 2000, $pingBuffer)
    if ($pingReply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
        $pingSuccess = $true
        $pingLatency = $pingReply.RoundtripTime
    } else {
        $pingError = "Status: $($pingReply.Status)"
    }
} catch {
    try {
        $pingOut = ping.exe $deviceHost -l $pingBufferSize -n 1
        if ($LASTEXITCODE -eq 0 -and ($pingOut -join "`n") -match '(?:time|Zeit)[<=](?<ms>\d+)\s*ms') {
            $pingSuccess = $true
            $pingLatency = [int]$Matches['ms']
        } else {
            $pingError = "ping.exe fehlgeschlagen (Exit-Code: $LASTEXITCODE)"
        }
    } catch {
        $pingError = $_.Exception.Message
    }
}

if (-not $pingSuccess) {
    Write-Host "ABBRUCH: Ping zu $deviceHost (-l $pingBufferSize) ist fehlgeschlagen ($pingError)." -ForegroundColor Red
    exit 1
}

if ($pingLatency -gt $maxPingLatencyMs) {
    Write-Host "ABBRUCH: Ping-Latenz zu $deviceHost ist zu hoch: $pingLatency ms (maximal erlaubt: $maxPingLatencyMs ms bei -l $pingBufferSize)." -ForegroundColor Red
    exit 1
}

Write-Host "Ping OK: $pingLatency ms (<= $maxPingLatencyMs ms)." -ForegroundColor Green

function Show-WirelessDebuggingHelp {
    Write-Host ""
    Write-Host "Android 11+ Wireless Debugging Help:" -ForegroundColor Yellow
    Write-Host "1. On your phone, go to Settings > Developer Options > Wireless Debugging." -ForegroundColor Yellow
    Write-Host "2. Ensure it is toggled 'On' and connected to the same Wi-Fi network." -ForegroundColor Yellow
    Write-Host "3. If the IP address changed from $deviceHost, set `$env:SCRCPY_DEVICE_IP=<new_ip>`." -ForegroundColor Yellow
    Write-Host ""
}

# Safely invoke an ADB command with a tight timeout so it never hangs indefinitely
function Invoke-Adb {
    param(
        [string[]]$Arguments,
        [double]$TimeoutSeconds = 2
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "adb"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($arg in $Arguments) {
        $psi.ArgumentList.Add($arg)
    }

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc) { return @() }

        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $hasExited = $proc.WaitForExit([int]($TimeoutSeconds * 1000))
        if (-not $hasExited) {
            try { $proc.Kill() } catch { }
        }

        if (-not $stdoutTask.IsCompleted -or -not $stderrTask.IsCompleted) {
            [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 300) | Out-Null
        }

        $out = $stdoutTask.Result
        if (-not [string]::IsNullOrWhiteSpace($out)) {
            return ($out -split "`r?`n")
        }
        return @()
    } catch {
        return @()
    }
}

# Safely restarts ADB server with immediate force-kill (avoids socket hangs and deadlocks)
function Restart-AdbServer {
    Write-Host "Restarting ADB server..." -ForegroundColor Cyan

    # Immediate force-kill: eliminates hanging kill-server calls and frees tcp:5037
    Stop-Process -Name "adb" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 100

    # Start adb server cleanly (5s timeout protects cold starts under load without adding delay)
    try {
        $p = Start-Process -FilePath "adb" -ArgumentList "start-server" -NoNewWindow -PassThru -ErrorAction SilentlyContinue
        if ($p) {
            if (-not $p.WaitForExit(5000)) {
                try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    } catch { }
    Start-Sleep -Milliseconds 100
}

# Check if a specific endpoint is reachable and authorized (1s max)
function Test-DeviceConnection {
    param([string]$Endpoint)
    if (-not $Endpoint) { return $false }
    $stateLines = Invoke-Adb -Arguments @("-s", $Endpoint, "get-state") -TimeoutSeconds 1
    $state = ($stateLines -join " ").Trim()
    return ($state -eq "device")
}

# Discover the endpoint (IP:Port) for $deviceHost
function Find-DeviceEndpoint {
    param([double]$MdnsTimeoutSeconds = 2)

    # 1. Check if already connected on any port for $deviceHost
    $devicesOut = Invoke-Adb -Arguments @("devices") -TimeoutSeconds 1
    foreach ($line in $devicesOut) {
        if ($line -match "$([regex]::Escape($deviceHost)):(\d+)\s+device") {
            return "$deviceHost`:$($matches[1])"
        }
    }

    # 2. Check mDNS discovery (Android 11+ Wireless Debugging uses dynamic ports)
    Write-Host "Searching for $deviceHost via mDNS..."
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $MdnsTimeoutSeconds) {
        $mdns = Invoke-Adb -Arguments @("mdns", "services") -TimeoutSeconds 1.5
        # Scan backwards to pick the latest published port immediately without pipeline overhead
        for ($i = $mdns.Length - 1; $i -ge 0; $i--) {
            if ($mdns[$i] -match "$([regex]::Escape($deviceHost)):(\d+)") {
                $found = "$deviceHost`:$($matches[1])"
                Write-Host "Discovered device port via mDNS: $found" -ForegroundColor Green
                return $found
            }
        }
        Start-Sleep -Milliseconds 250
    }

    # 3. Fallback to default port
    return "$deviceHost`:$defaultPort"
}

# Connects to an endpoint via adb connect with a tight timeout and visible output
function Connect-AdbEndpoint {
    param(
        [string]$Endpoint,
        [double]$TimeoutSeconds = 3
    )

    Write-Host "Connecting to $Endpoint via adb..."
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "adb"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.ArgumentList.Add("connect")
    $psi.ArgumentList.Add($Endpoint)

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc) { return $false }

        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $hasExited = $proc.WaitForExit([int]($TimeoutSeconds * 1000))
        if (-not $hasExited) {
            try { $proc.Kill() } catch { }
            Write-Host "adb connect timed out after $TimeoutSeconds seconds." -ForegroundColor Yellow
            return $false
        }

        if (-not $stdoutTask.IsCompleted -or -not $stderrTask.IsCompleted) {
            [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 300) | Out-Null
        }
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
    $psi.UseShellExecute = $false
    foreach ($arg in $argsList) {
        $psi.ArgumentList.Add($arg)
    }

    $proc = [System.Diagnostics.Process]::Start($psi)

    # Wait for exit or timeout (milliseconds)
    $hasExited = $proc.WaitForExit($timeoutSeconds * 1000)

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

    # Find endpoint (give mDNS 1.5s on first try, 3.5s on retries after server restart)
    $mdnsWait = if ($attempt -eq 1) { 1.5 } else { 3.5 }
    $deviceIp = Find-DeviceEndpoint -MdnsTimeoutSeconds $mdnsWait

    # Verify connection status
    $isConnected = Test-DeviceConnection -Endpoint $deviceIp
    if (-not $isConnected) {
        $connectOk = Connect-AdbEndpoint -Endpoint $deviceIp -TimeoutSeconds 3
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

    # If connection or scrcpy failed, clean up and restart ADB server before retrying
    if ($attempt -lt $maxAttempts) {
        Write-Host "Connection attempt $attempt failed. Retrying..." -ForegroundColor Yellow
        Restart-AdbServer
        Start-Sleep -Milliseconds 150
    }
}

Write-Host "`nERROR: Could not establish a connection to $deviceHost after $maxAttempts attempts." -ForegroundColor Red
Show-WirelessDebuggingHelp
exit 1