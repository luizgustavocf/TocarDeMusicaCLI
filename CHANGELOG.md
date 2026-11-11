# Notas de versão

## v2.01 — Versão na tela

Branch: `release-2.01`

- **Versão do programa no título**, à esquerda do HUD de CPU e memória:
  `V.2.01 · CPU 16.4% · MEM 347 MB`. A versão segue o nome da branch da release (`release-2.01` →
  `V.2.01`) e fica na constante `YTM_VERSION`, em `R/util.R`.
- A tecla `h` esconde só o HUD; a versão continua no canto direito.

## v2.0.0 — Tocador em R

Branch: `release-2.0`

O código foi todo reescrito em R. O que o R não faz sozinho no macOS ficou num pequeno ajudante em
Swift (`helper/ytm-helper`). Opções, teclas, visuais e integração com o macOS continuam os mesmos.

### Como ficou

- **R** (`ytm.R` e a pasta `R/`): opções e ajuda, busca, fila, pré-carga da próxima música, letra,
  visuais (barras, espelho, onda, letra, vídeo e vazio), FFT, HUD e a tela. O que antes rodava em
  threads (dados da faixa, letra, vídeo) agora são processos em segundo plano conferidos a cada quadro.
- **Ajudante em Swift**: toca o áudio (AVAudioEngine) e avisa quantos quadros já saíram no
  alto-falante; cuida do Tocando Agora, das teclas de mídia, dos controles do fone e do ícone na
  barra de menus; avisa o tamanho do terminal quando a janela muda.
- **Programas usados**: `yt-dlp` agora é o programa do Homebrew, e não mais a biblioteca do Python.
  Pacotes do R: `processx`, `jsonlite` e `ps`, instalados na pasta `.Rlib` do projeto.
- Saíram `ytm.py`, `macos.py` e `requirements.txt`. A pasta `.venv` da versão 1.x não é mais usada.

### Novidades e correções

- **Mensagens de erro das opções em português**, por exemplo
  `valor inválido para --visual: 'xyz' (aceitos: barras, espelho, ...)`.
- **Opções curtas juntas e com valor colado**: `-sr`, `-n10`, `--volume=50`.
- **Pausa sem perder trecho**: o áudio que já tinha sido entregue e ainda não tinha tocado é guardado
  e tocado ao continuar. O mesmo vale quando a saída de áudio muda (por exemplo, ao desconectar o fone).
- **`--radio` com um link** agora enfileira 50 músicas do rádio, como o `--radio` com uma busca. Antes
  vinha só 1, porque o padrão de `-n` é 1. Com `-n` maior que 1, vale o `-n`.
- **Vídeo pelo `timg` sem travar no começo.** O YouTube agora obriga cada download a esperar alguns
  segundos, e o `timg` descartava os quadros que chegavam atrasados. Agora o vídeo só abre depois que
  o áudio começa, e o `timg` entrega cada quadro assim que o recebe (`--debug-no-frame-delay`): quem
  decide a hora de mostrar é o `ytm`. Nos testes, o vídeo ficou a 30–50 ms do áudio.

### Observações

- **CPU**: nos testes (terminal de 120×36), ~16% nas barras, ~18% na letra, ~22% no espelho e ~30% na
  onda, contra 7–14% da versão em Python. No vídeo as duas ficam parecidas (~34% na qualidade `alta`
  com o `timg`).
- **Memória**: o R guarda a memória que já usou, então o processo fica com ~190 MB nos visuais comuns
  e chega a ~330 MB depois de usar o vídeo. Não cresce sem parar.
- **Sincronia**: a posição da música agora vem do próprio ajudante (quadros que já saíram no
  alto-falante). Com fones Bluetooth o atraso do fone pode não estar incluído; use `]` ou `--sync`.

## v1.5.1 — Ajuda do comando

Branch: `ajuda-do-comando`

- **`ytm -h`, `ytm -help`, `ytm --help` e `ytm` sozinho** mostram a ajuda. Antes, `ytm` sem nada só
  mostrava um erro, e o `-help` funcionava por acaso.
