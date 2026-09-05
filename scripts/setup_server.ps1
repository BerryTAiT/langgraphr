# setup_server.ps1 - install the hidden server's Python dependencies.
#
# This is the ONLY manual Python step a developer ever runs, and it is
# optional when `uv` is installed (uv creates the environment on demand).

# Stop on the first error so a broken install is obvious.
$ErrorActionPreference = "Stop"

# The folder that contains this script (scripts/).
$PSScriptRootPath = Split-Path -Parent $MyInvocation.MyCommand.Path
# The repository root (one level above scripts/).
$root   = Split-Path -Parent $PSScriptRootPath
# The server bundle folder that holds the python sources.
$server = Join-Path $root "langgraphr\inst\server"

# Tell the user which folder we are setting up.
Write-Host "Setting up server bundle at: $server"

# Move into the server folder so relative commands work there.
Push-Location $server
try {
    # Prefer uv when it is installed: it creates .venv and installs deps.
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        # Announce which step we are on.
        Write-Host "[1/1] uv sync (creates .venv and installs dependencies)..."
        # uv reads pyproject.toml/requirements and resolves everything.
        uv sync
    }
    # Fall back to plain python when uv is missing.
    elseif (Get-Command python -ErrorAction SilentlyContinue) {
        # Announce the first step.
        Write-Host "[1/2] Creating venv with python..."
        # Create a fresh virtual environment in ./.venv.
        python -m venv .venv
        # Announce the second step.
        Write-Host "[2/2] Installing requirements..."
        # Use the venv's python to upgrade pip itself.
        & ".\.venv\Scripts\python.exe" -m pip install --upgrade pip
        # Use the venv's python to install the pinned requirements.
        & ".\.venv\Scripts\python.exe" -m pip install -r requirements.txt
    }
    # Neither uv nor python exists: stop with guidance.
    else {
        throw "Neither uv nor python was found. Install uv (https://docs.astral.sh/uv/) or Python >= 3.10."
    }
    # Tell the user the setup finished.
    Write-Host "Done. Server dependencies are ready."
}
finally {
    # Always return to the original working directory.
    Pop-Location
}
