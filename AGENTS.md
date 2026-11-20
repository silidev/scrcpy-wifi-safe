# Agent Guide: scrcpy-wifi-safe

## Purpose
In AGENTS.md capture non-obvious knowledge that an AI agent cannot deduce on its own, e. g. domain knowledge, platform quirks, and knowledge discovered during troubleshooting. The goal is to minimize token cost and prevent regressions or trial-and-error debugging in future sessions if the chat history is unavailable.

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
- **Commit Message**: If any file was changed, when reporting to the user, include a commit message for the user to use for committing the changes.

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
   - **Fix**: Skip `kill-server` entirely and directly force-terminate via `Stop-Process -Name adb -Force -ErrorAction SilentlyContinue`. This immediately frees port 5037 and clears all socket state with zero latency.
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

All timeouts in `scrcpy-wifi-safe.ps1` are calibrated directly against the measurements above.
They are defined as **top-level variables** at the start of the script and can be overridden via environment variables without touching source code:

| Variable | Env-var override | Default | Rationale |
| :--- | :--- | :--- | :--- |
| `$timeoutMs` | `SCRCPY_TIMEOUT_MS` | **2000 ms** | Failed launches exit in < 400 ms. If running past 2000 ms, scrcpy is stable in background. |
| `$pingTimeoutMs` | `SCRCPY_PING_TIMEOUT_MS` | **2000 ms** | Generous ceiling for the .NET Ping API call. |
| `$adbStartServerTimeoutMs` | `SCRCPY_ADB_START_TIMEOUT_MS` | **5000 ms** | Safety margin for cold daemon startup under CPU load (returns immediately when started). |
| `$mdnsTimeoutFirstAttemptMs` | `SCRCPY_MDNS_TIMEOUT_FIRST_MS` | **1500 ms** | If daemon is already running, match is instant (< 200 ms). |
| `$mdnsTimeoutRetryMs` | `SCRCPY_MDNS_TIMEOUT_RETRY_MS` | **3500 ms** | Allows cold-started daemon to receive the multicast packet after server restart. |
| `$adbConnectTimeoutMs` | `SCRCPY_ADB_CONNECT_TIMEOUT_MS` | **3000 ms** | TCP RST takes 2580 ms to return error 10061. 3000 ms lets it report naturally, but cuts off silent packet drops before the 20+ s OS timeout. |
| `$durationRedThresholdMs` | `SCRCPY_DURATION_RED_MS` | **200 ms** | Duration display threshold: values above this are printed in red. |

Additional fixed timings (not configurable via env — they are low-level OS/socket constants):

| Setting / Location | Value | Rationale |
| :--- | :--- | :--- |
| `Invoke-Adb` default timeout | **2000 ms** | Local queries complete in < 150 ms; 2000 ms provides safety margin without blocking. |
| `Test-DeviceConnection` timeout | **1000 ms** | `get-state` takes ~130 ms; 1000 ms is plenty. |
| `Restart-AdbServer` kill method | `Stop-Process -Force` | Skips `kill-server`; instant force-kill guarantees no hang and frees port 5037 immediately. |
| `Restart-AdbServer` post-kill sleep | **100 ms** | Sufficient for Windows kernel socket cleanup. |
| `Restart-AdbServer` post-start sleep | **100 ms** | Buffer before issuing subsequent socket commands. |
| mDNS poll interval | **250 ms** | Captures the broadcast (~210 ms) on the 1st or 2nd cycle without CPU spin. |
| mDNS reverse scan | Reverse `-match` | Scans array backwards; captures newest port on 1st match with zero pipeline overhead. |
| Stale endpoint cleanup | Implicit via server restart | Killing the daemon clears all device sockets; explicit `adb disconnect` is redundant. |
| Delay between retries | **150 ms** | Eliminates dead waiting time before next attempt. |

---

## 6. Verification & Syntax Validation (Zero Side-Effects)

To validate PowerShell 7 script syntax and AST parsing without needing a physical phone connected or initiating network calls:

```powershell
pwsh -NoProfile -Command '$errs = @(); [void][System.Management.Automation.Language.Parser]::ParseFile("scrcpy-wifi-safe.ps1", [ref]$null, [ref]$errs); if ($errs.Count -gt 0) { $errs; exit 1 } else { "Syntax OK" }'
```

To run a safe dry-run through scrcpy's parameter validation without launching a full screen mirror:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scrcpy-wifi-safe.ps1 -v
```
