# ytm — tocador de YouTube Music no terminal com visualizador de áudio (versão em R).
#
# Fluxo do áudio: yt-dlp (download do stream) -> ffmpeg (decodifica para PCM float32) -> R
# -> ytm-helper (alto-falante). As mesmas amostras alimentam o visualizador (FFT), então a
# animação acompanha exatamente o que está tocando.
#
# Rode pelo atalho `ytm`, que aponta o R para os pacotes instalados pelo install.sh.

local({
  args <- commandArgs(trailingOnly = FALSE)
  file <- sub("^--file=", "", args[grep("^--file=", args)][1])
  assign("YTM_DIR", normalizePath(dirname(file)), envir = globalenv())
})
.libPaths(c(file.path(YTM_DIR, ".Rlib"), .libPaths()))
invisible(Sys.setlocale("LC_CTYPE", "en_US.UTF-8"))
options(warn = -1)

for (f in c("util", "args", "search", "lyrics", "player", "visual", "video", "perf", "mac", "ui")) {
  source(file.path(YTM_DIR, "R", paste0(f, ".R")), encoding = "UTF-8")
}

die <- function(msg) {
  cat(msg, "\n", sep = "", file = stderr())
  quit(save = "no", status = 1)
}

main <- function() {
  argv <- commandArgs(trailingOnly = TRUE)
  if (!length(argv)) {
    cat(HELP_TEXT)
    return(invisible())
  }
  args <- parse_args(argv)
  if (isTRUE(args$help)) {
    cat(HELP_TEXT)
    return(invisible())
  }

  for (tool in c("ffmpeg", "yt-dlp")) {
    if (!nzchar(Sys.which(tool))) die(sprintf("ytm: %s não encontrado. Instale com: brew install %s", tool, tool))
  }
  helper <- file.path(YTM_DIR, "helper", "ytm-helper")
  if (!file.exists(helper)) die("ytm: ajudante de áudio não encontrado. Rode o ./install.sh")
  if (!isatty(stdin())) die("ytm: precisa ser executado num terminal interativo.")

  cat("\033[2m🔎 Buscando no YouTube Music…\033[0m\n", file = stderr())
  found <- tryCatch(resolve(args), error = function(e) die(paste("ytm: falha na busca:", conditionMessage(e))))
  if (!length(found$tracks)) die("ytm: nada encontrado.")
  tracks <- found$tracks
  if (args$shuffle) tracks <- tracks[sample.int(length(tracks))]

  player <- new_player(tracks, found$label, args, helper)
  finished <- FALSE
  tryCatch({
    viz <- new_visualizer(args$visual, args$cores)
    mac <- new_mac(player, enabled = !args$sem_mac, notifications = !args$sem_notificacao)
    video <- new_video(player, args$qualidade_video, args$motor_video)
    finished <- run_ui(player, viz, mac, video)
  }, finally = player_close(player))
  if (finished) cat("♪ Fim da fila.\n")
}

main()
