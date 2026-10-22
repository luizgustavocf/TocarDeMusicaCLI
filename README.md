# ytm — YouTube Music no terminal

Tocador de música para o terminal do macOS que busca no YouTube Music e toca uma música,
uma fila de resultados, uma playlist ou um rádio, com animações que seguem o ritmo da música.

## Instalação

Precisa de [Homebrew](https://brew.sh) e Python 3.

```bash
./install.sh
```

Para usar o comando `ytm` de qualquer pasta:

```bash
ln -sf "$PWD/ytm" /opt/homebrew/bin/ytm
```

## Uso

```bash
ytm bohemian rhapsody                 # toca a primeira música encontrada
ytm -n 10 daft punk                   # enfileira os 10 primeiros resultados
ytm -p rock classico                  # busca uma playlist e toca
ytm --radio tiny dancer               # toca a música e continua com o rádio dela
ytm "https://music.youtube.com/playlist?list=..."   # link de música ou playlist
ytm -s -r "https://music.youtube.com/playlist?list=..."  # aleatório, repetindo
```

Opções: `--visual barras|espelho|onda`, `--cores neon|arco-iris|fogo|oceano|vu`,
`--volume 0-100`, `--sync MS`, `--single` (num link com `&list=`, toca só a música).

## Teclas

| Tecla | Ação |
|---|---|
| espaço | pausar / continuar |
| ← / → | voltar / avançar 10 s |
| n / p | próxima / anterior |
| ↑ / ↓ (ou + / -) | volume |
| v | trocar animação (barras, espelho, onda) |
| c | trocar paleta de cores |
| [ / ] | ajustar sincronia da animação (±20 ms) |
| r | repetir a fila |
| q | sair |

## Como funciona

`yt-dlp` encontra e baixa o áudio, o `ffmpeg` decodifica para PCM e o `sounddevice` toca.
As mesmas amostras que vão para o alto-falante passam por uma FFT, então as barras
reagem ao que está tocando (graves à esquerda, agudos à direita) e as cores pulsam nas batidas.

Com fones Bluetooth (AirPods etc.) o áudio chega com atraso; se a animação parecer adiantada,
use `]` durante a reprodução ou inicie com `--sync 200`.

A primeira música leva alguns segundos para começar porque o YouTube impõe uma espera antes
do download; as seguintes são pré-carregadas enquanto a atual toca.
