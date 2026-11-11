# Tela, teclado e o laço principal.

build_frame <- function(p, v, pm, vf, cols, rows, t_now) {
  t <- player_track(p)
  accent <- fg_code(viz_color(v, 0.8, 0.5))
  buffering <- p$state == "playing" && p$played == 0 && !p$paused
  icon <- if (p$state == "loading" || buffering) SPINNER[floor(t_now * 12) %% length(SPINNER) + 1]
          else if (p$state == "error") "✕" else if (p$paused) "⏸" else "▶"

  stats <- if (pm$visible) sprintf("CPU %4.1f%% · MEM %.0f MB ", pm$cpu, pm$mem / 2^20) else ""
  title <- trunc_text(if (nzchar(t$title)) t$title else "Carregando…", cols - dwidth(stats) - 5)
  gap <- cols - 3 - dwidth(title) - dwidth(stats)
  head1 <- paste0(" ", accent, icon, RESET, " ", BOLD, title, RESET, strrep(" ", max(gap, 1)), DIM, stats, RESET)

  queue <- trunc_text(sprintf("%d/%d · %s ", p$idx, length(p$tracks), p$label), max(cols %/% 3, 10))
  sub <- paste(Filter(nzchar, c(t$artist, t$album)), collapse = " · ")
  color <- DIM
  if (p$state == "error") {
    sub <- sprintf("Erro: %s — pulando…", p$message)
    color <- "\033[31m"
  } else if (p$state == "loading" || buffering) {
    sub <- paste0(if (nzchar(sub)) paste0(sub, " · ") else "", if (buffering) "preparando áudio…" else "buscando faixa…")
  }
  sub <- trunc_text(sub, cols - dwidth(queue) - 5)
  gap <- cols - 3 - dwidth(sub) - dwidth(queue)
  head2 <- paste0("   ", color, sub, RESET, strrep(" ", max(gap, 1)), DIM, queue, RESET)

  viz_h <- max(rows - 7, 3)
  active <- p$state == "playing" && !p$paused
  samples <- if (active) player_recent(p, FFT_N) else numeric(FFT_N)
  viz_update(v, samples, viz_layout(cols)$n, 1 / FPS, active)
  heard <- if (p$state == "playing") heard_position(p) else 0
  timg_out <- ""
  # o vídeo só abre quando o áudio já está tocando: antes disso o YouTube ainda faz o download
  # esperar, e o timg descartaria os quadros que chegassem atrasados em relação ao relógio dele
  if (viz_mode(v) == "video" && !(p$state == "playing" && p$played > 0)) {
    video_stop(vf)
    body <- character(viz_h)
    body[viz_h %/% 2 + 1] <- paste0(center_pad("carregando vídeo…", cols), DIM, "carregando vídeo…")
  } else if (viz_mode(v) == "video" && !is.null(t$info_path)) {
    video_ensure(vf, t, cols, viz_h)
    video_poll(vf)
    if (vf$engine == "timg") {
      timg_out <- video_take_timg(vf, top = 4)
      body <- video_timg_body(vf, viz_h, nzchar(timg_out))
    } else {
      video_take_frame(vf)
      body <- render_video(v, vf, cols, viz_h)
    }
  } else {
    video_stop(vf)
    body <- viz_render(v, cols, viz_h, samples, t, heard)
  }

  pos <- if (p$state == "playing") player_position(p) else 0
  dur <- t$duration %||% 0
  left <- fmt_time(pos)
  rt <- if (dur > 0) fmt_time(dur) else "--:--"
  bar_w <- max(cols - nchar(left) - nchar(rt) - 6, 5)
  frac <- if (dur > 0) min(pos / dur, 1) else 0
  k <- floor(frac * (bar_w - 1))
  prog <- paste0(" ", left, " ", accent, strrep("━", k), "●", RESET, DIM, strrep("─", bar_w - 1 - k), RESET, " ", rt)

  shown <- if (viz_mode(v) == "video") sprintf("video (%s · %s)", vf$quality, vf$engine) else viz_mode(v)
  status <- sprintf(" %svol %d%% · visual: %s · cores: %s · sync: %+dms%s%s", DIM, round(p$volume * 100), shown,
                    viz_palette(v), as.integer(p$sync_ms), if (p$repeat_queue) " · repetir" else "", RESET)
  keys <- trunc_text("espaço pausa · ←/→ ±10s · n/p próx/ant · ↑/↓ volume · v visual · g qualidade do vídeo · m motor do vídeo · c cores · [/] sync · r repetir · h hud · q sair", cols - 2)
  lines <- c(head1, head2, "", body, prog, status, paste0(" ", DIM, keys, RESET))
  lines <- lines[seq_len(min(length(lines), rows))]
  # cada linha vai para sua posição; NA deixa a linha como está (área desenhada pelo timg)
  i <- which(!is.na(lines))
  screen <- paste0(sprintf("\033[%d;1H", i), lines[i], RESET, "\033[K", collapse = "")
  if (length(lines) < rows) screen <- paste0(screen, sprintf("\033[%d;1H\033[J", length(lines) + 1))
  paste0(screen, timg_out)
}

