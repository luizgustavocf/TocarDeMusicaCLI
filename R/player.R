# Fila, carregamento e áudio.
#
# Fluxo do áudio: yt-dlp (download) -> ffmpeg (PCM float32) -> R -> ytm-helper (alto-falante).
# O R lê as amostras, aplica o volume, guarda uma cópia para o visualizador e entrega ao ajudante
# só um pouco à frente do que está tocando (AHEAD). O ajudante avisa quantos quadros já saíram no
# alto-falante; essa contagem é a posição da música usada pela animação, pela letra e pelo vídeo.

helper_msg <- function(type, body = raw(0)) {
  c(charToRaw(type), writeBin(length(body), raw(), size = 4, endian = "little"), body)
}

new_player <- function(tracks, label, args, helper_path) {
  p <- new.env()
  p$tracks <- tracks
  p$label <- label
  p$repeat_queue <- isTRUE(args$`repeat`)
  p$volume <- max(0, min(100, args$volume)) / 100
  p$sync_ms <- args$sync
  p$idx <- 1L
  p$state <- "loading"   # loading | playing | ended | error
  p$message <- ""
  p$error_at <- 0
  p$paused <- FALSE
  p$seek_gen <- 0L       # muda a cada (re)início do áudio; o vídeo recomeça junto
  p$tmpdir <- tempfile("ytm-")
  dir.create(p$tmpdir)
  p$src <- NULL
  p$src_eof <- FALSE
  p$leftover <- raw(0)
  p$base_frames <- 0     # posição (em quadros) onde o áudio atual começou
  p$written <- 0         # quadros entregues ao ajudante desde o início do áudio atual
  p$played <- 0          # quadros que já saíram no alto-falante
  p$played_at <- 0
  p$pend <- raw(0)       # áudio entregue que ainda não tocou (reenviado depois de uma pausa)
  p$pend_start <- 0
  p$ring <- numeric(RING)
  p$flush_id <- 0L
  p$flush_base <- 0
  p$helper <- processx::process$new(helper_path, if (isTRUE(args$sem_mac)) "--sem-mac" else character(),
                                    stdin = "|", stdout = "|", stderr = NULL, cleanup = TRUE)
  p$helper_in <- p$helper$get_input_connection()
  p
}

player_track <- function(p) p$tracks[[p$idx]]

helper_send <- function(p, bytes) {
  while (length(bytes)) {
    bytes <- processx::conn_write(p$helper_in, bytes)
    if (length(bytes)) Sys.sleep(0.001)
  }
}

# Descarta o áudio que o ajudante ainda não tocou e recomeça a contagem dele.
player_flush <- function(p) {
  p$flush_id <- p$flush_id + 1L
  p$flush_base <- p$played
  p$played_at <- now()
  helper_send(p, helper_msg("F", writeBin(p$flush_id, raw(), size = 4, endian = "little")))
}

# --------------------------------------------------------------------------- posição

played_est <- function(p) {
  if (p$state != "playing" || p$paused || p$played_at == 0) return(p$played)
  ext <- p$played + (now() - p$played_at) * SR
  min(ext, p$written, p$played + 2 * CHUNK)
}

player_position <- function(p) (p$base_frames + played_est(p)) / SR

heard_position <- function(p) max(0, player_position(p) - p$sync_ms / 1000)

# Últimas n amostras (mono) que estão saindo no alto-falante agora.
player_recent <- function(p, n) {
  end <- floor(played_est(p) - p$sync_ms / 1000 * SR)
  p$ring[((end - n):(end - 1)) %% RING + 1]
}

# --------------------------------------------------------------------------- carregamento

player_play_index <- function(p, i) {
  p$idx <- ((i - 1L) %% length(p$tracks)) + 1L
  player_kill_src(p)
  player_flush(p)
  p$state <- "loading"
  p$message <- ""
  p$paused <- FALSE
  p$base_frames <- 0
  p$written <- p$played <- 0
}

