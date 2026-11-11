# Visual 'video': o vídeo da faixa na área da animação, no mesmo ritmo do áudio.
#
# Só roda enquanto o visual 'video' está ativo. Cada (re)início do áudio, troca de faixa, de
# qualidade ou do tamanho do terminal recomeça o vídeo na posição que está tocando.

# alta: vídeo em 720p e 4 pixels por caractere (2 colunas x 2 linhas), com leve nitidez.
# media: mais quadros e cores sem arredondar. baixa: menos CPU. A tecla g percorre nesta ordem.
VIDEO_QUALITY <- list(
  alta = list(height = 720, fps = 30, quad = TRUE, step = 1, filter = "lanczos,unsharp=3:3:0.6"),
  media = list(height = 480, fps = 24, quad = FALSE, step = 1, filter = "lanczos"),
  baixa = list(height = 360, fps = 15, quad = FALSE, step = 8, filter = "area")
)

# Quadrantes: cada caractere cobre 2x2 pixels, pintados com 2 cores (texto e fundo).
# Bits: 1 = alto-esquerda, 2 = alto-direita, 4 = baixo-esquerda, 8 = baixo-direita (pixels na cor do texto).
QUAD_CHARS <- strsplit(" ▘▝▀▖▌▞▛▗▚▐▜▄▙▟█", "")[[1]]

has_timg <- function() nzchar(Sys.which("timg"))

new_video <- function(player, quality = "alta", engine = "timg") {
  vf <- new.env()
  vf$player <- player
  vf$quality <- quality
  vf$engine <- if (engine == "timg" && !has_timg()) "interno" else engine
  vf$key <- NULL
  vf$proc <- NULL
  vf$buf <- raw(0)
  vf$queue <- list()     # quadros já decodificados: list(t, dados)
  vf$count <- 0          # quadros recebidos desde o início
  vf$start <- 0
  vf$fps <- 30
  vf$sep <- NULL         # timg: "ESC [ N A" volta N linhas para desenhar cada quadro novo
  vf$timg_shown <- FALSE
  vf$lead <- 1.5         # timg: começa à frente do áudio para compensar a partida (ajustado sozinho)
  # O timg recebe --debug-no-frame-delay: entrega cada quadro assim que o recebe, sem seguir o
  # relógio dele. Quem decide a hora de mostrar é o ytm, pelo tempo da música de cada quadro; assim
  # nenhum quadro se perde quando o download demora para começar.
  vf$session <- list(key = NULL, at = 0)
  vf$frame <- NULL
  vf$frame_quad <- FALSE
  vf$frame_size <- c(0, 0)
  vf$status <- ""
  vf$area <- c(0, 0, 0, 0)  # colunas, linhas, largura e altura do vídeo
  vf
}

video_settings <- function(vf) VIDEO_QUALITY[[vf$quality]]

video_cycle_quality <- function(vf) {
  q <- names(VIDEO_QUALITY)
  vf$quality <- q[match(vf$quality, q) %% length(q) + 1]
}

video_cycle_engine <- function(vf) {
  if (has_timg()) vf$engine <- if (vf$engine == "timg") "interno" else "timg"
}

# Tamanho em caracteres que cabe na área, mantendo a proporção do vídeo
# (um caractere tem o dobro de altura que de largura).
cells_for <- function(track, cols, rows) {
  aspect <- track$aspect %||% (16 / 9)
  w <- cols
  h <- w / aspect / 2
  if (h > rows) {
    h <- rows
    w <- h * 2 * aspect
  }
  c(max(round(w), 1), max(floor(h), 1))
}

video_source_cmd <- function(vf, track, start, vf_filter, out) {
  q <- video_settings(vf)
  fmt <- sprintf("bestvideo[height<=%d][vcodec^=avc1]/bestvideo[height<=%d]/worstvideo", q$height, q$height)
  sprintf("yt-dlp -q --no-warnings --no-progress --load-info-json %s -o - -f %s | ffmpeg -v quiet -i pipe:0 -ss %.2f -an -vf %s %s",
          shQuote(track$info_path), shQuote(fmt), start, shQuote(vf_filter), out)
}

