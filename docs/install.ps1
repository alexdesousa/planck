$ErrorActionPreference = "Stop"

$Repo    = "alexdesousa/planck"
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

Write-Host "Installed planck to $Dest"
Write-Host "Restart your terminal, then run: planck"
