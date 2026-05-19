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
$Version     = "0.1.4"
$Base        = "https://github.com/$Repo/releases/download/planck-docker/v$Version"
$PlanckHome  = Join-Path $HOME "planck"
$ComposeUrl  = "$Base/compose.yml"
$ComposeFile = Join-Path $PlanckHome "compose.yml"
$EnvFile     = Join-Path $PlanckHome ".env"

function Invoke-Docker {
    docker @args
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

# ── Create directory layout ───────────────────────────────────────────────────
Write-Host "Setting up $PlanckHome..."
foreach ($dir in "models", "typesense-data", "workspace\.planck") {
    New-Item -ItemType Directory -Force -Path (Join-Path $PlanckHome $dir) | Out-Null
}

# ── Write .env (skip if present) ─────────────────────────────────────────────
if (-not (Test-Path $EnvFile)) {
    Write-Host "Writing $EnvFile..."
    $rng    = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes  = [byte[]]::new(24)
    $rng.GetBytes($bytes)
    $secret = ([Convert]::ToBase64String($bytes)) -replace '[=+/]'
    $secret = $secret.Substring(0, [Math]::Min(32, $secret.Length))

    @"
TYPESENSE_API_KEY=planck-internal-key
PLANCK_BIND_ADDRESS=$Bind
SEARXNG_SECRET=$secret
SEARXNG_LANGUAGE=en
"@ | Set-Content -Path $EnvFile
    Write-Host "  -> $EnvFile created. Edit SEARXNG_LANGUAGE to change the search language."
} else {
    Write-Host "  -> $EnvFile already exists, skipping."
}

# ── Download model ────────────────────────────────────────────────────────────
$Model     = "Bonsai-8B-Q1_0.gguf"
$ModelPath = Join-Path $PlanckHome "models\$Model"
$ModelUrl  = "https://huggingface.co/prism-ml/Bonsai-8B-gguf/resolve/main/$Model"

if (-not (Test-Path $ModelPath)) {
    Write-Host "Downloading Bonsai model (1.16 GB)..."
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($ModelUrl, $ModelPath)
} else {
    Write-Host "  -> Model already downloaded, skipping."
}

# ── Download compose.yml ──────────────────────────────────────────────────────
if (-not (Test-Path $ComposeFile)) {
    Write-Host "Downloading compose.yml..."
    Invoke-WebRequest -Uri $ComposeUrl -OutFile $ComposeFile -UseBasicParsing
} else {
    Write-Host "  -> compose.yml already exists, skipping."
}

# ── Export PLANCK_HOME so compose.yml volume paths resolve correctly ──────────
$env:PLANCK_HOME = $PlanckHome

# ── Pull images ───────────────────────────────────────────────────────────────
Write-Host "Pulling Docker images..."
Invoke-Docker compose -f "$ComposeFile" --env-file "$EnvFile" pull

# ── Run setup container ───────────────────────────────────────────────────────
Write-Host "Running first-run setup..."
Invoke-Docker compose -f "$ComposeFile" --env-file "$EnvFile" run --rm setup

# ── Start services ────────────────────────────────────────────────────────────
Write-Host "Starting Planck..."
Invoke-Docker compose -f "$ComposeFile" --env-file "$EnvFile" up -d

Write-Host ""
Write-Host "Planck is running at http://localhost:4000"
Write-Host "(Bonsai model may take 30-60 s to load on first start)"
