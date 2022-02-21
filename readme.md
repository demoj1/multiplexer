# Идея
  Не все сервисы умеют обрабатывать большой поток HTTP запросов.  
  В том числе, однопоточные сервисы на python, nodejs, ...  
  Данный скрипт умеет поднимать пул таких сервисов, назначать им
  рандомные порты и распределять нагрузку между ними.
# Установка
  Для запуска требуется Elixir >= 1.12.0-otp-22 и Erlang >= 22.2.0
  Установить можно с помощью asdf:
  ```
  asdf plugin add erlang && \
  asdf plugin add elixir && \
  asdf install erlang 22.2.4 && \
  asdf install elixir 1.12.0-otp-22
  ```
  После установки обязательно нужно проверить версию текущего elixir.
  Сделать это можно выполнив команду `iex`.
  Версии в выводе должны совпадать, вывод будет примерно такой:
  ```
  Erlang/OTP 22 [erts-10.6.2] [source] [64-bit] [smp:32:32] [ds:32:32:10] [async-threads:1] [hipe]
  Interactive Elixir (1.12.0) - press Ctrl+C to exit (type h() ENTER for help)
  ```
  Для запуска через systemd одним из вариантов может быть asdf, сделать это
  проще всего через скрипт:
  ```
  #!/bin/bash
  source /root/.bashrc
  source /root/.asdf/asdf.sh
  asdf global elixir 1.12.0-otp-22
  asdf global erlang 22.2.4
  elixir multiplexer config.exs
  ```
  И его уже запускаем как UNIT, пример:
  ```
  [Unit]
  Description=Muliplexer
  [Service]
  Type=simple
  ExecStart=/start_script.sh
  TimeoutStopSec=2
  KillMode=control-group
  User=root
  Group=root
  WorkingDirectory=⚠️ Не забываем поменять WorkingDirectory на директорию где находиться multiplexer.exs
  StandardOutput=syslog
  StandardError=syslog
  SyslogIdentifier=multiplexer
  [Install]
  WantedBy=multi-user.target
  ```
# Описание работы сервиса
  Перед запуском сервис пытается остановить все ранее запущенные
  воркеры, для этого выполнется команда kill с параметром `service_kill_pattern` из конфига.  
  После запуска поднимается `pool_size` сервисов, запускает они как Порты (смотреть Erlang Port)  
  с командой `service_start_process_cmd` и указание http порта, http порт выбирается из пула портов,
  пулл реализован на структуре **кольцо/ring**.  
  От сервисов ожидается выхлоп в stdout либо прошествие `service_start_delay_ms` времени.  
  После этого сервис считается запущенным и готовым к работе.  
  В случае если сервис падает, Порт отлавливает это событие и перезапускает воркера.  
  Данный скрипт начинает слушать `http_port`.  
  На каждый запрос происходит проксирование на случайный воркер из пула свободных.  
  Проксирование отрабатывает как reverse_proxy, воркер не знает что запрос проксировался.  
  Если запросов приходит больше, чем запущено воркеров, начинают использоваться временные.  
  Их число можно задать в `pool_max_overflow`.  
  Например pool_size: 1, pool_max_overflow: 2.  
  В сервис пришло одновременно 2 запроса, один запрос сразу же попадет в 1 воркера, а для
  второго запроса, будет запущен еще один воркер, после отработки запроса, один из воркеров
  будет убит. Кто будет убит рулиться параметром `pool_strategy`, есть fifo и lifo.  
  По хорошему следует использовать fifo, так как сервисы могут течь по памяти, а в случае fifo  
  оставаться в пуле всегда будут последние поднятые.  
# Пример конфига
  ```
  import Config
  config :multiplexer,
    pool_size: 5,
    pool_max_overflow: 15,
# ------------------------------
    http_port: 3000,
    http_proxy_timeout: 5 * 60 * 1000,
# ------------------------------
    service_http_base_url: "http://localhost",
    service_port_range: 10300..10350,
    service_start_process_cmd: "node index.js %PORT%",
# Можно установить в :wait_first_output
# Тогда сервис будет считаться запущеным, если он
# отправил что либо в stdout, зачастую сервисы когда запускаются пишут туда порт на котором запущены
# это может быть хорошим индикатором запущенности
    service_start_delay_ms: :wait_first_output,
# Паттерн для убийства процессов, будет подставлен в строку:
# System.shell("ps aux | grep ⚠️СЮДА⚠️ | tr -s ' ' | cut -d ' ' -f 2 | xargs kill -9")
# Вызывается при старте сервиса, полезен в случае ненормального завершения процесса
    service_kill_pattern: "index.js"
  ```
