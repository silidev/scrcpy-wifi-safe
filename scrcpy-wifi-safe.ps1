param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ScrcpyArgs
)

# This starts scrcpy over Wi-Fi. If connection fails or freezes, it safely cleans up,
# discovers updated dynamic ports via mDNS, restarts ADB if needed, and retries.
# Exclusively designed for PowerShell 7 (pwsh) with minimal latency timeouts.

# Extract target device IP or endpoint (e.g. 192.168.1.100 or 192.168.1.100:5555) from CLI arguments if supplied
$cliTargetIp = $null
$cliDefaultPort = $null
$remainingScrcpyArgs = [System.Collections.Generic.List[string]]::new()

if ($ScrcpyArgs) {
    for ($i = 0; $i -lt $ScrcpyArgs.Length; $i++) {
        $arg = $ScrcpyArgs[$i]
        $prevArg = if ($i -gt 0) { $ScrcpyArgs[$i - 1] } else { $null }
        $parsedIp = [ref]$null
        if (-not $cliTargetIp -and $prevArg -ne "-s" -and $prevArg -ne "--serial" -and $arg -match '^((?:\d{1,3}\.){3}\d{1,3})(?::(\d+))?$') {
            if ([System.Net.IPAddress]::TryParse($Matches[1], $parsedIp)) {
                $cliTargetIp = $parsedIp.Value.ToString()
                if ($Matches[2]) {
                    $cliDefaultPort = $Matches[2]
                }
                continue
            }
        }
        $remainingScrcpyArgs.Add($arg)
    }
}
$ScrcpyArgs = $remainingScrcpyArgs.ToArray()

# Enable ADB's built-in Openscreen mDNS daemon on Windows (avoids "ERROR: mdns daemon unavailable" when Bonjour is not installed)
$env:ADB_MDNS_OPENSCREEN = "1"

# Configuration
$deviceHost = if ($cliTargetIp) { $cliTargetIp } elseif ($env:SCRCPY_DEVICE_IP) { $env:SCRCPY_DEVICE_IP } else { "192.168.178.200" }
$defaultPort = if ($cliDefaultPort) { $cliDefaultPort } else { "5555" }
$scrcpyPath = if ($env:SCRCPY_PATH) { $env:SCRCPY_PATH } elseif (Test-Path "C:\progs\scrcpy\scrcpy.exe") { "C:\progs\scrcpy\scrcpy.exe" } else { "scrcpy" }

# Timeouts & limits
$timeoutMs = if ($env:SCRCPY_TIMEOUT_MS) { [int]$env:SCRCPY_TIMEOUT_MS } else { 2000 }
$maxAttempts = 3
$pingBufferSize = 1400
$pingTimeoutMs = if ($env:SCRCPY_PING_TIMEOUT_MS) { [int]$env:SCRCPY_PING_TIMEOUT_MS } else { 1000 }

# Timeouts for measured commands
$adbStartServerTimeoutMs = if ($env:SCRCPY_ADB_START_TIMEOUT_MS) { [int]$env:SCRCPY_ADB_START_TIMEOUT_MS } else { 5000 }
$mdnsTimeoutFirstAttemptMs = if ($env:SCRCPY_MDNS_TIMEOUT_FIRST_MS) { [double]$env:SCRCPY_MDNS_TIMEOUT_FIRST_MS } else { 1500 }
$mdnsTimeoutRetryMs = if ($env:SCRCPY_MDNS_TIMEOUT_RETRY_MS) { [double]$env:SCRCPY_MDNS_TIMEOUT_RETRY_MS } else { 3500 }
$adbConnectTimeoutMs = if ($env:SCRCPY_ADB_CONNECT_TIMEOUT_MS) { [double]$env:SCRCPY_ADB_CONNECT_TIMEOUT_MS } else { 1000 }
$durationRedThresholdMs = if ($env:SCRCPY_DURATION_RED_MS) { [int]$env:SCRCPY_DURATION_RED_MS } else { 200 }

