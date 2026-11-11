# Visualizador: espectro (FFT), barras, espelho, onda e letra.

BLOCKS <- strsplit(" ▁▂▃▄▅▆▇█", "")[[1]]
# bits do caractere braille para (linha 0..3, coluna 0..1)
BRAILLE <- matrix(c(0x01, 0x02, 0x04, 0x40, 0x08, 0x10, 0x20, 0x80), nrow = 4)

new_visualizer <- function(mode, palette) {
  v <- new.env()
  v$mode <- match(mode, MODES)
  v$palette <- match(palette, names(PALETTES))
  v$window <- 0.5 - 0.5 * cos(2 * pi * (0:(FFT_N - 1)) / (FFT_N - 1))  # janela de Hann
  v$freqs <- (0:(FFT_N / 2)) * SR / FFT_N
  v$n <- 0
  v$ref_db <- -30
  v$bass_avg <- 1e-6
  v$bass_bins <- which(v$freqs > 30 & v$freqs < 150)
  v$beat <- 0
  v$last_beat <- 0
  v$wave_gain <- 1
  v$phase <- 0
  v
}

viz_mode <- function(v) MODES[v$mode]
viz_palette <- function(v) names(PALETTES)[v$palette]
viz_cycle_mode <- function(v) v$mode <- v$mode %% length(MODES) + 1
viz_cycle_palette <- function(v) v$palette <- v$palette %% length(PALETTES) + 1

# Cores (matriz n x 3) para alturas t e posições x, com o pulso da batida.
viz_colors <- function(v, t, x) {
  n <- max(length(t), length(x))
  rgb <- PALETTES[[v$palette]](rep_len(t, n), rep_len(x, n), v$phase)
  if (viz_palette(v) %in% GRAYS) {  # clareia na batida para o topo continuar branco
    return(matrix(as.integer(rgb + (255 - rgb) * 0.3 * v$beat), ncol = 3))
  }
  matrix(pmin(255L, as.integer(rgb * (0.72 + 0.28 * v$beat))), ncol = 3)  # pulsa no grave
}

viz_color <- function(v, t, x) viz_colors(v, t, x)[1, ]

color_codes <- function(m) sprintf("\033[38;2;%d;%d;%dm", m[, 1], m[, 2], m[, 3])

viz_setup <- function(v, n) {
  v$n <- n
  edges <- exp(seq(log(35), log(16000), length.out = n + 1))
  v$centers <- sqrt(edges[-length(edges)] * edges[-1])
  idx <- findInterval(edges, v$freqs, left.open = TRUE) + 1  # como searchsorted (lado esquerdo)
  v$lo <- pmin(idx[-length(idx)], length(v$freqs))
  v$hi <- pmin(pmax(idx[-1] - 1, v$lo), length(v$freqs))
  v$hi[n] <- length(v$freqs)  # a última faixa vai até o fim do espectro
  v$wide <- (idx[-1] - idx[-length(idx)]) >= 2
  v$tilt <- 4.5 * log2(v$centers / 1000)  # compensa a queda natural dos agudos
  v$bars <- v$peaks <- v$hold <- numeric(n)
}

# Calcula o espectro das amostras atuais e anima barras e picos.
viz_update <- function(v, samples, n, dt, active) {
  if (n != v$n) viz_setup(v, n)
  v$phase <- (v$phase + dt * 0.02) %% 1
  if (active) {
    x <- samples[(length(samples) - FFT_N + 1):length(samples)] * v$window
    spec <- Mod(fft(x))[seq_len(FFT_N / 2 + 1)] / (FFT_N / 4)
    interp <- stats::approx(v$freqs, spec, xout = v$centers, rule = 2)$y
    bands <- vapply(seq_len(n), function(i) max(spec[v$lo[i]:v$hi[i]]), 0)
    mag <- ifelse(v$wide, bands, interp)
    db <- 20 * log10(mag + 1e-9) + v$tilt
    v$ref_db <- max(max(db), v$ref_db - 6 * dt, -40)
    target <- pmin(pmax((db - (v$ref_db - 48)) / 48, 0), 1)^1.5

    bass <- mean(spec[v$bass_bins])
    t <- now()
    if (bass > 1.45 * v$bass_avg && bass > 1e-3 && t - v$last_beat > 0.18) {
      v$beat <- 1
      v$last_beat <- t
    }
    v$bass_avg <- 0.92 * v$bass_avg + 0.08 * bass
  } else {
    target <- numeric(n)
  }
  v$beat <- max(0, v$beat - dt * 3.5)
  rise <- target > v$bars
  v$bars <- ifelse(rise, v$bars + (target - v$bars) * 0.75, pmax(target, v$bars - dt * 1.6))
  up <- v$bars >= v$peaks
  v$peaks <- ifelse(up, v$bars, v$peaks)
  v$hold <- ifelse(up, 0.35, v$hold - dt)
  v$peaks <- ifelse(v$hold < 0, pmax(v$bars, v$peaks - dt * 0.7), v$peaks)
}

