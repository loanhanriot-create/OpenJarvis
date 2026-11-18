# Finish a Windows OpenJarvis install WITHOUT the optional Rust extension.
#
# Use this when the official installer stops at "uv sync failed" while
# compiling openjarvis-rust. Chat, the API server and messaging channels work
# without it; only the Rust-accelerated memory/security features are missing.
#
# Usage (PowerShell):
#   irm <raw URL of this file> | iex

$ErrorActionPreference = 'Stop'

function Stop-Setup($msg) {
    Write-Host "[echec] $msg" -ForegroundColor Red
    throw $msg
}
function Write-Step($msg) { Write-Host ""; Write-Host "=== $msg ===" -ForegroundColor Cyan }

$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path', 'User') + ';' +
            (Join-Path $env:USERPROFILE '.local\bin')

$installRoot = if ($env:OPENJARVIS_HOME) { $env:OPENJARVIS_HOME } else { Join-Path $env:LOCALAPPDATA 'OpenJarvis' }
$srcDir = Join-Path $installRoot 'src'
if (-not (Test-Path (Join-Path $srcDir 'pyproject.toml'))) {
    Stop-Setup "Code OpenJarvis introuvable dans $srcDir. Lance d'abord l'installateur officiel."
}
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Stop-Setup "'uv' introuvable. Ferme PowerShell, rouvre-le et relance ce script."
}

# 1. Python packages, without the Rust extension group --------------------
Write-Step "1/4 Installation des modules Python (sans l'extension Rust)"
& uv sync --project $srcDir --extra desktop
if ($LASTEXITCODE -ne 0) { Stop-Setup "uv sync a echoue. Envoie une capture de l'erreur au-dessus." }
& uv pip install --python (Join-Path $srcDir '.venv\Scripts\python.exe') "python-telegram-bot>=21.0" -q
Write-Host "OK" -ForegroundColor Green

# 2. Ollama -------------------------------------------------------------------
Write-Step "2/4 Ollama (moteur qui fait tourner l'IA)"
$ollama = (Get-Command ollama -ErrorAction SilentlyContinue).Source
if (-not $ollama) {
    Write-Host "Installation d'Ollama (~150 Mo)..."
    & winget install -e --id Ollama.Ollama --accept-package-agreements --accept-source-agreements
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $ollama = (Get-Command ollama -ErrorAction SilentlyContinue).Source
    if (-not $ollama) {
        $candidate = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
        if (Test-Path $candidate) { $ollama = $candidate }
    }
    if (-not $ollama) { Stop-Setup "Ollama installe mais introuvable. Ferme et rouvre PowerShell puis relance ce script." }
}
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    try { Invoke-RestMethod 'http://127.0.0.1:11434/api/version' -TimeoutSec 2 | Out-Null; $ready = $true; break } catch { }
    if ($i -eq 2) { Start-Process -FilePath $ollama -ArgumentList 'serve' -WindowStyle Hidden }
    Start-Sleep -Seconds 1
}
if (-not $ready) { Stop-Setup "Ollama ne demarre pas. Lance l'application Ollama depuis le menu Demarrer puis relance ce script." }
Write-Host "OK ($ollama)" -ForegroundColor Green

# 3. Starter model ------------------------------------------------------------
Write-Step "3/4 Telechargement du modele qwen3.5:2b (~1,5 Go)"
& $ollama pull 'qwen3.5:2b'
if ($LASTEXITCODE -ne 0) { Stop-Setup "Telechargement du modele impossible. Verifie ta connexion et relance." }
Write-Host "OK" -ForegroundColor Green

# 4. jarvis command + config ---------------------------------------------------
Write-Step "4/4 Commande 'jarvis' et configuration"
$binDir = Join-Path $installRoot 'bin'
New-Item -ItemType Directory -Path $binDir -Force | Out-Null
Set-Content -Path (Join-Path $binDir 'jarvis.cmd') -Encoding ASCII -Value @"
@echo off
setlocal
set "SRC=%~dp0..\src"
uv run --project "%SRC%" jarvis %*
"@
$userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
$onPath = $false
foreach ($entry in ("$userPath" -split ';')) {
    if ([System.Environment]::ExpandEnvironmentVariables($entry) -ieq $binDir) { $onPath = $true }
}
if (-not $onPath) {
    $newPath = if ($userPath) { "$userPath;$binDir" } else { $binDir }
    [System.Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
}

$configPath = Join-Path $env:USERPROFILE '.openjarvis\config.toml'
if (-not (Test-Path $configPath)) {
    & uv run --project $srcDir jarvis init --engine ollama --no-download --no-scan --no-analytics --force
}
$env:OJ_CONFIG = $configPath
$pyFile = Join-Path $env:TEMP 'oj-config-edit.py'
Set-Content -Path $pyFile -Encoding ASCII -Value @'
import os, tomlkit
path = os.environ["OJ_CONFIG"]
with open(path, encoding="utf-8") as f:
    doc = tomlkit.parse(f.read())
doc.setdefault("engine", tomlkit.table())["default"] = "ollama"
doc.setdefault("intelligence", tomlkit.table())["default_model"] = "qwen3.5:2b"
with open(path, "w", encoding="utf-8") as f:
    f.write(tomlkit.dumps(doc))
'@
# Run from a file: Windows PowerShell strips double quotes from native-command args.
& uv run --project $srcDir python $pyFile
if ($LASTEXITCODE -ne 0) { Stop-Setup "Mise a jour de la configuration impossible." }
Remove-Item $pyFile, Env:OJ_CONFIG -ErrorAction SilentlyContinue
Write-Host "OK" -ForegroundColor Green

Write-Host ""
Write-Host "Test rapide de Jarvis..." -ForegroundColor Cyan
& uv run --project $srcDir jarvis ask "Reponds juste: bonjour"

Write-Host ""
Write-Host "Installation terminee !" -ForegroundColor Green
Write-Host "Prochaine etape : brancher Telegram (voir les instructions de Claude)."