player_start_src <- function(p, sec) {
  t <- player_track(p)
  cmd <- sprintf(
    "yt-dlp -q --no-warnings --no-progress --load-info-json %s -f bestaudio/best -o - | ffmpeg -v quiet -i pipe:0 -ss %.2f -f f32le -ac %d -ar %d pipe:1",
    shQuote(t$info_path), sec, CH, SR)
  p$src <- processx::process$new("sh", c("-c", cmd), stdout = "|", stderr = NULL, cleanup_tree = TRUE)
  p$src_eof <- FALSE
  p$leftover <- raw(0)
  p$seek_gen <- p$seek_gen + 1L
  p$base_frames <- round(sec * SR)
  p$written <- p$played <- 0
  p$pend <- raw(0)
  p$pend_start <- 0
  p$ring[] <- 0
  player_flush(p)
}

player_kill_src <- function(p) {
  if (!is.null(p$src)) {
    tryCatch(p$src$kill_tree(), error = function(e) NULL)
    p$src <- NULL
  }
}

# Chamado a cada quadro da tela: avança o carregamento, a letra e o áudio.
player_update <- function(p) {
  t <- player_track(p)
  if (p$state == "loading") {
    fetch_start(t, p$tmpdir)
    st <- fetch_poll(t)
    if (st == "done") {
      lyrics_start(t, p$tmpdir)
      player_start_src(p, 0)
      p$state <- "playing"
      if (p$idx < length(p$tracks)) fetch_start(p$tracks[[p$idx + 1L]], p$tmpdir)  # pré-carrega a próxima
    } else if (st == "error") {
      p$state <- "error"
      p$message <- t$error %||% "falha ao buscar a faixa"
      p$error_at <- now()
    }
  }
  lyrics_poll(t)
  if (p$idx < length(p$tracks)) {
    nxt <- p$tracks[[p$idx + 1L]]
    if (!is.null(nxt$job)) fetch_poll(nxt)
  }
  if (p$state == "playing" && !p$paused) player_pump(p)
}

# Entrega ao ajudante o áudio que falta para ficar AHEAD segundos à frente do que está tocando.
player_pump <- function(p) {
  if (is.null(p$src)) return(invisible())
  need <- AHEAD * SR - (p$written - played_est(p))
  if (need > 0 && !p$src_eof) {
    want <- ceiling(need / CHUNK) * CHUNK * 8
    data <- p$leftover
    repeat {
      got <- tryCatch(p$src$read_output_bytes(want - length(data)), error = function(e) raw(0))
      data <- c(data, got)
      if (length(data) >= want || !length(got)) break
    }
    if (!length(got) && !p$src$is_incomplete_output()) p$src_eof <- TRUE
    nf <- length(data) %/% 8
    p$leftover <- if (length(data) > nf * 8) data[(nf * 8 + 1):length(data)] else raw(0)
    if (nf > 0) {
      s <- readBin(data[seq_len(nf * 8)], "numeric", n = nf * 2, size = 4, endian = "little")
      out <- writeBin(s * p$volume, raw(), size = 4, endian = "little")
      mono <- (s[c(TRUE, FALSE)] + s[c(FALSE, TRUE)]) / 2
      p$ring[(p$written + seq_len(nf) - 1) %% RING + 1] <- mono
      chunk <- CHUNK * 8
      starts <- seq(1, length(out), by = chunk)
      msgs <- lapply(starts, function(a) helper_msg("A", out[a:min(a + chunk - 1, length(out))]))
      helper_send(p, unlist(msgs, use.names = FALSE))
      p$pend <- c(p$pend, out)
      p$written <- p$written + nf
    }
  }
  # o que já tocou não precisa mais ser guardado (recorta de meio em meio segundo: copiar o
  # áudio guardado a cada quadro custaria CPU à toa)
  drop <- floor(p$played - p$pend_start)
  if (drop > SR / 2) {
    p$pend <- if (drop * 8 < length(p$pend)) p$pend[-seq_len(drop * 8)] else raw(0)
    p$pend_start <- p$pend_start + drop
  }
  if (p$src_eof && p$written - p$played < CHUNK) {
    player_kill_src(p)
    if (p$written == 0 && p$base_frames == 0) {
      p$state <- "error"
      p$message <- "falha ao baixar o áudio"
      p$error_at <- now()
    } else {
      p$state <- "ended"
    }
  }
}