- A ajuda ficou toda em português (antes apareciam "usage", "options" e "show this help message"),
  com uma linha de uso curta, as opções agrupadas (o que tocar, som e tela, vídeo, macOS), os valores
  aceitos e o padrão de cada uma, as teclas usadas durante a música e mais exemplos.
- O `install.sh` agora usa um Python 3.10 ou mais novo (o `python3` do macOS é o 3.9, que não roda o
  `ytm`) e recria o ambiente virtual se ele foi feito com um Python antigo.

## v1.5.0 — Melhorias no vídeo

Branch: `melhorias-no-video`

### Novidades

- **Vídeo com mais qualidade.** O visual `video` ganhou três níveis de qualidade:
  - `alta` (padrão): vídeo em até 720p, 30 quadros por segundo e 4 pixels por caractere (2×2), usando
    os caracteres de quadrante (`▘▝▖▗▌▐▀▄▚▞▛▜▙▟`). Para cada caractere, o tocador escolhe o desenho e as
    duas cores que mais se aproximam da imagem, o que dobra a resolução na horizontal e deixa
    contornos mais nítidos. A imagem também recebe uma leve nitidez.
  - `media`: até 480p, 24 quadros por segundo, cores sem arredondamento e redução de tamanho mais
    suave (lanczos).
  - `baixa`: o comportamento da v1.3.0 (até 360p, 15 quadros por segundo), que gasta menos CPU.
