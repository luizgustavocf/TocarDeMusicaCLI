# ytm — YouTube Music no terminal

Tocador de música para o terminal do macOS que busca no YouTube Music e toca uma música,
uma fila de resultados, uma playlist ou um rádio, com animações que seguem o ritmo da música,
letra sincronizada com a voz, o videoclipe direto no terminal e o consumo de CPU e memória do
próprio tocador em tempo real.

## Instalação

Precisa de [Homebrew](https://brew.sh) e Python 3. O `install.sh` instala o `ffmpeg` e o `deno`
pelo Homebrew (se ainda não existirem) e cria um ambiente virtual com `yt-dlp`, `numpy`,
`sounddevice` e `psutil`.

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
ytm --visual letra garota de ipanema  # abre direto na letra sincronizada
ytm --visual video bohemian rhapsody  # abre direto no videoclipe
```

Opções: `--visual barras|espelho|onda|letra|video|vazio`, `--cores neon|arco-iris|fogo|oceano|vu|preto-branco|cinza`,
`--volume 0-100`, `--sync MS`, `--single` (num link com `&list=`, toca só a música).

## Teclas

| Tecla | Ação |
|---|---|
| espaço | pausar / continuar |
| ← / → | voltar / avançar 10 s |
| n / p | próxima / anterior |
| ↑ / ↓ (ou + / -) | volume |
| v | trocar visual (barras, espelho, onda, letra, video, vazio) |
| c | trocar paleta de cores |
| [ / ] | ajustar sincronia da animação, da letra e do vídeo (±20 ms) |
| r | repetir a fila |
| h | mostrar / esconder CPU e memória |
| q | sair |

## Como funciona

`yt-dlp` encontra e baixa o áudio, o `ffmpeg` decodifica para PCM e o `sounddevice` toca.
As mesmas amostras que vão para o alto-falante passam por uma FFT, então as barras
reagem ao que está tocando (graves à esquerda, agudos à direita) e as cores pulsam nas batidas.

No visual `letra`, a letra é buscada no [LRCLIB](https://lrclib.net) e cada verso acende
no momento em que é cantado, preenchendo da esquerda para a direita. Quando só existe a letra sem
marcação de tempo, as linhas são distribuídas ao longo da música (aparece o aviso "tempo estimado").

O visual `video` passa o vídeo da música na área da animação, desenhado com caracteres coloridos
(cada caractere mostra dois pixels). O vídeo é baixado em até 360p, acompanha o áudio, recomeça no
ponto certo ao pular ou trocar de faixa e só é baixado enquanto esse visual está aberto. Com as
paletas `preto-branco` e `cinza` ele aparece em preto e branco. Quanto maior o terminal, maior a imagem.
Em algumas faixas do YouTube Music o vídeo é só a capa do álbum; para ver o clipe oficial, passe o
link do clipe no YouTube (`ytm --visual video "https://www.youtube.com/watch?v=..."`).

O visual `vazio` deixa a área da animação em branco.

No canto direito do título aparece quanto o tocador está usando de CPU e de memória, atualizado
a cada segundo; a tecla `h` mostra ou esconde. A conta soma o próprio tocador e os processos que
ele abre (`yt-dlp` e `ffmpeg`). A CPU segue o padrão do Monitor de Atividade: 100% equivale a um
núcleo inteiro.

Com fones Bluetooth (AirPods etc.) o áudio chega com atraso; se a animação, a letra ou o vídeo
parecerem adiantados, use `]` durante a reprodução ou inicie com `--sync 200`.

A primeira música leva alguns segundos para começar porque o YouTube impõe uma espera antes
do download; as seguintes são pré-carregadas enquanto a atual toca.
