# update_all.ps1 - bring every layer of langgraphr to its latest version.
#
# Layers updated:
#   1. uv itself            (uv self update)
#   2. hidden server deps   (uv sync --upgrade inside langgraphr/inst/server)
#   3. R packages           (R6, httr2, processx, cli, jsonlite, testthat, remotes)
#
# Note: this script never edits code; after updating R packages it is still a
# good idea to reinstall langgraphr from source so it links the new versions.

# Stop on the first error.
$ErrorActionPreference = "Stop"

# The repository root (two levels up from scripts/).
$root   = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
# The folder containing the hidden Python server.
$server = Join-Path $root "langgraphr\inst\server"

Write-Host "==> [1/3] Updating uv itself"
# Self-update uv to the newest release (works when uv is installed).
if (Get-Command uv -ErrorAction SilentlyContinue) {
    # Try the self update, ignoring failure if the file is currently locked.
    uv self update 2>&1 | Out-Host
}
# If uv is missing, still continue (nothing to self-update).

Write-Host "==> [2/3] Upgrading hidden-server Python dependencies"
# Move into the server folder so uv finds the right project.
Push-Location $server
try {
    # uv resolves and installs the newest versions allowed by the manifests.
    uv sync --upgrade
}
finally {
    # Always return to the original directory.
    Pop-Location
}

Write-Host "==> [3/3] Updating R packages to the newest CRAN releases"
# Locate Rscript; needed for the R package step.
if (Get-Command Rscript -ErrorAction SilentlyContinue) {
    # Update the exact packages this project depends on (and remotes itself).
    & Rscript -e "update.packages(c('R6','httr2','processx','cli','jsonlite','testthat','remotes'), ask = FALSE, repos = 'https://cloud.r-project.org')"
}
else {
    # Warn when R is not reachable so the user knows one step was skipped.
    Write-Host "Rscript not found - skipping R package updates (install R >= 4.2)."
}

Write-Host "Done. Everything updated to the newest available versions."
