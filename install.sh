#!/bin/sh
# Instala o que o ytm precisa: programas pelo Homebrew, pacotes do R numa pasta local e o
# ajudante em Swift (áudio e integração com o macOS).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

need() {  # need <comando> <fórmula do Homebrew> <para que serve>
    command -v "$1" >/dev/null || { echo "Instalando $2 ($3)..."; brew install "$2"; }
}
need Rscript r "a linguagem do tocador"
need ffmpeg ffmpeg "decodifica o áudio e o vídeo"
need yt-dlp yt-dlp "busca e baixa do YouTube"
need deno deno "necessário para o yt-dlp resolver o YouTube"
need timg timg "motor do visual de vídeo"

if ! command -v swiftc >/dev/null; then
    echo "Erro: falta o compilador Swift, usado no ajudante de áudio." >&2
    echo "Instale as ferramentas de linha de comando da Apple com: xcode-select --install" >&2
    exit 1
fi

echo "Instalando os pacotes do R (processx, jsonlite, ps)..."
mkdir -p "$DIR/.Rlib"
Rscript --no-init-file -e '
lib <- commandArgs(TRUE)[1]
pkgs <- c("processx", "jsonlite", "ps")
missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), lib.loc = lib, quietly = TRUE)]
if (length(missing)) install.packages(missing, lib = lib, repos = "https://cloud.r-project.org", quiet = TRUE)
for (p in pkgs) if (!requireNamespace(p, lib.loc = lib, quietly = TRUE)) stop("não foi possível instalar o pacote ", p)
' "$DIR/.Rlib"

echo "Compilando o ajudante (ytm-helper)..."
swiftc -O -suppress-warnings "$DIR/helper/ytm-helper.swift" -o "$DIR/helper/ytm-helper"

chmod +x "$DIR/ytm"
if [ -d "$DIR/.venv" ]; then
    echo "A pasta .venv é da versão em Python (1.x) e não é mais usada; pode apagar com: rm -rf \"$DIR/.venv\""
fi
echo "Pronto! Para usar o comando 'ytm' de qualquer lugar:"
echo "  ln -sf \"$DIR/ytm\" /opt/homebrew/bin/ytm"
