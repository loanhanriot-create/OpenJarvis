#!/usr/bin/env bash
# Connect an installed OpenJarvis to a Telegram bot so you can chat from your phone.
#
# Prerequisite: OpenJarvis installed with the official installer:
#   curl -fsSL https://open-jarvis.github.io/OpenJarvis/install.sh | bash
#
# Usage: bash setup-telegram.sh
set -euo pipefail

OJ_HOME="${OPENJARVIS_HOME:-$HOME/.openjarvis}"
CONFIG="$OJ_HOME/config.toml"
PY="$OJ_HOME/.venv/bin/python"
JARVIS="$OJ_HOME/.venv/bin/jarvis"

if [ ! -x "$PY" ] || [ ! -f "$CONFIG" ]; then
  echo "OpenJarvis introuvable dans $OJ_HOME."
  echo "Installe-le d'abord :"
  echo "  curl -fsSL https://open-jarvis.github.io/OpenJarvis/install.sh | bash"
  exit 1
fi

cat <<'EOF'

=== Étape 1 : créer ton bot Telegram ===
 1. Dans Telegram, ouvre une conversation avec @BotFather
 2. Envoie /newbot, choisis un nom puis un identifiant finissant par "bot"
 3. BotFather te donne un jeton qui ressemble à 123456789:AAH...

EOF
read -r -p "Colle le jeton ici : " TOKEN
TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"

BOT_NAME="$(curl -fsS "https://api.telegram.org/bot${TOKEN}/getMe" \
  | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["result"]["username"])' 2>/dev/null || true)"
if [ -z "$BOT_NAME" ]; then
  echo "Jeton refusé par Telegram. Vérifie-le et relance le script."
  exit 1
fi
echo "Bot trouvé : @$BOT_NAME"

cat <<EOF

=== Étape 2 : te réserver le bot ===
 Ouvre https://t.me/$BOT_NAME sur ton téléphone, appuie sur Démarrer
 et envoie-lui un message (par exemple "salut").
 Comme ça, toi seul pourras lui parler.

EOF
read -r -p "Appuie sur Entrée une fois le message envoyé..." _

CHAT_ID=""
for _ in 1 2 3 4 5; do
  CHAT_ID="$(curl -fsS "https://api.telegram.org/bot${TOKEN}/getUpdates" \
    | "$PY" -c '
import json, sys
ids = [u["message"]["chat"]["id"] for u in json.load(sys.stdin).get("result", []) if "message" in u]
print(ids[-1] if ids else "")' 2>/dev/null || true)"
  [ -n "$CHAT_ID" ] && break
  sleep 3
done
if [ -z "$CHAT_ID" ]; then
  echo "Aucun message reçu. Envoie un message au bot puis relance le script."
  exit 1
fi
echo "Ton identifiant de conversation : $CHAT_ID"

echo
echo "=== Étape 3 : installation du module Telegram ==="
if command -v uv >/dev/null 2>&1; then
  uv pip install --python "$PY" "python-telegram-bot>=21.0" -q
else
  "$PY" -m pip install -q "python-telegram-bot>=21.0"
fi

cp "$CONFIG" "$CONFIG.bak"
TOKEN="$TOKEN" CHAT_ID="$CHAT_ID" "$PY" - "$CONFIG" <<'PYEOF'
import os, sys
import tomlkit

path = sys.argv[1]
with open(path) as f:
    doc = tomlkit.parse(f.read())
channel = doc.setdefault("channel", tomlkit.table())
channel["enabled"] = True
channel["default_channel"] = "telegram"
channel.setdefault("default_agent", "simple")
tg = channel.setdefault("telegram", tomlkit.table())
tg["bot_token"] = os.environ["TOKEN"]
tg["allowed_chat_ids"] = os.environ["CHAT_ID"]
with open(path, "w") as f:
    f.write(tomlkit.dumps(doc))
PYEOF
chmod 600 "$CONFIG"
echo "Configuration mise à jour ($CONFIG, sauvegarde : $CONFIG.bak)"

echo
echo "=== Étape 4 : démarrage de Jarvis en arrière-plan ==="
"$JARVIS" stop >/dev/null 2>&1 || true
"$JARVIS" start

curl -fsS "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -d chat_id="$CHAT_ID" \
  --data-urlencode text="Jarvis est connecté ! Écris-moi ce que tu veux." >/dev/null || true

cat <<EOF

C'est prêt ! Écris à @$BOT_NAME depuis ton téléphone.
 - L'ordinateur doit rester allumé, et Jarvis lancé.
 - Après un redémarrage de l'ordinateur : jarvis start
 - Arrêter : jarvis stop    |    État : jarvis status
EOF
