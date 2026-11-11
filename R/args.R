# Opções da linha de comando e a ajuda (ytm -h).

HELP_TEXT <- 'uso: ytm [opções] <busca ou link>

Toca músicas e playlists do YouTube Music no terminal, com visualizador de áudio.

o que tocar:
  busca ou link        termo de busca, ou link do YouTube / YouTube Music
  -p, --playlist       buscar uma playlist em vez de uma música
  -n N                 enfileirar os N primeiros resultados da busca
  --radio              depois da música, continuar com o rádio (mix) dela
  --single             num link com &list=, tocar só a música
  -s, --shuffle        ordem aleatória
  -r, --repeat         repetir a fila ao terminar

som e tela:
  --volume 0-100       volume inicial (padrão 100)
  --visual VISUAL      estilo da animação: barras, espelho, onda, letra, video, vazio (padrão barras)
  --cores PALETA       paleta de cores: neon, arco-iris, fogo, oceano, vu, preto-branco, cinza
                       (padrão neon)
  --sync MS            atraso extra da animação, da letra e do vídeo em ms (ex.: 200 para fones
                       Bluetooth)

vídeo (visual video):
  --qualidade-video Q  alta (720p, 30 qps, 2×2 pixels por caractere), media (480p, 24 qps) ou
                       baixa (360p, 15 qps); padrão alta
  --motor-video MOTOR  timg (padrão, se instalado; redesenha só o que muda) ou interno (o desenho
                       próprio do ytm)

macOS:
  --sem-notificacao    não mostrar notificação a cada música
  --sem-mac            não integrar com o macOS (Tocando Agora, barra de menus e notificações)

ajuda:
  -h, -help, --help    mostrar esta ajuda e sair

teclas durante a música:
  espaço        pausar / continuar
  ← / →         voltar / avançar 10 s
  n / p         próxima / anterior
  ↑ / ↓, + / -  volume
  v             trocar visual (barras, espelho, onda, letra, video, vazio)
  c             trocar paleta de cores
  g             trocar a qualidade do vídeo (alta → media → baixa)
  m             trocar o motor do vídeo (timg ↔ interno)
  [ / ]         ajustar a sincronia da animação, da letra e do vídeo (±20 ms)
  r             repetir a fila
  h             mostrar / esconder o HUD de CPU e memória
  q             sair

exemplos:
  ytm bohemian rhapsody                  toca a primeira música encontrada
  ytm -n 10 daft punk                    enfileira os 10 primeiros resultados
  ytm -p rock classico                   busca uma playlist e toca
  ytm --radio tiny dancer                toca a música e continua com o rádio dela
  ytm --visual letra garota de ipanema   abre direto na letra sincronizada
  ytm --visual video bohemian rhapsody   abre direto no videoclipe
  ytm -s -r "https://music.youtube.com/playlist?list=..."   aleatório, repetindo
'

# nome da opção -> (campo, tipo, valores aceitos)
OPTIONS <- list(
  "--playlist" = list("playlist", "flag"), "-p" = list("playlist", "flag"),
  "-n" = list("n", "int"),
  "--radio" = list("radio", "flag"),
  "--single" = list("single", "flag"),
  "--shuffle" = list("shuffle", "flag"), "-s" = list("shuffle", "flag"),
  "--repeat" = list("repeat", "flag"), "-r" = list("repeat", "flag"),
  "--volume" = list("volume", "int"),
  "--visual" = list("visual", "choice", MODES),
  "--cores" = list("cores", "choice", names(PALETTES)),
  "--sync" = list("sync", "int"),
  "--qualidade-video" = list("qualidade_video", "choice", c("alta", "media", "baixa")),
  "--motor-video" = list("motor_video", "choice", c("timg", "interno")),
  "--sem-notificacao" = list("sem_notificacao", "flag"),
  "--sem-mac" = list("sem_mac", "flag"),
  "-h" = list("help", "flag"), "-help" = list("help", "flag"), "--help" = list("help", "flag")
)

arg_error <- function(msg) {
  cat("uso: ytm [opções] <busca ou link>\nytm: erro: ", msg, "\nPara ver todas as opções: ytm -h\n",
      sep = "", file = stderr())
  quit(save = "no", status = 2)
}

parse_args <- function(argv) {
  a <- list(query = character(), playlist = FALSE, n = 1L, radio = FALSE, single = FALSE,
            shuffle = FALSE, `repeat` = FALSE, volume = 100L, visual = "barras", cores = "neon",
            sync = 0L, qualidade_video = "alta", motor_video = "timg", sem_notificacao = FALSE,
            sem_mac = FALSE, help = FALSE)
  i <- 1
  only_words <- FALSE
  while (i <= length(argv)) {
    w <- argv[i]
    i <- i + 1
    if (only_words || !startsWith(w, "-") || w == "-") {
      a$query <- c(a$query, w)
      next
    }
    if (w == "--") {
      only_words <- TRUE
      next
    }
    value <- NULL
    name <- w
    if (startsWith(w, "--") && grepl("=", w, fixed = TRUE)) {  # --volume=50
      name <- sub("=.*", "", w)
      value <- sub("^[^=]*=", "", w)
    }
    opt <- OPTIONS[[name]]
    if (is.null(opt) && !startsWith(w, "--") && nchar(w) > 2) {
      first <- OPTIONS[[substr(w, 1, 2)]]
      if (!is.null(first) && first[[2]] != "flag") {  # -n10
        opt <- first
        name <- substr(w, 1, 2)
        value <- substring(w, 3)
      } else {  # -sr: várias opções curtas juntas
        flags <- paste0("-", strsplit(substring(w, 2), "")[[1]])
        if (all(vapply(flags, function(l) identical(OPTIONS[[l]][[2]], "flag"), logical(1)))) {
          for (l in flags) a[[OPTIONS[[l]][[1]]]] <- TRUE
          next
        }
      }
    }
    if (is.null(opt)) arg_error(sprintf("opção desconhecida: %s", w))
    field <- opt[[1]]
    kind <- opt[[2]]
    if (kind == "flag") {
      if (!is.null(value)) arg_error(sprintf("a opção %s não recebe valor", name))
      a[[field]] <- TRUE
      if (field == "help") return(a)
      next
    }
    if (is.null(value)) {
      if (i > length(argv)) arg_error(sprintf("a opção %s precisa de um valor", name))
      value <- argv[i]
      i <- i + 1
    }
    if (kind == "int") {
      if (!grepl("^[+-]?[0-9]+$", value)) arg_error(sprintf("a opção %s precisa de um número inteiro (recebeu '%s')", name, value))
      a[[field]] <- as.integer(value)
    } else {
      if (!value %in% opt[[3]]) {
        arg_error(sprintf("valor inválido para %s: '%s' (aceitos: %s)", name, value, paste(opt[[3]], collapse = ", ")))
      }
      a[[field]] <- value
    }
  }
  if (!length(a$query)) arg_error("falta o que tocar: uma busca ou um link")
  a
}
