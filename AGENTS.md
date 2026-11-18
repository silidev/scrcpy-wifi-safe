# Agent Guide: scrcpy-wifi-safe

## Purpose
In AGENTS.md capture non-obvious knowledge, that an AI agent cannot deduce on its own, e. g. domain knowledge, platform quirks, and knowledge discovered during troubleshooting . The goal is to minimize token cost and prevent regressions or trial-and-error debugging in future sessions if the chat history is unavailable.

---

## 1. Operating Rules & Constraints

- **Language**: Always communicate strictly in English (in chat responses, code, comments, and commit messages), even if the user communicates in another language (e.g. German).
- **Explicit Order Only**: Do NOT modify production code (`scrcpy-wifi-safe.ps1`, `scrcpy-koh.cmd`) without explicit user instruction.
- **Ambiguity & No "Creative" Interpretations**: If a request can be interpreted in multiple ways, do NOT edit files. Halt, report, and ask for clarification.
- **Mismatched Request**: If a user request seems mismatched with this application/project (e.g. references to web/React/DOM entities), do NOT change any file; report the mismatch instead.
- **Contradictions & Problems**: You MUST proactively inform the user if there are any contradictions, incompatibilities, or issues with orders before proceeding.
- **Keep it Simple**: Keep the script minimal, lean, and fast. Avoid unnecessary abstractions.
- **Preserve CLI & Output Contract**: Do not alter CLI parameters (`$ScrcpyArgs`, `%*`), window flags, or console behavior unless explicitly ordered.
- **Diagnostics First**: If an error cannot be resolved with certainty, improve logging/diagnostics to expose what failed rather than guessing changes.
- **Missing References**: Never remove or rewrite code referencing missing external tools/entities; report them first.

---

## 2. Environment & Architecture

- **Runtime Requirement**: **PowerShell 7 (`pwsh`) ONLY**. Do not invoke or fall back to Windows PowerShell 5.1 (`powershell.exe`).
- **Call Chain**:
  `s.cmd` (`L:\Dropbox\shimsDbx\s.cmd`)  
  └─> `scrcpy-koh.cmd` (`L:\Dropbox\MyScripts\scrcpy-wifi-safe\scrcpy-koh.cmd`)  
  └─> `scrcpy-wifi-safe.ps1` (`pwsh -ExecutionPolicy Bypass -File ...`)
- **Target Device**: IP configurable via `$env:SCRCPY_DEVICE_IP`
- **Connection Type**: Android 11+ Wireless Debugging (`_adb-tls-connect._tcp.`). The phone assigns **random dynamic ports** (e.g. `35223`, `38177`, `40261`) on each reconnect / toggle. Port 5555 is only a legacy fallback.

---

## 3. Critical Gotchas & Root Causes of Freezes

1. **`adb kill-server` indefinite hang**:
   - On Windows, `adb kill-server` hangs indefinitely if the daemon is stuck waiting on a dead or half-closed TCP socket.
   - **Fix**: Attempt graceful `kill-server` with a short timeout (800 ms), then unconditionally force-terminate via `Stop-Process -Name adb -Force -ErrorAction SilentlyContinue`.
2. **mDNS discovery delay after daemon restart**:
   - Killing the ADB server clears its local mDNS cache.
   - When the daemon restarts, discovering the phone's dynamic port via multicast DNS takes 200–500 ms (measured). A single query immediately after startup returns empty; polling with a small backoff is required.
3. **PowerShell .NET threadpool crashes**:
   - Direct `.add_OutputDataReceived({ ... })` event handlers run on .NET threadpool threads. Any unhandled exception (or missing `$EventArgs`) instantly crashes the host process with exit code 1.
   - **Fix**: Use `[System.Diagnostics.Process]` with async tasks (`ReadToEndAsync()`) and `[System.Threading.Tasks.Task]::WaitAll(..., 300)`.

---

## 4. Empirical Latency Measurements

Measured on the local Windows machine with active Samsung device:

| Action / Command | Measured Duration | Notes |
| :--- | :--- | :--- |
| `adb devices` | ~144 ms | Local daemon query |
| `adb -s <endpoint> get-state` | ~130 ms | Local daemon query |
| `adb mdns services` (cached) | ~102 ms | Returns list immediately |
| `adb mdns services` (fresh daemon) | ~210 ms | Time to catch first multicast broadcast |
| `adb connect <dead/refused port>` | **2587 ms** (~2.6 s) | Target actively sends TCP RST (WSAECONNREFUSED / 10061) |
| `adb start-server` (cold start) | ~2400 ms | Spawns fork-server daemon on tcp:5037 |
| `scrcpy` failure on bad connection | ~400 ms | Pushes server jar, fails stream, exits immediately |
| `scrcpy` successful connection | ~1.0–1.5 s | Handshake, Direct3D11 surface init, stays open |

---

## 5. Derived Timeouts & Rationale

All timeouts in `scrcpy-wifi-safe.ps1` are calibrated directly against the measurements above:

| Setting / Location | Value | Rationale |
| :--- | :--- | :--- |
| `TIMEOUT_SECONDS` (scrcpy launch) | **2 s** | Failed launches exit in < 400 ms. If running past 2 s, scrcpy is stable in background. |
| `Invoke-Adb` default timeout | **2.0 s** | Local queries complete in < 150 ms; 2 s provides safety margin without blocking. |
| `Test-DeviceConnection` | **1.0 s** | `get-state` takes ~130 ms; 1 s is plenty. |
| `Connect-AdbEndpoint` timeout | **3.0 s** | TCP RST takes 2.58 s to return error 10061. 3.0 s lets it report naturally, but cuts off silent packet drops before the 20+ s OS timeout. |
| `Restart-AdbServer` kill wait | **800 ms** | If daemon does not die in 800 ms, it is wedged; force-kill fires immediately. |
| `Restart-AdbServer` post-kill sleep | **100 ms** | Sufficient for Windows kernel socket cleanup. |
| `Restart-AdbServer` start wait | **3000 ms** | Covers cold daemon startup (~2.4 s). |
| `Restart-AdbServer` post-start sleep| **200 ms** | Buffer before issuing subsequent socket commands. |
| mDNS poll interval | **250 ms** | Captures the broadcast (~210 ms) on the 1st or 2nd cycle without CPU spin. |
| mDNS timeout (Attempt 1) | **1.5 s** | If daemon is already running, match is instant (< 200 ms). |
| mDNS timeout (Attempts 2–3) | **3.5 s** | Allows cold-started daemon to receive the multicast packet. |
| Stale endpoint cleanup | `adb disconnect` (1 s) | Removes dead ports from `adb devices` cache before retry. |
| Delay between retries | **200 ms** | Eliminates dead waiting time before next attempt. |
