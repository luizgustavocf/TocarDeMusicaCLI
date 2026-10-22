#!/bin/sh
# Instala as dependências do ytm num ambiente virtual local.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
command -v ffmpeg >/dev/null || { echo "Instalando ffmpeg..."; brew install ffmpeg; }
command -v deno >/dev/null || { echo "Instalando deno (necessário para o yt-dlp resolver o YouTube)..."; brew install deno; }
python3 -m venv "$DIR/.venv"
"$DIR/.venv/bin/pip" install -q --upgrade pip
"$DIR/.venv/bin/pip" install -q -r "$DIR/requirements.txt"
chmod +x "$DIR/ytm"
echo "Pronto! Para usar o comando 'ytm' de qualquer lugar:"
echo "  ln -sf \"$DIR/ytm\" /opt/homebrew/bin/ytm"