scale_filter <- function(q, pw, ph) {
  parts <- strsplit(q$filter, ",", fixed = TRUE)[[1]]
  paste0(sprintf("fps=%d,scale=%d:%d:flags=%s", q$fps, pw, ph, parts[1]),
         if (length(parts) > 1) paste0(",", paste(parts[-1], collapse = ",")) else "")
}

video_ensure <- function(vf, track, cols, rows) {
  q <- video_settings(vf)
  cw <- cells_for(track, cols, rows)
  if (vf$engine == "timg") {
    # o timg corrige sozinho a proporção dos caracteres: ele recebe pixels quadrados
    pw <- cw[1] * (if (q$quad) 2 else 1)
    ph <- max(round(pw / (track$aspect %||% (16 / 9))) %/% 2 * 2, 2)
  } else {
    pw <- cw[1] * (if (q$quad) 2 else 1)
    ph <- cw[2] * 2
  }
  key <- paste(track$info_path, pw, ph, vf$player$seek_gen, vf$quality, vf$engine)
  vf$area <- c(cols, rows, cw[1], cw[2])
  if (identical(key, vf$key)) return(invisible())
  video_stop(vf)
  vf$key <- key
  vf$status <- "carregando vídeo…"
  vf$buf <- raw(0)
  vf$queue <- list()
  vf$count <- 0
  vf$fps <- q$fps
  if (vf$engine == "timg") {
    picture <- paste(track$info_path, pw, ph, vf$quality)
    if (!identical(vf$session$key, picture)) vf$timg_shown <- FALSE  # mesma imagem: fica até o novo quadro
    vf$session <- list(key = picture, at = now())
    vf$sep <- NULL
    vf$start <- heard_position(vf$player) + vf$lead
    cmd <- paste(video_source_cmd(vf, track, vf$start, scale_filter(q, pw, ph),
                                  "-c:v rawvideo -pix_fmt rgb24 -f nut pipe:1"),
                 sprintf("| timg -V --debug-no-frame-delay -p %s -g %dx%d -o /dev/stdout -", if (q$quad) "q" else "h", cw[1], cw[2]))
  } else {
    vf$frame <- NULL
    vf$frame_size <- c(pw, ph)
    vf$frame_quad <- q$quad
    vf$start <- heard_position(vf$player)
    cmd <- video_source_cmd(vf, track, vf$start, scale_filter(q, pw, ph), "-f rawvideo -pix_fmt rgb24 pipe:1")
  }
  vf$proc <- processx::process$new("sh", c("-c", cmd), stdout = "|", stderr = NULL, cleanup_tree = TRUE)
}

# Lê o que já chegou do vídeo, sem esperar (no máximo ~2 s de quadros guardados).
video_poll <- function(vf) {
  if (is.null(vf$proc) || length(vf$queue) > vf$fps * 2) return(invisible())
  # cada leitura devolve só alguns KB: lê até esvaziar o que já chegou (com um limite por quadro da tela)
  cap <- if (vf$engine == "timg") 1 * 2^20 else 4 * prod(vf$frame_size) * 3
  parts <- list()
  total <- 0
  repeat {
    got <- tryCatch(vf$proc$read_output_bytes(), error = function(e) raw(0))
    if (!length(got)) break
    parts[[length(parts) + 1]] <- got
    total <- total + length(got)
    if (total >= cap) break
  }
  ended <- !total && !vf$proc$is_incomplete_output()
  if (total) vf$buf <- c(vf$buf, unlist(parts, use.names = FALSE))
  if (vf$engine == "timg") {
    if (is.null(vf$sep)) {
      m <- grepRaw("\033\\[[0-9]+A", vf$buf, value = TRUE)
      if (length(m)) {
        vf$sep <- m
        vf$area[4] <- as.integer(gsub("[^0-9]", "", rawToChar(m)))  # altura real usada pelo timg
      }
    }
    if (!is.null(vf$sep)) {
      at <- grepRaw(vf$sep, vf$buf, fixed = TRUE, all = TRUE)
      cuts <- c(1, at + length(vf$sep))
      for (k in seq_along(at)) if (at[k] > cuts[k]) push_timg(vf, vf$buf[cuts[k]:(at[k] - 1)])
      vf$buf <- if (length(at)) vf$buf[-seq_len(cuts[length(cuts)] - 1)] else vf$buf
    }
    if (ended && length(vf$buf)) {
      push_timg(vf, vf$buf)
      vf$buf <- raw(0)
    }
  } else {
    size <- prod(vf$frame_size) * 3
    while (length(vf$buf) >= size) {
      vf$queue[[length(vf$queue) + 1]] <- list(t = vf$start + vf$count / vf$fps, data = vf$buf[seq_len(size)])
      vf$count <- vf$count + 1
      vf$buf <- vf$buf[-seq_len(size)]
    }
  }
  if (ended) {
    vf$proc <- NULL
    vf$status <- if (vf$count == 0) "vídeo indisponível" else ""
  }
}

