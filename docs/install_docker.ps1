<#
.SYNOPSIS
    Install Planck (Docker Compose stack) on Windows.
.PARAMETER Bind
    IP address to bind Planck to (default: 127.0.0.1).
    Set to 0.0.0.0 to expose on the network (not recommended without a firewall).
.EXAMPLE
    irm https://raw.githubusercontent.com/alexdesousa/planck/main/docs/install_docker.ps1 | iex
.EXAMPLE
    .\install_docker.ps1 -Bind 0.0.0.0
#>
[CmdletBinding()]
param(
    [string]$Bind = "127.0.0.1"
)

$ErrorActionPreference = "Stop"

$Repo        = "alexdesousa/planck"
$Version     = "0.1.6"
$PlanckHome  = Join-Path $HOME "planck"
$ComposeUrl  = "https://raw.githubusercontent.com/$Repo/v$Version/planck_docker/compose.yml"
$ComposeFile = Join-Path $PlanckHome "compose.yml"
$EnvFile     = Join-Path $PlanckHome ".env"

function Invoke-Compose {
    & $script:Compose @args
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# ── Check Docker ──────────────────────────────────────────────────────────────
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "Docker is not installed."
    Write-Host "Install Docker Desktop: https://docs.docker.com/desktop/install/windows-install/"
    exit 1
}

docker info 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker daemon is not running. Start Docker Desktop and try again."
    exit 1
}

docker compose version 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    $script:Compose = @("docker", "compose")
} elseif (Get-Command docker-compose -ErrorAction SilentlyContinue) {
    $script:Compose = @("docker-compose")
} else {
    Write-Host "Neither 'docker compose' nor 'docker-compose' found."
    Write-Host "Install Docker Compose: https://docs.docker.com/compose/install/"
    exit 1
}

# ── Create directory layout ───────────────────────────────────────────────────
Write-Host "Setting up $PlanckHome..."
foreach ($dir in "typesense-data", "workspace\.planck") {
    New-Item -ItemType Directory -Force -Path (Join-Path $PlanckHome $dir) | Out-Null
}

# ── Write .env — create if absent, add missing keys if it exists ──────────────
$rng    = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$bytes  = [byte[]]::new(24)
$rng.GetBytes($bytes)
$secret = ([Convert]::ToBase64String($bytes)) -replace '[=+/]'
$secret = $secret.Substring(0, [Math]::Min(32, $secret.Length))

function Add-IfMissing([string]$Key, [string]$Value) {
    if (-not (Select-String -Quiet -Path $EnvFile -Pattern "^$Key=")) {
        Add-Content -Path $EnvFile -Value "$Key=$Value"
    }
}

if (-not (Test-Path $EnvFile)) {
    Write-Host "Writing $EnvFile..."
    @"
PLANCK_HOME=$PlanckHome
TYPESENSE_API_KEY=planck-internal-key
PLANCK_BIND_ADDRESS=$Bind
SEARXNG_SECRET=$secret
SEARXNG_LANGUAGE=en
"@ | Set-Content -Path $EnvFile
    Write-Host "  -> $EnvFile created. Edit SEARXNG_LANGUAGE to change the search language."
} else {
    Write-Host "  -> $EnvFile exists — adding any missing keys..."
    Add-IfMissing "PLANCK_HOME" $PlanckHome
    Add-IfMissing "TYPESENSE_API_KEY" "planck-internal-key"
    Add-IfMissing "PLANCK_BIND_ADDRESS" $Bind
    Add-IfMissing "SEARXNG_SECRET" $secret
    Add-IfMissing "SEARXNG_LANGUAGE" "en"
}

# ── Download compose.yml ──────────────────────────────────────────────────────
Write-Host "Downloading compose.yml..."
Invoke-WebRequest -Uri $ComposeUrl -OutFile $ComposeFile -UseBasicParsing

# ── Export PLANCK_HOME so compose.yml volume paths resolve correctly ──────────
$env:PLANCK_HOME = $PlanckHome

# ── Pull images ───────────────────────────────────────────────────────────────
Write-Host "Pulling Docker images..."
Invoke-Compose -f "$ComposeFile" --env-file "$EnvFile" pull

# ── Run setup container ───────────────────────────────────────────────────────
Write-Host "Running first-run setup..."
Invoke-Compose -f "$ComposeFile" --env-file "$EnvFile" run --rm setup

# ── Start services ────────────────────────────────────────────────────────────
Write-Host "Starting Planck..."
Invoke-Compose -f "$ComposeFile" --env-file "$EnvFile" up -d

Write-Host ""
Write-Host "Planck is running at http://localhost:4000"
Write-Host "Open it in your browser and follow the setup wizard to configure a provider."
