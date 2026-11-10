param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ScrcpyArgs
)

$deviceIp = "192.168.178.39:5555"
$scrcpyPath = "C:\progs\scrcpy\scrcpy.exe"

function Start-Scrcpy {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $scrcpyPath
    $psi.Arguments = $ScrcpyArgs -join " "
    $psi.UseShellExecute = $false

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
    
    $code = $proc.ExitCode
    Write-Host "scrcpy exit code: $code"
    return $code
}

$exitCode = Start-Scrcpy

if ($exitCode -ne 0) {
    Write-Host "Connection failed (exit code $exitCode). Retrying with adb connect..."
    adb connect $deviceIp
    $exitCode = Start-Scrcpy
    
    if ($exitCode -ne 0) {
        Write-Host "Still failing (exit code $exitCode). Restarting adb server..."
        adb kill-server
        adb connect $deviceIp
        Start-Scrcpy
    }
}