push_timg <- function(vf, bytes) {
  text <- rawToChar(bytes)
  Encoding(text) <- "UTF-8"
  text <- gsub("\033[?25l", "", text, fixed = TRUE)
  text <- gsub("\033[?25h", "", text, fixed = TRUE)
  vf$queue[[length(vf$queue) + 1]] <- list(t = vf$start + vf$count / vf$fps, data = text)
  vf$count <- vf$count + 1
}

# Tira da fila os quadros que já chegaram na hora do áudio.
video_due <- function(vf) {
  heard <- heard_position(vf$player)
  due <- list()
  while (length(vf$queue) && vf$queue[[1]]$t <= heard + 0.03) {
    due[[length(due) + 1]] <- vf$queue[[1]]
    vf$queue[[1]] <- NULL
  }
  list(frames = due, late = if (length(due)) heard - due[[length(due)]]$t else 0)
}

# timg: códigos de terminal dos quadros que já chegaram na hora do áudio, posicionados na área.
video_take_timg <- function(vf, top) {
  d <- video_due(vf)
  if (d$late > 0.25 && now() - vf$session$at < 8) {
    # a partida demorou mais que o previsto: os quadros atrasados saem de uma vez e o vídeo alcança
    # o áudio sozinho; a próxima partida já começa mais à frente
    vf$lead <- min(vf$lead + d$late, 6)
  }
  if (!length(d$frames)) return("")
  a <- vf$area
  row <- top + (a[2] - a[4]) %/% 2
  col <- (a[1] - a[3]) %/% 2 + 1
  pos <- sprintf("\033[%d;%dH", row, col)
  nl <- sprintf("\n\033[%dG", col)
  paste0(paste0(pos, gsub("\n", nl, vapply(d$frames, `[[`, "", "data"), fixed = TRUE), collapse = ""), RESET)
}

# timg: linhas da área do vídeo; NA mantém o que o timg desenhou.
video_timg_body <- function(vf, rows, drawing) {
  if (vf$timg_shown) return(rep(NA_character_, rows))
  if (drawing) {  # primeiro quadro: limpa a área antes de desenhar
    vf$timg_shown <- TRUE
    return(rep("", rows))
  }
  out <- character(rows)
  msg <- if (nzchar(vf$status)) vf$status else "carregando vídeo…"
  out[rows %/% 2 + 1] <- paste0(center_pad(msg, vf$area[1]), DIM, msg)
  out
}

# interno: atualiza o quadro atual com o último que já chegou na hora do áudio.
video_take_frame <- function(vf) {
  d <- video_due(vf)
  if (length(d$frames)) vf$frame <- d$frames[[length(d$frames)]]$data
}

video_stop <- function(vf) {
  vf$key <- NULL
  if (!is.null(vf$proc)) {
    tryCatch(vf$proc$kill_tree(), error = function(e) NULL)
    vf$proc <- NULL
  }
}

# --------------------------------------------------------------------------- desenho (motor interno)