# Verify network quality before proceeding
function Test-DevicePing {
    param(
        [string]$TargetHost = $deviceHost,
        [int]$BufferSize = $pingBufferSize,
        [int]$TimeoutMs = $pingTimeoutMs
    )

    Write-Host "Checking connection to $TargetHost (Ping -l $BufferSize)..."
    $pingSuccess = $false
    $pingLatency = $null
    $pingError = $null

    try {
        $pingSender = [System.Net.NetworkInformation.Ping]::new()
        $pingBuffer = [byte[]]::new($BufferSize)
        $pingReply = $pingSender.Send($TargetHost, $TimeoutMs, $pingBuffer)
        if ($pingReply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            $pingSuccess = $true
            $pingLatency = $pingReply.RoundtripTime
        } else {
            $pingError = "Status: $($pingReply.Status)"
        }
    } catch {
        try {
            $pingOut = ping.exe $TargetHost -l $BufferSize -n 1
            if ($LASTEXITCODE -eq 0 -and ($pingOut -join "`n") -match '(?:time)[<=](?<ms>\d+)\s*ms') {
                $pingSuccess = $true
                $pingLatency = [int]$Matches['ms']
            } else {
                $pingError = "ping.exe failed (exit code: $LASTEXITCODE)"
            }
        } catch {
            $pingError = $_.Exception.Message
        }
    }

    if (-not $pingSuccess) {
        Write-Host "ABORT: Ping to $TargetHost (-l $BufferSize) failed ($pingError)." -ForegroundColor Red
        exit 1
    }

    if ($pingLatency -gt $TimeoutMs) {
        Write-Host "ABORT: Ping latency to $TargetHost is too high: $pingLatency ms (max allowed: $TimeoutMs ms at -l $BufferSize)." -ForegroundColor Red
        exit 1
    }

    Write-Host "Ping OK: $pingLatency ms (<= $TimeoutMs ms)." -ForegroundColor Green
}

function Show-WirelessDebuggingHelp {
    Write-Host ""
    Write-Host "Android 11+ Wireless Debugging Help:" -ForegroundColor Yellow
    Write-Host "1. On your phone, go to Settings > Developer Options > Wireless Debugging." -ForegroundColor Yellow
    Write-Host "2. Ensure it is toggled 'On' and connected to the same Wi-Fi network." -ForegroundColor Yellow
    Write-Host "3. If the IP address changed from $deviceHost, pass the new IP (e.g. 's <ip>') or set `$env:SCRCPY_DEVICE_IP=<new_ip>`." -ForegroundColor Yellow
    Write-Host ""
}

function Write-CommandDuration {
    param(
        [string]$CommandName,
        [long]$DurationMs
    )
    Write-Host "$CommandName took " -NoNewline
    if ($DurationMs -gt $durationRedThresholdMs) {
        Write-Host "$DurationMs ms" -ForegroundColor Red -NoNewline
    } else {
        Write-Host "$DurationMs ms" -NoNewline
    }
    Write-Host "."
}

