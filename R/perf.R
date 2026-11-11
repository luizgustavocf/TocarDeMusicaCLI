# HUD: CPU e memória do tocador (R + ytm-helper + yt-dlp + ffmpeg + timg), uma vez por segundo.

new_perf <- function() {
  pm <- new.env()
  pm$cpu <- 0       # % de um núcleo, como no Monitor de Atividade
  pm$mem <- 0       # bytes (memória residente)
  pm$visible <- TRUE
  pm$last <- 0
  pm$times <- c()   # pid -> tempo de CPU na última leitura
  pm$me <- ps::ps_handle()
  pm$procs <- list(pm$me)
  pm$tree_at <- 0
  pm
}

perf_update <- function(pm) {
  t <- now()
  if (!pm$visible || t - pm$last < 1) return(invisible())
  dt <- if (pm$last > 0) t - pm$last else NA
  pm$last <- t
  # listar os processos filhos percorre todos os processos do sistema: só a cada 5 s
  if (t - pm$tree_at >= 5) {
    pm$tree_at <- t
    pm$procs <- c(list(pm$me), tryCatch(ps::ps_children(pm$me, recursive = TRUE), error = function(e) list()))
  }
  procs <- pm$procs
  cpu <- mem <- 0
  times <- c()
  for (h in procs) {
    tryCatch({
      pid <- as.character(ps::ps_pid(h))
      ct <- ps::ps_cpu_times(h)
      used <- ct[["user"]] + ct[["system"]]
      mem <- mem + ps::ps_memory_info(h)[["rss"]]
      if (!is.na(dt) && pid %in% names(pm$times)) cpu <- cpu + (used - pm$times[[pid]]) / dt * 100
      times[pid] <- used
    }, error = function(e) NULL)
  }
  pm$times <- times
  if (!is.na(dt)) pm$cpu <- max(cpu, 0)
  pm$mem <- mem
}
