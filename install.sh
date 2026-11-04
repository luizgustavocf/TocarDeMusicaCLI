#!/bin/sh
# Instala as dependências do ytm num ambiente virtual local.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
command -v ffmpeg >/dev/null || { echo "Instalando ffmpeg..."; brew install ffmpeg; }
command -v timg >/dev/null || { echo "Instalando timg (motor do visual de vídeo)..."; brew install timg; }
command -v deno >/dev/null || { echo "Instalando deno (necessário para o yt-dlp resolver o YouTube)..."; brew install deno; }

# O ytm precisa de Python 3.10 ou mais novo (o python3 que vem com o macOS é o 3.9).
python_ok() {
    "$1" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null
}

find_python() {
    for py in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
        for cand in "/opt/homebrew/bin/$py" "/usr/local/bin/$py" "$py"; do
            if command -v "$cand" >/dev/null 2>&1 && python_ok "$cand"; then
                command -v "$cand"
                return 0
            fi
        done
    done
    return 1
}

PYTHON="$(find_python)" || {
    echo "Instalando Python 3.13 (o ytm precisa de Python 3.10 ou mais novo)..."
    brew install python@3.13
    PYTHON="$(find_python)" || { echo "Erro: não encontrei um Python 3.10 ou mais novo." >&2; exit 1; }
}
echo "Usando $("$PYTHON" --version) ($PYTHON)"

# Recria o ambiente virtual se ele foi feito com um Python antigo.
if [ -x "$DIR/.venv/bin/python" ] && ! python_ok "$DIR/.venv/bin/python"; then
    echo "Recriando o ambiente virtual (foi criado com um Python antigo)..."
    rm -rf "$DIR/.venv"
fi

"$PYTHON" -m venv "$DIR/.venv"
"$DIR/.venv/bin/pip" install -q --upgrade pip
"$DIR/.venv/bin/pip" install -q --upgrade -r "$DIR/requirements.txt"
chmod +x "$DIR/ytm"
echo "Pronto! Para usar o comando 'ytm' de qualquer lugar:"
echo "  ln -sf \"$DIR/ytm\" /opt/homebrew/bin/ytm"
