# Letra sincronizada (LRCLIB), buscada em segundo plano com o curl.

LRC_TAG <- "\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]"
TITLE_NOISE <- "(?i)\\s*[(\\[][^)\\]]*(official|video|clipe|lyric|letra|audio|áudio|remaster|4k|hd\\b|visualizer)[^)\\]]*[)\\]]"
LRCLIB_UA <- "ytm-cli (https://github.com/luizgustavocf/TocarDeMusicaCLI)"

parse_lrc <- function(text) {
  out <- list()
  for (raw in strsplit(text, "\n")[[1]]) {
    words <- trimws(gsub(LRC_TAG, "", raw, perl = TRUE))
    tags <- regmatches(raw, gregexpr(LRC_TAG, raw, perl = TRUE))[[1]]
    for (tag in tags) {
      p <- suppressWarnings(as.numeric(regmatches(tag, regexec(LRC_TAG, tag, perl = TRUE))[[1]][2:3]))
      if (!anyNA(p)) out[[length(out) + 1]] <- data.frame(t = p[1] * 60 + p[2], text = words)
    }
  }
  if (!length(out)) return(data.frame(t = numeric(), text = character()))
  d <- do.call(rbind, out)
  d[order(d$t), , drop = FALSE]
}

lyrics_queries <- function(title, artist) {
  title <- trimws(gsub(TITLE_NOISE, "", title, perl = TRUE))
  artist <- trimws(sub("(?i)\\s*(official|vevo)$", "", artist %||% "", perl = TRUE))
  qs <- list(list(track_name = title, artist_name = artist))
  parts <- strsplit(title, "\\s+[-–—]\\s+", perl = TRUE)[[1]]
  if (length(parts) >= 2) {  # vídeos no formato "Artista - Música"
    qs <- c(list(list(track_name = paste(parts[-1], collapse = " - "), artist_name = parts[1])), qs)
  }
  c(qs, list(list(q = paste(artist, title))))
}

# Começa as buscas da letra (todas juntas; a resposta segue a ordem de preferência).
lyrics_start <- function(t, tmpdir) {
  if (!is.null(t$lyrics) || !is.null(t$lyrics_jobs)) return(invisible())
  enc <- function(x) utils::URLencode(x, reserved = TRUE)
  t$lyrics_jobs <- lapply(lyrics_queries(t$title, t$lyrics_artist %||% t$artist), function(q) {
    url <- paste0("https://lrclib.net/api/search?",
                  paste0(names(q), "=", vapply(q, enc, ""), collapse = "&"))
    path <- tempfile("letra-", tmpdir, ".json")
    list(path = path, proc = processx::process$new(
      "curl", c("-s", "--max-time", "10", "-A", LRCLIB_UA, url), stdout = path, stderr = NULL, cleanup = TRUE))
  })
}

lyrics_poll <- function(t) {
  if (!is.null(t$lyrics) || is.null(t$lyrics_jobs)) return(invisible())
  if (any(vapply(t$lyrics_jobs, function(j) j$proc$is_alive(), logical(1)))) return(invisible())
  jobs <- t$lyrics_jobs
  t$lyrics_jobs <- NULL
  dur <- t$duration %||% 0
  score <- function(r) {
    d <- if (dur > 0) abs((r$duration %||% 0) - dur) else 0
    synced <- !is.null(r$syncedLyrics) && nzchar(r$syncedLyrics)
    c(if (synced && d <= 4) 0 else if (d <= 15) 1 else 2, !synced, d)
  }
  for (j in jobs) {
    res <- tryCatch(jsonlite::fromJSON(j$path, simplifyVector = FALSE), error = function(e) list())
    res <- Filter(function(r) is.list(r) && (nzchar(r$syncedLyrics %||% "") || nzchar(r$plainLyrics %||% "")), res)
    if (!length(res)) next
    s <- do.call(rbind, lapply(res, score))
    best <- res[[order(s[, 1], s[, 2], s[, 3])[1]]]
    if (nzchar(best$syncedLyrics %||% "")) {
      t$lyrics <- parse_lrc(best$syncedLyrics)
      t$lyrics_synced <- TRUE
    } else {
      plain <- trimws(strsplit(best$plainLyrics, "\n")[[1]])
      d <- if (dur > 0) dur else best$duration %||% 180
      i <- seq_along(plain) - 1
      t$lyrics <- data.frame(t = d * (0.08 + 0.87 * i / max(length(plain), 1)), text = plain)
      t$lyrics_synced <- FALSE
    }
    return(invisible())
  }
  t$lyrics <- data.frame(t = numeric(), text = character())
}