# Reenvia ao ajudante o áudio que tinha sido entregue e ainda não tocou (depois de uma pausa
# ou de uma troca da saída de áudio).
player_resend <- function(p) {
  p$played <- max(p$played, p$pend_start)
  player_flush(p)
  skip <- floor(p$played - p$pend_start) * 8
  rest <- if (skip < length(p$pend)) p$pend[(skip + 1):length(p$pend)] else raw(0)
  p$pend <- rest
  p$pend_start <- p$played
  p$written <- p$played + length(rest) / 8
  if (length(rest)) {
    chunk <- CHUNK * 8
    starts <- seq(1, length(rest), by = chunk)
    helper_send(p, unlist(lapply(starts, function(a) helper_msg("A", rest[a:min(a + chunk - 1, length(rest))])),
                          use.names = FALSE))
  }
}

# Lê o que o ajudante mandou. Atualiza a posição e devolve as outras linhas (comandos, tamanho).
player_read_helper <- function(p) {
  lines <- tryCatch(p$helper$read_output_lines(), error = function(e) character())
  other <- character()
  for (l in lines) {
    w <- strsplit(l, " ", fixed = TRUE)[[1]]
    if (w[1] == "pos") {
      if (as.integer(w[2]) == p$flush_id) {
        p$played <- p$flush_base + as.numeric(w[3])
        p$played_at <- now()
      }
    } else if (w[1] == "lost") {
      if (as.integer(w[2]) == p$flush_id && p$state == "playing" && !p$paused) player_resend(p)
    } else {
      other <- c(other, l)
    }
  }
  other
}

# --------------------------------------------------------------------------- controles

player_toggle_pause <- function(p) {
  if (p$state != "playing") return(invisible())
  if (!p$paused) {
    p$played <- played_est(p)
    p$paused <- TRUE
    player_flush(p)  # pausa na hora: descarta o que estava na fila do ajudante
  } else {
    p$paused <- FALSE
    player_resend(p)
  }
}

player_seek <- function(p, delta) {
  if (p$state != "playing") return(invisible())
  pos <- max(0, player_position(p) + delta)
  t <- player_track(p)
  player_kill_src(p)
  if (t$duration > 0 && pos >= t$duration - 1) {
    p$state <- "ended"
    return(invisible())
  }
  p$paused <- FALSE
  player_start_src(p, pos)
}

player_next <- function(p, manual = TRUE) {
  if (p$idx < length(p$tracks)) player_play_index(p, p$idx + 1L)
  else if (p$repeat_queue) player_play_index(p, 1L)
  else if (!manual) return(FALSE)
  TRUE
}

player_prev <- function(p) {
  if (p$state == "playing" && player_position(p) > 3) player_seek(p, -player_position(p))
  else if (p$idx > 1 || p$repeat_queue) player_play_index(p, p$idx - 1L)
}

player_close <- function(p) {
  player_kill_src(p)
  tryCatch({
    helper_send(p, helper_msg("Q"))
    p$helper$wait(1500)
  }, error = function(e) NULL)
  if (p$helper$is_alive()) p$helper$kill()
  for (t in p$tracks) {
    if (!is.null(t$job)) tryCatch(t$job$proc$kill(), error = function(e) NULL)
    for (j in t$lyrics_jobs) tryCatch(j$proc$kill(), error = function(e) NULL)
  }
  unlink(p$tmpdir, recursive = TRUE)
}
