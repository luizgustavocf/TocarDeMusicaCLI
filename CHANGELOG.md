# Notas de versão

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