handle_keys <- function(data, p, v, pm, vf) {
  arrows <- c("\033[A" = "up", "\033[B" = "down", "\033[C" = "right", "\033[D" = "left")
  i <- 1
  while (i <= nchar(data)) {
    seq3 <- substr(data, i, i + 2)
    if (seq3 %in% names(arrows)) {
      i <- i + 3
      switch(arrows[[seq3]],
        up = p$volume <- min(1, round(p$volume + 0.05, 2)),
        down = p$volume <- max(0, round(p$volume - 0.05, 2)),
        right = player_seek(p, 10),
        left = player_seek(p, -10))
      next
    }
    ch <- substr(data, i, i)
    i <- i + 1
    if (ch %in% c("q", "Q")) return(FALSE)
    if (ch == " ") player_toggle_pause(p)
    else if (ch %in% c("n", "N")) player_next(p)
    else if (ch %in% c("p", "P")) player_prev(p)
    else if (ch %in% c("+", "=")) p$volume <- min(1, round(p$volume + 0.05, 2))
    else if (ch %in% c("-", "_")) p$volume <- max(0, round(p$volume - 0.05, 2))
    else if (ch %in% c("v", "V")) viz_cycle_mode(v)
    else if (ch %in% c("c", "C")) viz_cycle_palette(v)
    else if (ch == "[") p$sync_ms <- p$sync_ms - 20
    else if (ch == "]") p$sync_ms <- p$sync_ms + 20
    else if (ch %in% c("r", "R")) p$repeat_queue <- !p$repeat_queue
    else if (ch %in% c("h", "H")) pm$visible <- !pm$visible
    else if (ch %in% c("g", "G")) video_cycle_quality(vf)
    else if (ch %in% c("m", "M")) video_cycle_engine(vf)
  }
  TRUE
}

tty_size <- function() {
  s <- tryCatch(system("stty size < /dev/tty 2>/dev/null", intern = TRUE), error = function(e) "", warning = function(w) "")
  n <- suppressWarnings(as.integer(strsplit(s[1] %||% "", " ")[[1]]))
  if (length(n) == 2 && all(!is.na(n)) && all(n > 0)) c(n[2], n[1]) else c(80, 24)
}

out_write <- function(s) {
  cat(s)
  flush(stdout())
}

run_ui <- function(p, v, mac, vf) {
  old_tty <- system("stty -g < /dev/tty", intern = TRUE)
  system("stty -icanon -echo min 0 time 0 < /dev/tty")
  keys <- processx::conn_create_fd(0L, encoding = "UTF-8")
  # mensagens de bibliotecas iriam para o meio da tela: vão para um log
  log <- file(file.path(tempdir_root(), "ytm.log"), open = "a")
  sink(log, type = "message")
  finished <- FALSE
  err <- NULL
  restored <- FALSE
  restore <- function() {
    if (restored) return(invisible())
    restored <<- TRUE
    video_stop(vf)
    out_write("\033[0m\033[?25h\033[?1049l")
    system(paste("stty", shQuote(old_tty), "< /dev/tty"))
    sink(type = "message")
    close(log)
  }
  on.exit(restore())
  out_write("\033[?1049h\033[?25l\033[2J")
  pm <- new_perf()
  player_play_index(p, 1L)
  size <- tty_size()
  drawn <- NULL
  next_frame <- now()
  tryCatch({
    repeat {
      for (line in player_read_helper(p)) {
        w <- strsplit(line, " ", fixed = TRUE)[[1]]
        if (w[1] == "size") size <- as.integer(w[2:3]) else mac_command(mac, line)
      }
      if (mac$quit_requested) break
      player_update(p)
      if (p$state == "ended" && !player_next(p, manual = FALSE)) {
        finished <- TRUE
        break
      }
      if (p$state == "error" && now() - p$error_at > 2 && !player_next(p, manual = FALSE)) {
        finished <- TRUE
        break
      }
      mac_refresh(mac)
      perf_update(pm)

      if (!identical(size, drawn)) {
        drawn <- size
        out_write("\033[2J")
      }
      out_write(build_frame(p, v, pm, vf, size[1], size[2], now()))

      next_frame <- next_frame + 1 / FPS
      wait <- next_frame - now()
      if (wait < 0) {
        next_frame <- now()
        wait <- 0
      }
      ready <- processx::poll(list(keys), as.integer(wait * 1000))[[1]]
      if (ready == "ready") {
        data <- processx::conn_read_chars(keys)
        if (nzchar(data) && !handle_keys(data, p, v, pm, vf)) break
      }
    }
  }, interrupt = function(e) NULL, error = function(e) err <<- e, finally = restore())
  if (!is.null(err)) stop(err)  # a tela já voltou ao normal: o erro aparece no terminal
  finished
}

tempdir_root <- function() {
  d <- Sys.getenv("TMPDIR", "/tmp")
  if (nzchar(d)) d else "/tmp"
}
