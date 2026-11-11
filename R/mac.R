# Integração com o macOS, do lado do R.
#
# O ytm-helper cuida do "Tocando Agora", das teclas de mídia, dos controles do fone e do ícone na
# barra de menus. O R manda para ele a música atual (mensagem N) e recebe os comandos (cmd ...,
# seek ...). As notificações são enviadas aqui mesmo, pelo AppleScript.

new_mac <- function(player, enabled = TRUE, notifications = TRUE) {
  m <- new.env()
  m$player <- player
  m$enabled <- enabled
  m$notifications <- enabled && notifications
  m$shown <- NULL
  m$notified <- NULL
  m$quit_requested <- FALSE
  m
}

applescript_escape <- function(x) gsub('"', '\\\\"', gsub("\\\\", "\\\\\\\\", x))

mac_notify <- function(t) {
  dur <- as.integer(t$duration %||% 0)
  details <- paste(Filter(nzchar, c(t$album, if (dur > 0) sprintf("%d:%02d", dur %/% 60, dur %% 60) else "")),
                   collapse = " · ")
  script <- sprintf('display notification "%s" with title "♪ %s" subtitle "%s"',
                    applescript_escape(if (nzchar(details)) details else "YouTube Music"),
                    applescript_escape(if (nzchar(t$title)) t$title else "ytm"),
                    applescript_escape(t$artist %||% ""))
  tryCatch(processx::process$new("osascript", c("-e", script), stdout = NULL, stderr = NULL),
           error = function(e) NULL)
}

# Manda a música atual ao Tocando Agora e à barra de menus quando algo muda.
mac_refresh <- function(m) {
  p <- m$player
  if (!m$enabled || p$state != "playing" || p$played == 0) return(invisible())
  t <- player_track(p)
  key <- paste(p$idx, p$paused, p$seek_gen, t$title)
  if (identical(key, m$shown)) return(invisible())
  m$shown <- key
  info <- list(title = t$title %||% "", artist = t$artist %||% "", album = t$album %||% "",
               duration = as.numeric(t$duration %||% 0), elapsed = player_position(p),
               paused = isTRUE(p$paused))
  if (!is.null(t$thumbnail)) info$artwork <- t$thumbnail
  body <- charToRaw(enc2utf8(as.character(jsonlite::toJSON(info, auto_unbox = TRUE, digits = NA))))
  helper_send(p, helper_msg("N", body))
  if (!identical(m$notified, t)) {
    m$notified <- t
    if (m$notifications) mac_notify(t)
  }
}

# Comandos que vieram do ajudante (menu, teclas de mídia, Tocando Agora).
mac_command <- function(m, line) {
  p <- m$player
  w <- strsplit(line, " ", fixed = TRUE)[[1]]
  if (w[1] == "seek") {
    if (p$state == "playing") player_seek(p, as.numeric(w[2]) - player_position(p))
    return(invisible())
  }
  if (w[1] != "cmd") return(invisible())
  switch(w[2],
    "pause" = player_toggle_pause(p),
    "play" = if (p$paused) player_toggle_pause(p),
    "stop" = if (!p$paused) player_toggle_pause(p),
    "next" = player_next(p),
    "prev" = player_prev(p),
    "quit" = m$quit_requested <- TRUE)
}