# Para cada bloco 2x2, escolhe o desenho de quadrante e as 2 cores que mais se aproximam da imagem.
quadrants <- function(px, pw, ph) {
  rows <- ph %/% 2
  cols <- pw %/% 2
  r <- rep(seq_len(rows) - 1, each = cols)
  c <- rep(seq_len(cols) - 1, times = rows)
  at <- function(dy, dx) px[(2 * r + dy) * pw + 2 * c + dx + 1, , drop = FALSE]
  P <- list(at(0, 0), at(0, 1), at(1, 0), at(1, 1))  # bits 1, 2, 4, 8
  total <- P[[1]] + P[[2]] + P[[3]] + P[[4]]
  N <- nrow(total)
  err <- matrix(0, N, 7)
  fgs <- bgs <- vector("list", 7)
  for (m in 1:7) {
    w <- bitwAnd(m, c(1, 2, 4, 8)) > 0
    sum_fg <- Reduce(`+`, P[w])
    fg <- sum_fg / sum(w)
    bg <- (total - sum_fg) / (4 - sum(w))
    e <- 0
    for (k in 1:4) e <- e + rowSums((P[[k]] - if (w[k]) fg else bg)^2)
    err[, m] <- e
    fgs[[m]] <- fg
    bgs[[m]] <- bg
  }
  best <- max.col(-err, ties.method = "first")
  fg <- bg <- matrix(0, N, 3)
  for (m in 1:7) {
    sel <- best == m
    fg[sel, ] <- fgs[[m]][sel, ]
    bg[sel, ] <- bgs[[m]][sel, ]
  }
  chars <- QUAD_CHARS[best + 1]
  # bloco quase liso (variação média < ~10 por canal): uma cor só. Evita pontinhos com o ruído do
  # vídeo nas áreas lisas e gera menos códigos de cor.
  mean <- total / 4
  spread <- rowSums((P[[1]] - mean)^2 + (P[[2]] - mean)^2 + (P[[3]] - mean)^2 + (P[[4]] - mean)^2)
  flat <- spread < 4 * 3 * 10^2
  chars[flat] <- " "
  fg[flat, ] <- mean[flat, ]
  bg[flat, ] <- mean[flat, ]
  list(chars = chars, fg = fg, bg = bg, rows = rows, cols = cols)
}

render_video <- function(v, vf, width, height) {
  out <- character(height)
  if (is.null(vf$frame)) {
    msg <- trunc_text(if (nzchar(vf$status)) vf$status else "carregando vídeo…", width - 4)
    out[height %/% 2 + 1] <- paste0(center_pad(msg, width), DIM, msg)
    return(out)
  }
  pw <- vf$frame_size[1]
  ph <- vf$frame_size[2]
  px <- matrix(as.integer(vf$frame), ncol = 3, byrow = TRUE)  # linha = pixel (y * pw + x)
  storage.mode(px) <- "double"
  if (viz_palette(v) %in% GRAYS) px <- matrix(rep(px %*% c(0.299, 0.587, 0.114), 3), ncol = 3)
  if (vf$frame_quad) {
    q <- quadrants(px, pw, ph)
  } else {  # ▀: pixel de cima na cor do texto, o de baixo no fundo
    rows <- ph %/% 2
    r <- rep(seq_len(rows) - 1, each = pw)
    x <- rep(seq_len(pw) - 1, times = rows)
    q <- list(chars = rep("▀", rows * pw), fg = px[(2 * r) * pw + x + 1, , drop = FALSE],
              bg = px[(2 * r + 1) * pw + x + 1, , drop = FALSE], rows = rows, cols = pw)
  }
  # step > 1 arredonda as cores: menos códigos de cor por linha, menos dados para o terminal
  step <- video_settings(vf)$step
  round_c <- function(m) as.integer(pmin(pmax(m + 0.5, 0), 255)) %/% step * step
  fg <- matrix(round_c(q$fg), ncol = 3)
  bg <- matrix(round_c(q$bg), ncol = 3)
  codes <- sprintf("\033[38;2;%d;%d;%d;48;2;%d;%d;%dm", fg[, 1], fg[, 2], fg[, 3], bg[, 1], bg[, 2], bg[, 3])
  top <- max((height - q$rows) %/% 2, 0)
  left <- strrep(" ", max((width - q$cols) %/% 2, 0))
  for (r in seq_len(min(q$rows, height))) {
    i <- (r - 1) * q$cols + seq_len(q$cols)
    cc <- codes[i]
    emit <- c(TRUE, cc[-1] != cc[-length(cc)])
    out[top + r] <- paste0(left, paste0(ifelse(emit, cc, ""), q$chars[i], collapse = ""), RESET)
  }
  out
}