# Safely invoke an ADB command with a tight timeout so it never hangs indefinitely
function Invoke-Adb {
    param(
        [string[]]$Arguments,
        [double]$TimeoutMs = 2000
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

        $hasExited = $proc.WaitForExit([int]$TimeoutMs)
        if (-not $hasExited) {
            try { $proc.Kill($true) } catch { }
            Write-Host "adb $($Arguments -join ' ') timed out after $TimeoutMs ms." -ForegroundColor Yellow
        }

        if (-not $stdoutTask.IsCompleted -or -not $stderrTask.IsCompleted) {
            [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 300) | Out-Null
        }

        $out = if ($stdoutTask.IsCompleted) { $stdoutTask.Result } else { "" }
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

    # Start adb server cleanly (protected by timeout against cold starts under load without adding delay)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $p = Start-Process -FilePath "adb" -ArgumentList "start-server" -NoNewWindow -PassThru -ErrorAction SilentlyContinue
        if ($p) {
            if (-not $p.WaitForExit($adbStartServerTimeoutMs)) {
                try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    } catch { }
    $sw.Stop()
    Write-CommandDuration -CommandName "adb start-server" -DurationMs $sw.ElapsedMilliseconds
    Start-Sleep -Milliseconds 100
}

# Ensures ADB server is running before issuing redirected queries, preventing cold-start daemon pipe hangs
function Ensure-AdbServer {
    $isRunning = $false
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $task = $tcp.ConnectAsync("127.0.0.1", 5037)
        if ($task.Wait(150)) {
            $isRunning = $true
        }
        $tcp.Dispose()
    } catch { }

    if (-not $isRunning) {
        Restart-AdbServer
    }
}

# Check if a specific endpoint is reachable and authorized (1000 ms max)
function Test-DeviceConnection {
    param([string]$Endpoint)
    if (-not $Endpoint) { return $false }
    $stateLines = Invoke-Adb -Arguments @("-s", $Endpoint, "get-state") -TimeoutMs 1000
    $state = ($stateLines -join " ").Trim()
    return ($state -eq "device")
}

# Discover the endpoint (IP:Port) for $deviceHost
function Find-DeviceEndpoint {
    param([double]$MdnsTimeoutMs = $mdnsTimeoutFirstAttemptMs)

    # 1. Check if already connected on any port for $deviceHost
    Write-Host "Checking connected ADB devices..."
    $devicesOut = Invoke-Adb -Arguments @("devices") -TimeoutMs 1000
    foreach ($line in $devicesOut) {
        if ($line -match "$([regex]::Escape($deviceHost)):(\d+)\s+device") {
            return "$deviceHost`:$($matches[1])"
        }
    }

    # 2. Check mDNS discovery (Android 11+ Wireless Debugging uses dynamic ports)
    Write-Host "Searching for $deviceHost via mDNS..."
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalMilliseconds -lt $MdnsTimeoutMs) {
        $mdns = Invoke-Adb -Arguments @("mdns", "services") -TimeoutMs 1500
        # Scan backwards to pick the latest published port immediately without pipeline overhead
        for ($i = $mdns.Length - 1; $i -ge 0; $i--) {
            if ($mdns[$i] -match "$([regex]::Escape($deviceHost)):(\d+)") {
                $found = "$deviceHost`:$($matches[1])"
                $stopwatch.Stop()
                Write-Host "Discovered device port via mDNS: $found" -ForegroundColor Green
                Write-CommandDuration -CommandName "mDNS search" -DurationMs $stopwatch.ElapsedMilliseconds
                return $found
            }
        }
        Start-Sleep -Milliseconds 250
    }
    $stopwatch.Stop()
    Write-CommandDuration -CommandName "mDNS search" -DurationMs $stopwatch.ElapsedMilliseconds

    # 3. If a USB-connected device matches $deviceHost, enable tcpip on $defaultPort
    foreach ($line in $devicesOut) {
        if ($line -match '^([^\s:]+)\s+device\b') {
            $usbSerial = $matches[1]
            $ipLines = Invoke-Adb -Arguments @("-s", $usbSerial, "shell", "ip", "-4", "addr", "show", "wlan0") -TimeoutMs 1500
            if (($ipLines -join "`n") -match [regex]::Escape($deviceHost)) {
                Write-Host "Found USB device $usbSerial with IP $deviceHost. Enabling adb tcpip $defaultPort..." -ForegroundColor Cyan
                Invoke-Adb -Arguments @("-s", $usbSerial, "tcpip", $defaultPort) -TimeoutMs 3000 | Out-Null
                Start-Sleep -Milliseconds 500
                return "$deviceHost`:$defaultPort"
            }
        }
    }

    # 4. Fallback to default port
    return "$deviceHost`:$defaultPort"
}