viz_layout <- function(width) {
  bw <- 2
  gap <- 1
  n <- max(4, (width + gap) %/% (bw + gap))
  list(n = n, bw = bw, gap = gap, margin = (width - (n * (bw + gap) - gap)) %/% 2)
}

# --------------------------------------------------------------------------- desenho

viz_render <- function(v, width, height, samples, track, pos) {
  switch(viz_mode(v),
    "vazio" = rep("", height),
    "letra" = render_lyrics(v, width, height, track, pos),
    "onda" = render_wave(v, width, height, samples),
    "espelho" = {
      top <- (height + 1) %/% 2
      c(render_bars(v, width, top), render_reflection(v, width, height - top))
    },
    render_bars(v, width, height))
}

# Desenha uma matriz de células (linhas x barras): cada barra tem bw caracteres e um espaço entre elas.
# cells: índice em BLOCKS (1 = vazio) ou 0 para o pico "▁"; cols: código de cor ou NA.
bar_rows <- function(L, cells, cols) {
  table <- c(strrep("▁", L$bw), vapply(BLOCKS, strrep, "", L$bw, USE.NAMES = FALSE))
  gap <- c(rep(strrep(" ", L$gap), L$n - 1), "")
  margin <- strrep(" ", L$margin)
  vapply(seq_len(nrow(cells)), function(r) {
    paste0(margin, join_cells(paste0(table[cells[r, ] + 1], gap), cols[r, ]))
  }, "")
}

render_bars <- function(v, width, height) {
  L <- viz_layout(width)
  n <- L$n
  b <- (height - 1):0  # linha contando de baixo, de cima para baixo
  lvl <- outer(-b * 8, floor(v$bars * height * 8), "+")
  peak_row <- pmin(floor(v$peaks * height), height - 1)
  is_peak <- lvl <= 0 & outer(b, peak_row, "==") & matrix(v$peaks > 0.03, height, n, byrow = TRUE)
  cells <- pmax(pmin(lvl, 8), 0) + 1
  cells[is_peak] <- 0
  t <- (b + 0.5) / height
  if (viz_palette(v) == "arco-iris") {
    bar_cols <- matrix(color_codes(viz_colors(v, rep(t, n), rep((seq_len(n) - 1) / n, each = height))), height, n)
  } else {
    bar_cols <- matrix(color_codes(viz_colors(v, t, 0)), height, n)
  }
  cols <- matrix(NA_character_, height, n)
  cols[lvl > 0] <- bar_cols[lvl > 0]
  cols[is_peak] <- "\033[38;2;235;235;245m"
  bar_rows(L, matrix(as.integer(cells), height, n), cols)
}

render_reflection <- function(v, width, height) {
  if (height < 1) return(character())
  L <- viz_layout(width)
  n <- L$n
  k <- seq_len(height) - 1
  lvl <- outer(-k * 2, floor(v$bars * (height + 1) * 2), "+")
  shape <- ifelse(lvl >= 2, 3L, ifelse(lvl == 1, 2L, 1L))  # vazio, ▀, █
  base <- viz_colors(v, v$bars, (seq_len(n) - 1) / n)
  t <- 1 - (k + 0.5) / max(height, 1)
  f <- rep(0.15 + 0.35 * t, n)  # fator de cada célula (coluna por coluna)
  dimmed <- matrix(as.integer(base[rep(seq_len(n), each = height), ] * f), ncol = 3)
  cols <- matrix(color_codes(dimmed), height, n)
  cols[shape == 1L] <- NA
  table <- c(strrep(" ", L$bw), strrep("▀", L$bw), strrep("█", L$bw))
  gap <- c(rep(strrep(" ", L$gap), n - 1), "")
  margin <- strrep(" ", L$margin)
  vapply(seq_len(height), function(r) paste0(margin, join_cells(paste0(table[shape[r, ]], gap), cols[r, ])), "")
}

