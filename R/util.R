# Constantes, texto e cores usados por todo o tocador.

YTM_VERSION <- "2.01"  # versão do programa: segue o nome da branch da release (release-2.01)

SR <- 44100L          # amostras por segundo
CH <- 2L              # estéreo
CHUNK <- 1024L        # quadros por mensagem de áudio enviada ao ajudante
RING <- bitwShiftL(1L, 17L)  # ~3 s de áudio mono para o visualizador
FFT_N <- 4096L
FPS <- 30
AHEAD <- 0.25         # segundos de áudio entregues ao ajudante antes de tocar

RESET <- "\033[0m"
BOLD <- "\033[1m"
DIM <- "\033[2m"
SPINNER <- strsplit("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏", "")[[1]]

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a

now <- function() as.numeric(Sys.time())

# --------------------------------------------------------------------------- texto

dwidth <- function(s) nchar(s, type = "width", allowNA = TRUE, keepNA = FALSE)

trunc_text <- function(s, w) {
  if (dwidth(s) <= w) return(s)
  ch <- strsplit(s, "")[[1]]
  widths <- cumsum(nchar(ch, type = "width"))
  paste0(paste(ch[widths <= w - 1], collapse = ""), "…")
}

center_pad <- function(text, width) strrep(" ", max((width - dwidth(text)) %/% 2, 0))

fmt_time <- function(sec) {
  sec <- as.integer(max(sec, 0))
  if (sec >= 3600) sprintf("%d:%02d:%02d", sec %/% 3600, sec %/% 60 %% 60, sec %% 60)
  else sprintf("%02d:%02d", sec %/% 60, sec %% 60)
}

# --------------------------------------------------------------------------- cores

fg_code <- function(rgb) sprintf("\033[38;2;%d;%d;%dm", rgb[1], rgb[2], rgb[3])

# vetores de h, s, v (0..1) -> matriz n x 3 com valores 0..255
hsv_rgb <- function(h, s, v) {
  h <- h %% 1
  i <- floor(h * 6)
  f <- h * 6 - i
  p <- v * (1 - s)
  q <- v * (1 - f * s)
  t <- v * (1 - (1 - f) * s)
  i <- i %% 6
  r <- ifelse(i == 0, v, ifelse(i == 1, q, ifelse(i == 2, p, ifelse(i == 3, p, ifelse(i == 4, t, v)))))
  g <- ifelse(i == 0, t, ifelse(i == 1, v, ifelse(i == 2, v, ifelse(i == 3, q, ifelse(i == 4, p, p)))))
  b <- ifelse(i == 0, p, ifelse(i == 1, p, ifelse(i == 2, t, ifelse(i == 3, v, ifelse(i == 4, v, q)))))
  cbind(as.integer(r * 255), as.integer(g * 255), as.integer(b * 255))
}

# rampa entre cores (lista de c(r, g, b)) para t em 0..1
ramp <- function(stops, t) {
  stops <- do.call(rbind, stops)
  t <- pmin(pmax(t, 0), 1) * (nrow(stops) - 1)
  i <- pmin(floor(t), nrow(stops) - 2)
  f <- t - i
  a <- stops[i + 1, , drop = FALSE]
  b <- stops[i + 2, , drop = FALSE]
  matrix(as.integer(a + (b - a) * f), ncol = 3)
}

# Cada paleta recebe t (altura 0..1), x (posição horizontal 0..1) e fase (tempo); vetorizadas.
PALETTES <- list(
  "neon" = function(t, x, ph) hsv_rgb(0.52 + 0.42 * t + ph, 0.85, 1.0),
  "arco-iris" = function(t, x, ph) hsv_rgb(x * 0.85 + ph * 3, 0.8 - 0.3 * t, 0.75 + 0.25 * t),
  "fogo" = function(t, x, ph) ramp(list(c(90, 0, 0), c(220, 40, 0), c(255, 140, 0), c(255, 220, 60), c(255, 255, 220)), t),
  "oceano" = function(t, x, ph) ramp(list(c(10, 30, 120), c(0, 110, 220), c(0, 210, 230), c(180, 255, 250)), t),
  "vu" = function(t, x, ph) {
    out <- matrix(c(60L, 220L, 90L), nrow = length(t), ncol = 3, byrow = TRUE)
    out[t >= 0.6, ] <- rep(c(240L, 210L, 40L), each = sum(t >= 0.6))
    out[t >= 0.85, ] <- rep(c(250L, 60L, 50L), each = sum(t >= 0.85))
    out
  },
  # tons de cinza: a base some num fundo preto; 'cinza' começa mais claro para a barra inteira aparecer
  "preto-branco" = function(t, x, ph) ramp(list(c(0, 0, 0), c(255, 255, 255)), t),
  "cinza" = function(t, x, ph) ramp(list(c(38, 38, 38), c(255, 255, 255)), t)
)
GRAYS <- c("preto-branco", "cinza")
MODES <- c("barras", "espelho", "onda", "letra", "video", "vazio")

# Junta células de uma linha, escrevendo o código de cor só quando a cor muda.
# cols: código de cor de cada célula, ou NA quando a célula não tem cor própria (espaço).
join_cells <- function(chars, cols) {
  idx <- which(!is.na(cols))
  if (!length(idx)) return(paste(chars, collapse = ""))
  cc <- cols[idx]
  change <- c(TRUE, cc[-1] != cc[-length(cc)])  # a cor das células sem cor própria não muda
  pre <- character(length(chars))
  pre[idx[change]] <- cc[change]
  paste0(pre, chars, collapse = "")
}
