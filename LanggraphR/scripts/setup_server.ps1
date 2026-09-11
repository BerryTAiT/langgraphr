# setup_server.ps1 - install the hidden server's Python dependencies.
#
# This is the ONLY manual Python step a developer ever runs, and it is
# optional when `uv` is installed (uv creates the environment on demand).
#
# Usage:
#   .\setup_server.ps1            # frozen versions from uv.lock (default)
#   .\setup_server.ps1 -Latest    # newest versions allowed by pyproject.toml

# Accept an optional -Latest switch that upgrades every dependency to the
# newest version allowed by the manifests, instead of the frozen lockfile.
param(
    [switch]$Latest
)

# Stop on the first error so a broken install is obvious.
$ErrorActionPreference = "Stop"

# The folder that contains this script (scripts/).
$PSScriptRootPath = Split-Path -Parent $MyInvocation.MyCommand.Path
# The repository root (one level above scripts/).
$root   = Split-Path -Parent $PSScriptRootPath
# The server bundle folder that holds the python sources.
$server = Join-Path $root "inst\server"

# Tell the user which folder we are setting up.
Write-Host "Setting up server bundle at: $server"

# Move into the server folder so relative commands work there.
Push-Location $server
try {
    # Prefer uv when it is installed: it creates .venv and installs deps.
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        # Choose the sync mode from the -Latest switch.
        if ($Latest) {
            # Announce that we are resolving the newest allowed versions.
            Write-Host "[1/1] uv sync --upgrade (newest versions allowed by pyproject.toml)..."
            # --upgrade re-resolves every dependency to its newest version
            # that still satisfies pyproject.toml, so a fresh LangGraph
            # release is picked up automatically.
            uv sync --upgrade
        }
        # Default path: install exactly the frozen, tested lockfile.
        else {
            # Announce which step we are on.
            Write-Host "[1/1] uv sync (frozen versions from uv.lock)..."
            # uv reads uv.lock and installs exactly those versions.
            uv sync
        }
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
        # Build the pip argument list; requirements.txt uses >= pins, so
        # plain installs already fetch the newest satisfying version, and
        # --upgrade (with -Latest) also bumps an existing venv.
        $pipArgs = @("-m", "pip", "install", "-r", "requirements.txt")
        # Add --upgrade when the caller asked for the latest versions.
        if ($Latest) { $pipArgs += "--upgrade" }
        # Use the venv's python to install the requirements.
        & ".\.venv\Scripts\python.exe" @pipArgs
    }
    # Neither uv nor python exists: stop with guidance.
    else {
        throw "Neither uv nor python was found. Install uv (https://docs.astral.sh/uv/) or Python >= 3.10."
    }
    # Report which engine version the environment actually received, so an
    # upgrade is visible immediately (uv and pip both land in ./.venv).
    if (Test-Path ".\.venv\Scripts\python.exe") {
        & ".\.venv\Scripts\python.exe" -c "from importlib.metadata import version; print('langgraph engine version:', version('langgraph'))"
    }
    # Tell the user the setup finished.
    Write-Host "Done. Server dependencies are ready."
}
finally {
    # Always return to the original working directory.
    Pop-Location
}
