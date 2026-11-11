param(
    [string]$ConfigFile = "backend/.env",
    [string]$AppName = "video-caption-app",
    [string]$SecretName = "caption-app-config",
    [ValidateSet("auto", "L4", "L40S", "A10", "T4", "none")]
    [string]$RenderGpu = "auto"
)

$ErrorActionPreference = "Stop"
Push-Location $PSScriptRoot
try {
    # Modal prints Unicode status symbols even in a redirected Windows shell.
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"
    $deployPython = Join-Path $PSScriptRoot ".venv-modal/Scripts/python.exe"
    if (-not (Test-Path -LiteralPath $deployPython)) {
        python -m venv .venv-modal
        if ($LASTEXITCODE -ne 0) { throw "Could not create the deployment environment." }
    }
    & $deployPython -m pip install --quiet --disable-pip-version-check -r requirements-modal.txt
    if ($LASTEXITCODE -ne 0) { throw "Could not install the Modal CLI." }
    if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "Configuration file does not exist: $ConfigFile" }

    $env:MODAL_APP_NAME = $AppName
    $env:MODAL_CONFIG_SECRET = $SecretName
    $env:MODAL_RENDER_GPU = $RenderGpu

    # The CLI reads this file directly; credentials never enter command text.
    & $deployPython -m modal secret create $SecretName --from-dotenv $ConfigFile --force
    if ($LASTEXITCODE -ne 0) {
        throw "Could not configure Modal Secrets. Sign in with: .\.venv-modal\Scripts\python.exe -m modal token new"
    }
    & $deployPython -m modal run modal_app.py::migrate
    if ($LASTEXITCODE -ne 0) { throw "Database migration failed; deployment stopped." }
    & $deployPython -m modal deploy modal_app.py
    if ($LASTEXITCODE -ne 0) { throw "Modal deployment failed." }
    Write-Host "Deployment complete. Open the web URL printed by Modal above."
} finally {
    Pop-Location
}
