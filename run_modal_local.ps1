$ErrorActionPreference = "Stop"
Push-Location $PSScriptRoot
try {
    $configFile = Join-Path $PSScriptRoot "backend/.env"
    $modalTokenFile = Join-Path $env:USERPROFILE ".modal.toml"

    if (-not (Test-Path -LiteralPath $configFile)) {
        throw "Missing backend/.env. Configure the shared database, storage, and app secrets first."
    }
    $databaseEntry = Get-Content -LiteralPath $configFile | Where-Object { $_ -match '^DATABASE_URL=' } | Select-Object -First 1
    if (-not $databaseEntry) {
        throw "DATABASE_URL is missing from backend/.env."
    }
    $databaseUrl = $databaseEntry.Substring("DATABASE_URL=".Length).Trim('"', "'")
    try { $databaseHost = ([Uri]$databaseUrl).DnsSafeHost } catch {
        throw "DATABASE_URL in backend/.env is not a valid database URL."
    }
    if (-not $databaseHost.EndsWith(".supabase.com", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Use the shared Supabase DATABASE_URL for both the localhost API and Modal workers."
    }
    if (-not (Test-Path -LiteralPath $modalTokenFile -PathType Leaf)) {
        throw "Modal credentials were not found at $modalTokenFile. Sign in with .\.venv-modal\Scripts\python.exe -m modal token new."
    }

    docker compose --env-file $configFile `
        -f docker-compose.yml `
        -f docker-compose.local.yml `
        -f docker-compose.modal-local.yml `
        up --build backend
    if ($LASTEXITCODE -ne 0) { throw "Could not start the localhost API with Modal workers." }
} finally {
    Pop-Location
}
