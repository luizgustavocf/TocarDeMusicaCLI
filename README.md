# ytm — YouTube Music no terminal

Tocador de música para o terminal do macOS que busca no YouTube Music e toca uma música,
uma fila de resultados, uma playlist ou um rádio, com animações que seguem o ritmo da música,
letra sincronizada com a voz, o videoclipe direto no terminal e o consumo de CPU e memória do
próprio tocador em tempo real. O macOS reconhece a música que está tocando: ela aparece no
"Tocando Agora", na barra de menus e nas notificações.

## Instalação

Precisa de [Homebrew](https://brew.sh) e Python 3. O `install.sh` instala o `ffmpeg`, o `timg` e o
`deno` pelo Homebrew (se ainda não existirem) e cria um ambiente virtual com `yt-dlp`, `numpy`,
`sounddevice`, `psutil` e `pyobjc` (para a integração com o macOS).

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
`--volume 0-100`, `--sync MS`, `--single` (num link com `&list=`, toca só a música),
`--qualidade-video alta|media|baixa` (qualidade do visual `video`; padrão `alta`),
`--motor-video timg|interno` (quem desenha o vídeo; padrão `timg`),
`--sem-notificacao` (não avisa a cada música) e `--sem-mac` (desliga toda a integração com o macOS).

## Teclas

| Tecla | Ação |
|---|---|
| espaço | pausar / continuar |
| ← / → | voltar / avançar 10 s |
| n / p | próxima / anterior |
| ↑ / ↓ (ou + / -) | volume |
| v | trocar visual (barras, espelho, onda, letra, video, vazio) |
| g | trocar a qualidade do vídeo (alta → media → baixa) |
| m | trocar o motor do vídeo (timg ↔ interno) |
| c | trocar paleta de cores |
| [ / ] | ajustar sincronia da animação, da letra e do vídeo (±20 ms) |
| r | repetir a fila |
| h | mostrar / esconder o HUD de CPU e memória |
| q | sair |

## Como funciona

`yt-dlp` encontra e baixa o áudio, o `ffmpeg` decodifica para PCM e o `sounddevice` toca.
As mesmas amostras que vão para o alto-falante passam por uma FFT, então as barras
reagem ao que está tocando (graves à esquerda, agudos à direita) e as cores pulsam nas batidas.

No visual `letra`, a letra é buscada no [LRCLIB](https://lrclib.net) e cada verso acende
no momento em que é cantado, preenchendo da esquerda para a direita. Quando só existe a letra sem
marcação de tempo, as linhas são distribuídas ao longo da música (aparece o aviso "tempo estimado").

O visual `video` passa o vídeo da música na área da animação, desenhado com caracteres coloridos.
Ele acompanha o áudio, recomeça no ponto certo ao pular ou trocar de faixa e só é baixado enquanto
esse visual está aberto. Com as paletas `preto-branco` e `cinza` ele aparece em preto e branco.
Quanto maior o terminal, maior a imagem.

A qualidade é escolhida com `--qualidade-video` ou trocada durante a música com a tecla `g`:

| Qualidade | Vídeo baixado | Quadros por segundo | Pixels por caractere | CPU nos testes |
|---|---|---|---|---|
| `alta` (padrão) | até 720p | 30 | 4 (2×2, com leve nitidez) | ~20–25% |
| `media` | até 480p | 24 | 2 (1×2) | ~11–12% |
| `baixa` | até 360p | 15 | 2 (1×2), cores arredondadas | ~9% |

Na qualidade `alta`, cada caractere mostra 2×2 pixels usando os caracteres de quadrante
(`▘▝▖▗▌▐▀▄▚▞▛▜▙▟`), o que dobra a resolução na horizontal e deixa contornos e textos do vídeo mais
nítidos. Ela usa mais CPU, internet e dados enviados ao terminal; se a imagem engasgar, use `media`.

Quem desenha o vídeo é escolhido com `--motor-video` ou a tecla `m`:

- `timg` (padrão): o `ffmpeg` reduz o vídeo e o [timg](https://timg.sh) o transforma em caracteres,
  mandando a cada quadro só o que mudou. Envia bem menos dados ao terminal, o que evita que
  terminais mais simples se percam com o vídeo (como o texto da tela virando quadrantes).
- `interno`: o desenho próprio do `ytm`, que redesenha a área inteira a cada quadro.

Integrado ao `ytm`, o `timg` sempre desenha com blocos de caracteres; os modos de imagem real dele
(kitty, iTerm2, sixel) não funcionam quando a saída passa por um pipe.
Em algumas faixas do YouTube Music o vídeo é só a capa do álbum; para ver o clipe oficial, passe o
link do clipe no YouTube (`ytm --visual video "https://www.youtube.com/watch?v=..."`).

O visual `vazio` deixa a área da animação em branco.

No canto direito do título fica o HUD: quanto o tocador está usando de CPU e de memória,
atualizado a cada segundo; a tecla `h` mostra ou esconde. A conta soma o próprio tocador e os
processos que ele abre (`yt-dlp` e `ffmpeg`). A CPU segue o padrão do Monitor de Atividade: 100%
equivale a um núcleo inteiro.

## Integração com o macOS

Ao tocar, o `ytm` aparece para o macOS como um tocador de música:

- **Tocando Agora** (Central de Controle): título, artista, álbum, capa, duração e posição da música.
  As teclas de mídia do teclado (⏯ ⏭ ⏮), os controles dos AirPods e a barra de posição do
  Tocando Agora controlam o `ytm`.
- **Barra de menus**: o ícone `♪ YTM` (`⏸ YTM` quando pausada). Clicando nele aparecem a música e o
  artista e as opções Pausar/Continuar, Próxima, Anterior e Sair do ytm.
- **Notificações**: cada música que começa a tocar gera uma notificação com título, artista,
  álbum e duração.

As notificações são enviadas pelo AppleScript e aparecem como "Editor de Scripts". Se não aparecerem,
libere o Editor de Scripts em Ajustes do Sistema → Notificações. Para ver o Tocando Agora direto na
barra de menus, ative em Ajustes do Sistema → Central de Controle → Tocando Agora.

Com fones Bluetooth (AirPods etc.) o áudio chega com atraso; se a animação, a letra ou o vídeo
parecerem adiantados, use `]` durante a reprodução ou inicie com `--sync 200`.

A primeira música leva alguns segundos para começar porque o YouTube impõe uma espera antes
do download; as seguintes são pré-carregadas enquanto a atual toca.
