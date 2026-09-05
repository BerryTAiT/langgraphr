# scripts/run_server_dev.ps1

<!-- TARGET: scripts/run_server_dev.ps1 -->

> Run the hidden server in the FOREGROUND for debugging (logs visible).
> Normal users never need this: the R package spawns the server itself.

```powershell
# run_server_dev.ps1 - start the langgraphr server in the foreground.
#
# Development/debugging aid. The R package normally starts this process
# invisibly through lg_start_server(); this script is for watching logs.

# Stop on errors.
$ErrorActionPreference = "Stop"

# Resolve the repository root from this script's location.
$root   = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
# The server bundle folder that contains app.py.
$server = Join-Path $root "langgraphr\inst\server"
# The port to listen on (first argument, default 8123).
$port   = if ($args.Count -gt 0) { $args[0] } else { "8123" }

# The venv must exist before we can run the server this way.
if (-not (Test-Path (Join-Path $server ".venv"))) {
    # Guide the user to the one-time setup script.
    Write-Host "Server venv missing - run scripts/setup_server.ps1 first."
    exit 1
}

# Move into the server folder (imports need the current directory there).
Push-Location $server
try {
    # Prefer uv when it is installed.
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        # uv run executes inside the project venv with hot reload enabled.
        uv run uvicorn app:app --host 127.0.0.1 --port $port --reload
    }
    else {
        # Fall back to calling uvicorn with the venv's python directly.
        & ".\.venv\Scripts\python.exe" -m uvicorn app:app --host 127.0.0.1 --port $port --reload
    }
}
finally {
    # Always return to the original working directory.
    Pop-Location
}
```
