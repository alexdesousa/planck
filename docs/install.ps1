$ErrorActionPreference = "Stop"

$Repo    = "alexdesousa/planck"
$Version = "0.1.10"
$Asset   = "planck_windows.exe"
$Url     = "https://github.com/$Repo/releases/latest/download/$Asset"
$BinDir  = "$Home\.planck\bin"
$Dest    = "$BinDir\planck.exe"

if (-not (Test-Path $BinDir)) {
    New-Item -ItemType Directory -Path $BinDir | Out-Null
}

Write-Host "Downloading planck..."

if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
    curl.exe -fsSL $Url -o $Dest
} else {
    Invoke-WebRequest -Uri $Url -OutFile $Dest
}

# Add to PATH if not already present
$CurrentPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
if ($CurrentPath -notlike "*$BinDir*") {
    [System.Environment]::SetEnvironmentVariable("PATH", "$CurrentPath;$BinDir", "User")
    $Env:PATH = "$Env:PATH;$BinDir"
    Write-Host "Added $BinDir to PATH"
}

# ── Install planck_setup skill ────────────────────────────────────────────────
$SkillBase   = "$Home\.planck\skills"
$ZipUrl      = "https://github.com/$Repo/archive/refs/tags/v$Version.zip"
$ZipTemp     = [System.IO.Path]::GetTempFileName() + ".zip"
$ExtractTemp = [System.IO.Path]::GetTempPath() + "planck_skill_extract"

if (-not (Test-Path $SkillBase)) {
    New-Item -ItemType Directory -Path $SkillBase | Out-Null
}

Write-Host "Installing planck_setup skill..."
try {
    Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipTemp -UseBasicParsing
    Expand-Archive -Path $ZipTemp -DestinationPath $ExtractTemp -Force
    $SkillSrc = Join-Path $ExtractTemp "planck-$Version\skills\planck_setup"
    Copy-Item -Path $SkillSrc -Destination $SkillBase -Recurse -Force
} catch {
    Write-Host "Warning: could not install planck_setup skill"
} finally {
    Remove-Item $ZipTemp -ErrorAction SilentlyContinue
    Remove-Item $ExtractTemp -Recurse -ErrorAction SilentlyContinue
}

Write-Host "Installed planck to $Dest"
Write-Host "Restart your terminal, then run: planck"
