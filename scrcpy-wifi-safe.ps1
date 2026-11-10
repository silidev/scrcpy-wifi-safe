param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ScrcpyArgs
)

# This starts scrcpy but if that fails it kill the adb server and adb connects again and then starts scrcpy.

# Configuration
$deviceIp = "192.168.178.39:5555"
$scrcpyPath = "C:\progs\scrcpy\scrcpy.exe"
Set-Variable -Name TIMEOUT_SECONDS -Value 5 -Option Constant

function Start-ScrcpyProcess {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $scrcpyPath
    $psi.Arguments = $ScrcpyArgs -join " "
    $psi.UseShellExecute = $false

    $proc = [System.Diagnostics.Process]::Start($psi)
    
    # Wait for exit or timeout (milliseconds)
    $hasExited = $proc.WaitForExit($TIMEOUT_SECONDS * 1000)

    if (-not $hasExited) {
        # Process is still running after timeout -> successful connection running in background
        Write-Host "scrcpy launched successfully and running in background."
        return 0
    }

    # Process exited within timeout period -> evaluation of exit code
    $code = $proc.ExitCode
    Write-Host "scrcpy exited within threshold (exit code: $code)"
    return $code
}

$exitCode = Start-ScrcpyProcess

if ($exitCode -ne 0) {
    Write-Host "Connection failed. Retrying with adb connect..."
    adb connect $deviceIp
    $exitCode = Start-ScrcpyProcess
    
    if ($exitCode -ne 0) {
        Write-Host "Still failing. Restarting adb server..."
        adb kill-server
        adb connect $deviceIp
        [void](Start-ScrcpyProcess)
    }
}