# Connects to an endpoint via adb connect with a tight timeout and visible output
function Connect-AdbEndpoint {
    param(
        [string]$Endpoint,
        [double]$TimeoutMs = $adbConnectTimeoutMs
    )

    Write-Host "Connecting to $Endpoint via adb..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
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
        if (-not $proc) {
            $sw.Stop()
            Write-CommandDuration -CommandName "adb connect" -DurationMs $sw.ElapsedMilliseconds
            return $false
        }

        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $hasExited = $proc.WaitForExit([int]$TimeoutMs)
        if (-not $hasExited) {
            try { $proc.Kill($true) } catch { }
            $sw.Stop()
            Write-Host "adb connect timed out after $TimeoutMs ms." -ForegroundColor Yellow
            Write-CommandDuration -CommandName "adb connect" -DurationMs $sw.ElapsedMilliseconds
            return $false
        }

        if (-not $stdoutTask.IsCompleted -or -not $stderrTask.IsCompleted) {
            [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 300) | Out-Null
        }
        $sw.Stop()
        $stdout = if ($stdoutTask.IsCompleted) { $stdoutTask.Result } else { "" }
        $stderr = if ($stderrTask.IsCompleted) { $stderrTask.Result } else { "" }

        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            Write-Host $stdout.Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Host $stderr.Trim() -ForegroundColor Yellow
        }
        Write-CommandDuration -CommandName "adb connect" -DurationMs $sw.ElapsedMilliseconds

        return ($stdout -match "connected to")
    } catch {
        $sw.Stop()
        Write-Host "Connection error: $_" -ForegroundColor Yellow
        Write-CommandDuration -CommandName "adb connect" -DurationMs $sw.ElapsedMilliseconds
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

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)

    # Wait for exit or timeout (milliseconds)
    $hasExited = $proc.WaitForExit($timeoutMs)
    $sw.Stop()
    Write-CommandDuration -CommandName "scrcpy" -DurationMs $sw.ElapsedMilliseconds

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

# Connects to the device, handles mDNS discovery, and launches scrcpy with automatic retries
function Start-ScrcpySession {
    param(
        [string]$TargetHost = $deviceHost,
        [int]$MaxAttemptsCount = $maxAttempts
    )

    Ensure-AdbServer

    for ($attempt = 1; $attempt -le $MaxAttemptsCount; $attempt++) {
        if ($attempt -gt 1) {
            Write-Host "`n--- Retry attempt $attempt of $MaxAttemptsCount ---" -ForegroundColor Cyan
        }

        # Find endpoint (give mDNS first attempt timeout on first try, retry timeout after server restart)
        $mdnsWait = if ($attempt -eq 1) { $mdnsTimeoutFirstAttemptMs } else { $mdnsTimeoutRetryMs }
        $deviceIp = Find-DeviceEndpoint -MdnsTimeoutMs $mdnsWait

        # Verify connection status
        $isConnected = Test-DeviceConnection -Endpoint $deviceIp
        if (-not $isConnected) {
            $connectOk = Connect-AdbEndpoint -Endpoint $deviceIp -TimeoutMs $adbConnectTimeoutMs
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
        if ($attempt -lt $MaxAttemptsCount) {
            Write-Host "Connection attempt $attempt failed. Retrying..." -ForegroundColor Yellow
            Restart-AdbServer
            Start-Sleep -Milliseconds 150
        }
    }

    Write-Host "`nERROR: Could not establish a connection to $TargetHost after $MaxAttemptsCount attempts." -ForegroundColor Red
    Show-WirelessDebuggingHelp
    exit 1
}

# ==============================================================================
# Main Execution Flow
# ==============================================================================

# Verify network quality before proceeding (comment out this line to bypass ping test)
Test-DevicePing

# Connect, handle dynamic mDNS port discovery, and launch scrcpy with automatic retries
Start-ScrcpySession
