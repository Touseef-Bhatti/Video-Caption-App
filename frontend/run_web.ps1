param(
    [int]$Port = 9000,
    [string]$ApiBaseUrl = "http://localhost:8000"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw "Flutter was not found on PATH. Install Flutter 3.27+ and reopen PowerShell."
}

$listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
if ($listeners.Count -gt 0) {
    $processIds = ($listeners | Select-Object -ExpandProperty OwningProcess -Unique) -join ", "
    throw "Port $Port is already in use by process ID(s) $processIds. Stop that process, then run this script again."
}

Push-Location $PSScriptRoot
try {
    # Recreate Flutter's generated web entrypoint on every clean startup so
    # the dev server never falls back to index.html for a stale/missing JS file.
    flutter clean
    if ($LASTEXITCODE -ne 0) { throw "flutter clean failed (exit code $LASTEXITCODE)." }

    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed (exit code $LASTEXITCODE)." }

    flutter run -d chrome "--web-port=$Port" "--dart-define=API_BASE_URL=$ApiBaseUrl"
    if ($LASTEXITCODE -ne 0) { throw "flutter run failed (exit code $LASTEXITCODE)." }
}
finally {
    Pop-Location
}
