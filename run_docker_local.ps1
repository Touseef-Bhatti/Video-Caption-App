$ErrorActionPreference = "Stop"
Push-Location $PSScriptRoot
try {
    $configFile = Join-Path $PSScriptRoot "backend/.env"
    if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
        throw "Missing backend/.env. Copy backend/.env.example and configure the required local service keys first."
    }

    docker compose --env-file $configFile `
        -f docker-compose.yml `
        -f docker-compose.local.yml `
        up --build
    if ($LASTEXITCODE -ne 0) { throw "Could not start the Docker-only local stack." }
} finally {
    Pop-Location
}
