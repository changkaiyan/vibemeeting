$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (Test-Path -LiteralPath "$root\.venv\Scripts\python.exe") {
    & "$root\.venv\Scripts\python.exe" "$root\scripts\launcher.py" local @args
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    & py -3 "$root\scripts\launcher.py" local @args
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    & python "$root\scripts\launcher.py" local @args
} else {
    throw 'Install Python 3.10+ and Git, then rerun this script. Docker is required for recording.'
}
exit $LASTEXITCODE
