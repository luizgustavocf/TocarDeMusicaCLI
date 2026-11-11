# Busca no YouTube Music e dados de cada faixa (pelo programa yt-dlp).

YTDLP_QUIET <- c("-q", "--no-warnings", "--no-progress")

new_track <- function(url, title = "", artist = "", duration = 0) {
  t <- new.env()
  t$url <- url
  t$title <- title
  t$artist <- artist
  t$album <- ""
  t$duration <- duration
  t$info_path <- NULL
  t$job <- NULL          # processo do yt-dlp buscando os dados
  t$error <- NULL
  t$lyrics <- NULL       # data.frame(t, text); NULL = ainda não buscou
  t$lyrics_jobs <- NULL
  t$lyrics_synced <- FALSE
  t$lyrics_artist <- artist
  t$aspect <- 16 / 9
  t$thumbnail <- NULL
  t
}

clean_artist <- function(name) sub(" - Topic$", "", name %||% "")

first_text <- function(...) {
  for (x in list(...)) {
    if (is.list(x)) x <- paste(unlist(x), collapse = ", ")
    if (!is.null(x) && length(x) && !is.na(x[1]) && nzchar(x[1])) return(as.character(x[1]))
  }
  ""
}

entry_to_track <- function(e) {
  url <- e$url %||% ""
  if (!startsWith(url, "http")) url <- paste0("https://music.youtube.com/watch?v=", e$id)
  new_track(url, title = e$title %||% "",
            artist = clean_artist(first_text(e$artist, e$artists, e$channel, e$uploader)),
            duration = as.numeric(e$duration %||% 0))
}

flat <- function(url, limit = NULL) {
  args <- c(YTDLP_QUIET, "--flat-playlist", "-J")
  if (!is.null(limit)) args <- c(args, "--playlist-end", as.character(limit))
  r <- processx::run("yt-dlp", c(args, url), error_on_status = FALSE)
  if (r$status != 0) {
    msg <- trimws(strsplit(r$stderr, "\n")[[1]])
    stop(sub("^ERROR: ", "", tail(msg[nzchar(msg)], 1) %||% "o yt-dlp falhou"), call. = FALSE)
  }
  jsonlite::fromJSON(r$stdout, simplifyVector = FALSE)
}

entries <- function(info) Filter(Negate(is.null), info$entries %||% list())

video_id <- function(url) {
  host <- sub("^https?://([^/?#]+).*", "\\1", url)
  if (endsWith(host, "youtu.be")) return(sub("^https?://[^/]+/([^?#]+).*", "\\1", url))
  m <- regmatches(url, regexpr("[?&]v=([^&#]+)", url))
  if (length(m)) sub("^[?&]v=", "", m) else NULL
}

radio_url <- function(id) sprintf("https://music.youtube.com/watch?v=%s&list=RDAMVM%s", id, id)

# Transforma a entrada do usuário numa lista de faixas + um rótulo.
resolve <- function(args) {
  q <- trimws(paste(args$query, collapse = " "))
  enc <- function(x) utils::URLencode(x, reserved = TRUE)

  if (grepl("^https?://", q)) {
    if (grepl("/browse/VL", q, fixed = TRUE)) {
      q <- paste0("https://music.youtube.com/playlist?list=", sub(".*/browse/VL", "", q))
    }
    vid <- video_id(q)
    if (args$radio && !is.null(vid)) {
      info <- flat(radio_url(vid), limit = if (args$n > 1) args$n else 50)
      return(list(tracks = lapply(entries(info), entry_to_track), label = "Rádio"))
    }
    if (grepl("list=", q, fixed = TRUE) && !args$single) {
      info <- flat(q)
      return(list(tracks = lapply(entries(info), entry_to_track), label = info$title %||% "Playlist"))
    }
    return(list(tracks = list(new_track(q)), label = "YouTube Music"))
  }

  if (args$playlist) {
    found <- entries(flat(sprintf("https://music.youtube.com/search?q=%s#community+playlists", enc(q)), limit = 1))
    if (!length(found)) return(list(tracks = list(), label = ""))
    pid <- sub("^VL", "", found[[1]]$id %||% "")
    info <- flat(paste0("https://music.youtube.com/playlist?list=", pid))
    return(list(tracks = lapply(entries(info), entry_to_track), label = info$title %||% "Playlist"))
  }

  found <- entries(flat(sprintf("https://music.youtube.com/search?q=%s#songs", enc(q)),
                        limit = if (args$radio) 1 else args$n))
  if (args$radio && length(found)) {
    info <- flat(radio_url(found[[1]]$id), limit = 50)
    return(list(tracks = lapply(entries(info), entry_to_track),
                label = paste0("Rádio: ", found[[1]]$title %||% q)))
  }
  list(tracks = lapply(found, entry_to_track), label = "YouTube Music")
}

# --------------------------------------------------------------------------- dados da faixa

# Começa a buscar os dados da faixa (formatos, título, álbum...) em segundo plano.
fetch_start <- function(t, tmpdir) {
  if (!is.null(t$info_path) || !is.null(t$job)) return(invisible())
  t$error <- NULL
  path <- tempfile("faixa-", tmpdir, ".json")
  t$job <- list(path = path, proc = processx::process$new(
    "yt-dlp", c(YTDLP_QUIET, "-f", "bestaudio/best", "--no-playlist", "-J", t$url),
    stdout = path, stderr = "|", cleanup = TRUE))
}

# "done", "running" ou "error" (com a mensagem em t$error)
fetch_poll <- function(t) {
  if (!is.null(t$info_path)) return("done")
  if (!is.null(t$error)) return("error")
  if (is.null(t$job)) return("error")
  p <- t$job$proc
  if (p$is_alive()) return("running")
  path <- t$job$path
  err <- tryCatch(p$read_all_error(), error = function(e) "")
  t$job <- NULL
  info <- if (identical(p$get_exit_status(), 0L)) {
    tryCatch(jsonlite::fromJSON(path, simplifyVector = FALSE), error = function(e) NULL)
  }
  if (is.null(info)) {
    lines <- trimws(strsplit(err, "\n")[[1]])
    t$error <- substr(sub("^ERROR: ", "", tail(lines[nzchar(lines)], 1) %||% "falha ao buscar a faixa"), 1, 200)
    return("error")
  }
  t$title <- first_text(info$track, info$title, t$title)
  t$artist <- clean_artist(first_text(info$artist, info$channel, info$uploader)) %||% t$artist
  if (!nzchar(t$artist)) t$artist <- clean_artist(first_text(info$channel, info$uploader))
  t$album <- first_text(info$album)
  t$duration <- as.numeric(info$duration %||% t$duration)
  t$lyrics_artist <- if (length(info$artists)) as.character(info$artists[[1]]) else t$artist
  sized <- Filter(function(f) !is.null(f$width) && !is.null(f$height) && f$height > 0, info$formats %||% list())
  if (length(sized)) {
    last <- sized[[length(sized)]]
    t$aspect <- last$width / last$height
  }
  t$thumbnail <- info$thumbnail
  t$info_path <- path
  "done"
}
