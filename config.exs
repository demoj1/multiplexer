import Config


config :multiplexer,
  pool_size: 1,
  pool_max_overflow: 25,
  pool_strategy: :fifo,
  # -----
  http_port: 4334,
  http_proxy_timeout: 5 * 60 * 1000,
  # -----
  service_http_base_url: "http://localhost",
  service_port_range: 8900..9000,
  service_start_process_cmd: "node render_server_wrapper.js %PORT%",
  # Можно установить в :wait_first_output
  # Тогда сервис будет считаться запущеным, если он
  # отправил что либо в stdout, зачастую сервисы когда запускаются пишут туда порт на котором запущены
  # это может быть хорошим индикатором запущенности
  service_start_delay_ms: :wait_first_output,
  # Паттерн для убийства процессов, будет подставлен в строку:
  # System.shell("ps aux | grep ⚠️СЮДА⚠️ | tr -s ' ' | cut -d ' ' -f 2 | xargs kill -9")
  # Вызывается при старте сервиса, полезен в случае ненормального завершения процесса
  service_kill_pattern: "render_server_wrapper.js"


config :logger,
  backends: [:console],
  truncate: :infinity,
  level: :debug,
  utc_log: true,
  handle_otp_reports: true,
  handle_sasl_reports: true

config :logger, :console,
  format: "=» $time [$level] \n\n$message\n\n metadata: $metadata\n\n",
  metadata: [:module, :function, :line, :pid, :all_time, :work_time, :without_work_time]