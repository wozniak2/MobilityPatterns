# Thin launcher for scripts/00_run_pipeline.R -- see that file for what it
# actually does and for the --force flag. Exists so the whole pipeline can be
# started with one command/double-click instead of remembering the Rscript
# path and script location.
#
# Usage:
#   .\run_pipeline.ps1
#   .\run_pipeline.ps1 -Force

param(
    [switch]$Force
)

$rscript = "C:\Program Files\R\R-4.4.1\bin\Rscript.exe"
$script  = Join-Path $PSScriptRoot "scripts\00_run_pipeline.R"

if ($Force) {
    & $rscript $script --force
} else {
    & $rscript $script
}

exit $LASTEXITCODE
