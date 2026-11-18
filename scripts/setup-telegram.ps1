# Connect an installed OpenJarvis (Windows) to a Telegram bot so you can chat from your phone.
#
# Prerequisite: OpenJarvis installed with the official Windows installer:
#   irm https://open-jarvis.github.io/OpenJarvis/install.ps1 | iex
#
# Usage (PowerShell):
#   irm <raw URL of this file> | iex

$ErrorActionPreference = 'Stop'

function Stop-Setup($msg) {
    Write-Host $msg -ForegroundColor Red
    throw $msg
}

$installRoot = if ($env:OPENJARVIS_HOME) { $env:OPENJARVIS_HOME } else { Join-Path $env:LOCALAPPDATA 'OpenJarvis' }
$srcDir = Join-Path $installRoot 'src'
$configDir = Join-Path $env:USERPROFILE '.openjarvis'
$configPath = Join-Path $configDir 'config.toml'

# Refresh PATH so uv / ollama installed by the installer are found in this window.
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path', 'User')

if (-not (Test-Path (Join-Path $srcDir 'pyproject.toml'))) {
    Stop-Setup "OpenJarvis introuvable dans $srcDir. Installe-le d'abord :`n  irm https://open-jarvis.github.io/OpenJarvis/install.ps1 | iex"
}
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Stop-Setup "La commande 'uv' est introuvable. Ferme PowerShell, rouvre-le, puis relance ce script."
}

function Invoke-Jarvis { & uv run --project $srcDir jarvis @args }

Write-Host ""
Write-Host "=== Etape 1 : creer ton bot Telegram ===" -ForegroundColor Cyan
Write-Host " 1. Dans Telegram, ouvre une conversation avec @BotFather"
Write-Host " 2. Envoie /newbot, choisis un nom puis un identifiant finissant par 'bot'"
Write-Host " 3. BotFather te donne un jeton qui ressemble a 123456789:AAH..."
Write-Host ""
$token = (Read-Host "Colle le jeton ici (clic droit pour coller)").Trim()

try {
    $me = Invoke-RestMethod "https://api.telegram.org/bot$token/getMe"
    $botName = $me.result.username
} catch {
    Stop-Setup "Jeton refuse par Telegram. Verifie-le et relance le script."
}
Write-Host "Bot trouve : @$botName" -ForegroundColor Green

Write-Host ""
Write-Host "=== Etape 2 : te reserver le bot ===" -ForegroundColor Cyan
Write-Host " Ouvre https://t.me/$botName sur ton telephone, appuie sur Demarrer"
Write-Host " et envoie-lui un message (par exemple 'salut')."
Write-Host " Comme ca, toi seul pourras lui parler."
Write-Host ""
Read-Host "Appuie sur Entree une fois le message envoye" | Out-Null

$chatId = $null
for ($i = 0; $i -lt 5 -and -not $chatId; $i++) {
    $updates = Invoke-RestMethod "https://api.telegram.org/bot$token/getUpdates"
    $msgs = @($updates.result | Where-Object { $_.message })
    if ($msgs.Count -gt 0) { $chatId = [string]$msgs[-1].message.chat.id }
    else { Start-Sleep -Seconds 3 }
}
if (-not $chatId) {
    Stop-Setup "Aucun message recu. Envoie un message au bot puis relance le script."
}
Write-Host "Ton identifiant de conversation : $chatId" -ForegroundColor Green

Write-Host ""
Write-Host "=== Etape 3 : installation du module Telegram ===" -ForegroundColor Cyan
& uv pip install --python (Join-Path $srcDir '.venv\Scripts\python.exe') "python-telegram-bot>=21.0" -q
if ($LASTEXITCODE -ne 0) { Stop-Setup "Installation du module Telegram impossible." }

$createdConfig = $false
if (-not (Test-Path $configPath)) {
    Write-Host "Aucune configuration trouvee, creation..."
    Invoke-Jarvis init --engine ollama --no-download --no-scan --no-analytics --force
    $createdConfig = $true
} else {
    Copy-Item $configPath "$configPath.bak" -Force
}

$env:OJ_TG_TOKEN = $token
$env:OJ_TG_CHAT = $chatId
$env:OJ_TG_CONFIG = $configPath
$env:OJ_TG_SETMODEL = if ($createdConfig) { '1' } else { '' }
$py = @'
import os, tomlkit
path = os.environ["OJ_TG_CONFIG"]
with open(path, encoding="utf-8") as f:
    doc = tomlkit.parse(f.read())
if os.environ.get("OJ_TG_SETMODEL"):
    intel = doc.setdefault("intelligence", tomlkit.table())
    intel["default_model"] = "qwen3.5:2b"  # model pulled by the Windows installer
channel = doc.setdefault("channel", tomlkit.table())
channel["enabled"] = True
channel["default_channel"] = "telegram"
channel.setdefault("default_agent", "simple")
tg = channel.setdefault("telegram", tomlkit.table())
tg["bot_token"] = os.environ["OJ_TG_TOKEN"]
tg["allowed_chat_ids"] = os.environ["OJ_TG_CHAT"]
with open(path, "w", encoding="utf-8") as f:
    f.write(tomlkit.dumps(doc))
'@
$pyFile = Join-Path $env:TEMP 'oj-telegram-edit.py'
Set-Content -Path $pyFile -Encoding ASCII -Value $py
# Run from a file: Windows PowerShell strips double quotes from native-command args.
& uv run --project $srcDir python $pyFile
Remove-Item $pyFile -ErrorAction SilentlyContinue
if ($LASTEXITCODE -ne 0) { Stop-Setup "Mise a jour de la configuration impossible." }
Remove-Item Env:OJ_TG_TOKEN, Env:OJ_TG_CHAT, Env:OJ_TG_CONFIG, Env:OJ_TG_SETMODEL
Write-Host "Configuration mise a jour : $configPath" -ForegroundColor Green

Write-Host ""
Write-Host "=== Etape 4 : demarrage de Jarvis en arriere-plan ===" -ForegroundColor Cyan
try { Invoke-Jarvis stop *> $null } catch { }
Invoke-Jarvis start

try {
    Invoke-RestMethod "https://api.telegram.org/bot$token/sendMessage" -Method Post `
        -Body @{ chat_id = $chatId; text = "Jarvis est connecte ! Ecris-moi ce que tu veux." } | Out-Null
} catch { }

Write-Host ""
Write-Host "C'est pret ! Ecris a @$botName depuis ton telephone." -ForegroundColor Green
Write-Host " - L'ordinateur doit rester allume, et Jarvis lance."
Write-Host " - Apres un redemarrage du PC : ouvre PowerShell et tape  jarvis start"
Write-Host " - Arreter : jarvis stop    |    Etat : jarvis status"