- **Opção de configuração** `--qualidade-video alta|media|baixa`.
- **Tecla `g`** troca a qualidade durante a música; o vídeo recomeça no ponto que está tocando.
- **Motor `timg`** (padrão quando o `timg` está instalado; o `install.sh` instala). O `ffmpeg` reduz
  o vídeo para o tamanho da área e o [timg](https://timg.sh) transforma em caracteres, mandando a
  cada quadro só as células que mudaram. Com isso o volume de dados enviado ao terminal caiu muito
  (num trecho do teste: cerca de 0,05 MB/s com o `timg`, contra 1,76 MB/s com o motor interno).
  - O `ytm` recebe os quadros do `timg` por um pipe e escreve cada um na área do vídeo junto com o
    resto da tela, então os dois nunca escrevem no terminal ao mesmo tempo.
  - A sincronia com o áudio se ajusta sozinha: se o vídeo começar atrasado, ele recomeça um pouco
    mais à frente sem apagar a imagem (nos testes, a menos de 10 ms do áudio).
  - Opção `--motor-video timg|interno` e tecla `m` para alternar durante a música.
- A linha de status mostra a qualidade e o motor em uso, por exemplo `visual: video (alta · timg)`.

### Correções

- **Texto da tela virando quadrantes depois de um tempo de vídeo.** A saída do `ytm` estava correta
  (conferida num emulador de terminal por 75 s), mas o painel de terminal do app Claude se perdia
  com o volume de caracteres coloridos (cerca de 3 MB/s numa janela grande). O motor `timg`
  resolve isso reduzindo os dados enviados.
- A tela agora posiciona cada linha no lugar dela a cada quadro, em vez de depender de quebras de linha.
- Mensagens de bibliotecas (como avisos do áudio) não aparecem mais no meio da tela: enquanto o
  tocador está aberto, elas vão para o arquivo `ytm.log` na pasta temporária do sistema.
- Áreas lisas do vídeo na qualidade `alta` são desenhadas com uma cor só, sem a textura de pontinhos
  causada pelo ruído do vídeo.

### Como usar

```bash
ytm --visual video bohemian rhapsody                         # qualidade alta (padrão)
ytm --visual video --qualidade-video media bohemian rhapsody
ytm --visual video --motor-video interno bohemian rhapsody   # desenho próprio do ytm
```

### Observações

- Nos testes, com o terminal em 120×36, o uso de CPU com o vídeo aberto foi de cerca de 9% (`baixa`),
  11–12% (`media`) e 20–25% (`alta`). As três mantiveram o vídeo a menos de 15 ms do áudio.
- A qualidade `alta` baixa mais dados da internet e envia mais dados ao terminal; em terminais
  mais lentos ou conexões fracas, prefira `media`.
- Nova dependência: `timg` (Homebrew). Sem ele, o tocador usa o motor interno.
- Integrado ao `ytm`, o `timg` usa blocos de caracteres (quadrantes na `alta`, meio-bloco nas
  outras). Os modos de imagem real do `timg` (kitty, iTerm2, sixel) não funcionam com a saída num
  pipe: ele só desenha o primeiro quadro.

## v1.4.0 — Integração com o Mac

Branch: `integracao-com-o-mac`

### Novidades

- **Tocando Agora do macOS.** Ao tocar, o sistema reconhece o `ytm` como tocador de música e mostra
  título, artista, álbum, capa, duração e posição na Central de Controle.
  - As teclas de mídia do teclado (⏯ ⏭ ⏮) e os controles dos AirPods pausam, continuam e trocam
    de música.
  - Arrastar a barra de posição no Tocando Agora pula para aquele ponto da música.
- **Ícone na barra de menus.** Mostra `♪ YTM` (`⏸ YTM` quando pausada). O menu traz a música,
  o artista e as opções Pausar/Continuar, Próxima, Anterior e Sair do ytm.
- **Notificação a cada música** com título, artista, álbum e duração.
- Novas opções: `--sem-notificacao` desliga só as notificações; `--sem-mac` desliga toda a integração.
- Na linha de ajuda do rodapé, a tecla `h` passou de "h desempenho" para "h hud"; ela continua
  mostrando e escondendo o HUD de CPU e memória.

### Observações

- Novas dependências: `pyobjc-framework-Cocoa` e `pyobjc-framework-MediaPlayer`. Quem já tem o
  projeto instalado deve rodar `./install.sh` de novo. Sem elas, o tocador funciona normalmente,
  só que sem a integração.
- As notificações são enviadas pelo AppleScript e aparecem como "Editor de Scripts"; pode ser
  preciso liberar o Editor de Scripts em Ajustes do Sistema → Notificações.
- A integração usa cerca de 50 MB a mais de memória.
- Enquanto o menu da barra está aberto, a animação no terminal fica parada; a música continua tocando.

## v1.3.0 — VideoClipe

Branch: `videoclipe` (criada a partir de `informacoes-de-performance`)

### Novidades

- **Visual `video`.** Passa o vídeo da música dentro do terminal, na área da animação:
  - desenhado com meio-blocos coloridos (`▀`), dois pixels por caractere, mantendo a proporção do vídeo;
  - sincronizado com o áudio (diferença de cerca de 10 ms nos testes), inclusive ao pausar,
    avançar ou voltar 10 s e trocar de faixa;
  - usa o vídeo da própria faixa, em até 360p e 15 quadros por segundo, para gastar pouca internet e CPU;
  - só é baixado enquanto o visual `video` está aberto; ao trocar de visual, o download para;
  - com as paletas `preto-branco` e `cinza`, o vídeo aparece em preto e branco;
  - quando a faixa não tem vídeo, aparece "vídeo indisponível";
  - o ajuste de sincronia das teclas `[` e `]` também vale para o vídeo.
- A tecla `v` agora alterna entre barras → espelho → onda → letra → video → vazio.

### Como usar

```bash
ytm --visual video bohemian rhapsody
ytm --visual video --cores cinza bohemian rhapsody
```

### Observações

- Em algumas músicas do YouTube Music o "vídeo" é só a capa do álbum parada; é o que o próprio
  YouTube Music mostra para essa faixa. Para ver o clipe oficial, passe o link do clipe no YouTube.
- Com o vídeo aberto, o tocador usa mais CPU e internet (cerca de 10% de CPU nos testes). Logo
  depois de pular para outro ponto da música, a CPU sobe por um instante enquanto o vídeo se reposiciona.
- O README foi atualizado: descrição do projeto, exemplos de `--visual letra` e `--visual video`,
  explicação do visual `video` e ajuste de sincronia valendo também para o vídeo.

## v1.2.0 — Informações de performance

Branch: `informacoes-de-performance` (criada a partir de `melhorias-nos-graficos`)

### Novidades

- **CPU e memória em tempo real.** No lado oposto ao nome da música aparece quanto o tocador
  está usando do computador, por exemplo `CPU 7.2% · MEM 262 MB`, atualizado a cada segundo.
  - A conta inclui o tocador e os processos que ele abre para tocar a música (`yt-dlp` e `ffmpeg`).
  - A CPU segue o padrão do Monitor de Atividade do macOS: 100% equivale a um núcleo inteiro.
  - A memória é a memória residente (RSS) somada desses processos.
  - A tecla `h` mostra ou esconde essas informações. Escondidas, a medição fica pausada e
    não gasta CPU. A linha de ajuda no rodapé passou a mostrar "h desempenho".
- A posição na fila e o nome da fila (por exemplo `1/2 · YouTube Music`) passaram para o lado
  direito da linha do artista.

### Observações

- Nova dependência: `psutil`. Quem já tem o projeto instalado deve rodar `./install.sh` de novo.
- O README foi atualizado: descrição do projeto, dependências instaladas pelo `install.sh`, tecla
  `h` e ajuste de sincronia valendo também para a letra.

## v1.1.0 — Melhorias nos gráficos

Branch: `melhorias-nos-graficos`

### Novidades

- **Paletas em tons de cinza.** Duas novas opções de cores, disponíveis em todos os visuais
  (barras, espelho e onda):
  - `preto-branco`: degradê do preto puro (`#000000`) até o branco (`#ffffff`).
  - `cinza`: degradê do cinza escuro (`#262626`) até o branco. A base das barras continua
    visível em terminais de fundo preto.

  Nessas paletas a batida do grave clareia as cores em vez de escurecê-las entre as batidas,
  então o topo das barras sempre chega ao branco.

- **Visual `letra`.** Mostra a letra da música sincronizada com a voz:
  - o verso cantado fica no centro da tela, em destaque, e vai se preenchendo da esquerda
    para a direita;
  - os versos anteriores e os próximos aparecem acima e abaixo, mais apagados conforme se afastam;
  - antes do primeiro verso, um ♪ marca a introdução instrumental;
  - a letra vem do [LRCLIB](https://lrclib.net), e o tocador escolhe a versão com duração mais
    parecida com a da gravação que está tocando;
  - a sincronia desconta o atraso da saída de áudio e respeita o ajuste das teclas `[` e `]`
    (útil com fones Bluetooth);
  - quando só existe a letra sem tempos, as linhas são distribuídas ao longo da música, com o
    aviso "tempo estimado"; quando não há letra, aparece "letra não encontrada";
  - a busca funciona também com títulos de vídeo no formato "Artista – Música (Official Video)".

- **Visual `vazio`.** Deixa a área da animação em branco, mantendo título, progresso e controles.

### Como usar

```bash
ytm --cores cinza garota de ipanema
ytm --visual letra --cores preto-branco garota de ipanema
```

Durante a reprodução, a tecla `v` agora alterna entre barras → espelho → onda → letra → vazio,
e a tecla `c` inclui as paletas `preto-branco` e `cinza`.

### Observações

- A letra precisa de internet e é buscada em segundo plano ao carregar cada música.
- O LRCLIB é mantido pela comunidade: algumas letras podem vir incompletas ou com linhas que
  não fazem parte da música.
- O README foi atualizado com as novas opções.

## v1.0.0 — Versão inicial

- Toca uma música, uma fila de resultados (`-n`), uma playlist (`-p` ou link) ou o rádio de uma
  música (`--radio`) do YouTube Music direto no terminal do macOS.
- Visuais `barras`, `espelho` e `onda`, que seguem o som tocado, com paletas `neon`, `arco-iris`,
  `fogo`, `oceano` e `vu`.
- Controles de pausa, avanço e retorno, próxima e anterior, volume, repetição e ajuste de sincronia.