render_wave <- function(v, width, height, samples) {
  dw <- width * 2
  dh <- height * 4
  span <- 2048
  # alinha num cruzamento por zero para a onda ficar estável na tela
  head <- samples[seq_len(length(samples) - span)]
  cross <- which(head[-length(head)] <= 0 & head[-1] > 0)
  start <- if (length(cross)) cross[length(cross)] else length(samples) - span + 1
  seg <- stats::filter(samples[start:(start + span - 1)], rep(1 / 6, 6), sides = 2)  # suaviza
  seg[is.na(seg)] <- 0
  x <- as.numeric(seg)[as.integer(seq(1, span, length.out = dw))]
  peak <- max(abs(x))
  if (peak > 1e-4) v$wave_gain <- v$wave_gain + (min(0.85 / peak, 40) - v$wave_gain) * 0.15
  y <- pmin(pmax(round((1 - x * v$wave_gain) / 2 * (dh - 1)), 0), dh - 1)

  # liga cada ponto ao anterior com uma linha vertical de pontos braille
  prev <- c(y[1], y[-length(y)])
  lo <- pmin(prev, y)
  hi <- pmax(prev, y)
  len <- hi - lo + 1
  vy <- sequence(len, from = lo)
  vx <- rep(seq_len(dw) - 1, len)
  bit <- BRAILLE[cbind(vy %% 4 + 1, vx %% 2 + 1)]
  cell <- (vy %/% 4) * width + vx %/% 2 + 1
  key <- unique(data.frame(cell, bit))
  grid <- tabulate(rep(key$cell, key$bit), nbins = width * height)  # soma dos bits distintos

  out <- character(height)
  mid <- height / 2
  for (r in seq_len(height)) {
    bits <- grid[(r - 1) * width + seq_len(width)]
    t <- abs(r - 0.5 - mid) / mid
    on <- bits > 0
    ch <- ifelse(on, intToUtf8(0x2800 + bits, multiple = TRUE), " ")
    cols <- rep(NA_character_, width)
    if (any(on)) cols[on] <- color_codes(viz_colors(v, 0.25 + 0.75 * t, (which(on) - 1) / width))
    out[r] <- join_cells(ch, cols)
  }
  out
}

render_lyrics <- function(v, width, height, track, pos) {
  lines <- track$lyrics
  out <- character(height)
  mid <- height %/% 2 + 1
  center <- function(text, prefix) {
    text <- trunc_text(text, width - 4)
    paste0(center_pad(text, width), prefix, text)
  }
  if (is.null(lines) || !nrow(lines)) {
    out[mid] <- center(if (is.null(lines)) "procurando letra…" else "letra não encontrada", DIM)
    return(out)
  }
  times <- lines$t
  cur <- findInterval(pos, times)  # 0 = antes do primeiro verso
  for (r in seq_len(height)) {
    diff <- r - mid
    if (diff %% 2) next  # uma linha em branco entre os versos
    j <- cur + diff %/% 2
    if (j == cur && cur == 0) out[r] <- center("♪", fg_code(viz_color(v, 0.6, 0.5)))
    if (j < 1 || j > nrow(lines)) next
    text <- lines$text[j]
    if (!nzchar(text)) text <- "♪"
    if (j != cur) {
      fade <- max(0.18, 0.75 - 0.14 * abs(j - cur))
      out[r] <- center(text, fg_code(as.integer(viz_color(v, 0.7, 0.5) * fade)))
      next
    }
    # verso atual: preenche da esquerda para a direita acompanhando a voz
    text <- trunc_text(text, width - 4)
    nxt <- if (j < nrow(lines)) times[j + 1] else times[j] + 5
    frac <- if (track$lyrics_synced) min(max((pos - times[j]) / max(nxt - times[j], 0.1), 0), 1) else 1
    chars <- strsplit(text, "")[[1]]
    k <- floor(length(chars) * min(frac * 1.4, 1))  # a voz costuma terminar antes do próximo verso
    sung <- paste(chars[seq_len(k)], collapse = "")
    rest <- if (k < length(chars)) paste(chars[(k + 1):length(chars)], collapse = "") else ""
    out[r] <- paste0(center_pad(text, width), BOLD, fg_code(viz_color(v, 1, 0.5)), sung,
                     fg_code(viz_color(v, 0.55, 0.5)), rest)
  }
  if (!track$lyrics_synced) out[height] <- center("letra sem sincronia: tempo estimado", DIM)
  out
}
