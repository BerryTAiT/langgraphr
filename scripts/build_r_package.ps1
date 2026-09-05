# build_r_package.ps1 - build and install the langgraphr R package.
#
# Runs the standard R toolchain. After this, `library(langgraphr)` works.

# Stop on errors.
$ErrorActionPreference = "Stop"

# Rscript must exist on the PATH for this script to work.
if (-not (Get-Command Rscript -ErrorAction SilentlyContinue)) {
    # Guide the user to install R first.
    Write-Host "Rscript not found. Install R from https://cran.r-project.org and retry."
    exit 1
}

# R.exe lives in the same bin folder as Rscript.exe.
$Rbin = Split-Path -Parent (Get-Command Rscript).Source
# The full path to R.exe.
$Rexe = Join-Path $Rbin "R.exe"
# The repository root (one level above scripts/).
$root = Split-Path -Parent $PSScriptRoot
# The R package source folder.
$pkg  = Join-Path $root "langgraphr"

# Announce the build step.
Write-Host "==> R CMD build"
# Build the source tarball next to the package (output in $root).
& $Rexe CMD build --no-build-vignettes $pkg

# Find the newest tarball the build produced.
$tarball = Get-ChildItem -Path $root -Filter "langgraphr_*.tar.gz" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
# If no tarball appeared the build failed silently.
if ($null -eq $tarball) {
    throw "Build produced no tarball in $root"
}

# Announce the install step.
Write-Host "==> R CMD INSTALL $($tarball.Name)"
# Install the built package into the user's R library.
& $Rexe CMD INSTALL $tarball.FullName

# Tell the user it worked and how to use the package.
Write-Host "Done. Try in R:  library(langgraphr)"
