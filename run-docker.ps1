$ErrorActionPreference = 'Stop'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Install and start Docker Desktop (Linux containers) with Docker Compose.' }
$root = $PSScriptRoot
Push-Location -LiteralPath $root
try {
    & docker info --format '{{.ServerVersion}}'
    if ($LASTEXITCODE -ne 0) { throw 'Docker is not running. Start Docker and rerun.' }
    & docker compose version
    if ($LASTEXITCODE -ne 0) { throw 'Docker Compose v2.20+ is required.' }
    $compose = @('compose', '--project-name', 'smart-meeting', '--env-file', '.runtime/docker.env', '-f', 'compose.yaml')
    if ($args.Count -gt 0 -and $args[0] -eq '--stop') {
        & docker @compose down
    } elseif ($args.Count -gt 0 -and $args[0] -eq '--logs') {
        & docker @compose logs --follow
    } else {
        $mount = "type=bind,source=$root,target=/workspace"
        $hostRoot = $root.Replace('\', '/')
        & docker run --rm --mount $mount --workdir /workspace python:3.12-slim-bookworm python scripts/launcher.py docker-config --host-root $hostRoot @args
        if ($LASTEXITCODE -ne 0) { throw 'Configuration initialization failed.' }
        & docker @compose up --build --force-recreate --detach --wait --wait-timeout 180
        if ($LASTEXITCODE -ne 0) { throw 'Startup failed. Run .\run-docker.ps1 --logs to inspect service logs.' }
        & docker run --rm --mount $mount --workdir /workspace python:3.12-slim-bookworm python scripts/launcher.py docker-info
    }
    if ($LASTEXITCODE -ne 0) { throw 'Docker operation failed.' }
} finally {
    Pop-Location
}
