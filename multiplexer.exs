#! /usr/bin/env elixir



# ~~~~~~~~~~~~~~~~~~~~~ Documentation ~~~~~~~~~~~~~~~~~~~~ #
"""
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
"""
# ~~~~~~~~~~~~~~~~~~~~~ Documentation ~~~~~~~~~~~~~~~~~~~~ #



# ~~~~~~~~~~~~~~~~~~~~~~ Source code ~~~~~~~~~~~~~~~~~~~~~ #
# ⚠️ FOR CONFIG JUMP TO BOTTOM FILE ⚠️

Mix.install([
  {:poolboy, "~> 1.5"},
  {:plug_cowboy, "~> 2.0"},
  {:httpoison, "~> 1.8"}
])

defmodule Multiplexer.Application do
  require Logger
  use Application

  defp poolboy_config do
    [
      name: {:local, :worker},
      worker_module: Multiplexer.Pool.Worker,
      size: Application.get_env(:multiplexer, :pool_size, 3),
      max_overflow: Application.get_env(:multiplexer, :pool_max_overflow, 3),
      strategy: Application.get_env(:multiplexer, :pool_strategy, :fifo)
    ]
  end

  def start(_type, _args) do
    children = [
      {Multiplexer.Pool.PortRing, Enum.to_list(Application.get_env(:multiplexer, :service_port_range, 1100..1150))},
      {Plug.Cowboy, scheme: :http, plug: Multiplexer.Http, port: Application.get_env(:multiplexer, :http_port)},
      :poolboy.child_spec(:worker, poolboy_config())
    ]

    pattern = Application.get_env(:multiplexer, :service_kill_pattern)

    System.shell("ps aux | grep #{pattern} | tr -s ' ' | cut -d ' ' -f 2 | xargs kill -9")

    opts = [strategy: :one_for_one, name: Multiplexer.Pool.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

defmodule Multiplexer.Pool.Worker do
  require Logger
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  def init(_) do
    Process.flag(:trap_exit, true)

    state = %{
      http_port: Multiplexer.Pool.PortRing.get_port
    }

    {:ok, state, {:continue, :start_render_server}}
  end

  def handle_continue(:start_render_server, state) do
    http_port_string = to_string(state.http_port)
    cmd_tempate =
      Application.get_env(:multiplexer, :service_start_process_cmd)
      |> String.replace("%PORT%", http_port_string)

    port = Port.open({:spawn, cmd_tempate}, [:binary])
    port_info = Port.info(port)

    new_state = Map.merge(state, %{port: port, port_info: port_info})

    Logger.info("Start new process #{port_info[:name]}, pid: #{port_info[:os_pid]}")

    case Application.get_env(:multiplexer, :service_start_delay_ms, :wait_first_output) do
      :wait_first_output ->
        Logger.debug("Waiting first message..., timeout: 30 seconds")
        receive do
          {^port, {:data, msg}} ->
            Logger.debug("""
              First message received, message:
                #{msg}
            """)

            # Иногда нужно еще немножко подождать... =)
            Process.sleep(100)
        after
          30_000 ->
            Logger.error("Waiting first message timeout, terminating...")
            Process.exit(self, :kill)
        end

      ms when is_number(ms) -> Process.sleep(Application.get_env(:multiplexer, :service_start_delay_ms, 1_000))
    end

    {:noreply, new_state}
  end

  def handle_call({:request, {method, url, body, headers}}, _from, %{http_port: http_port} = state) do
    base_url = Application.get_env(:multiplexer, :service_http_base_url)
    url = "#{base_url}:#{http_port}#{url}"

    Logger.debug("Prepare url: #{url}")

    res = HTTPoison.request(
      method,
      url,
      body,
      headers,
      timeout: Application.get_env(:multiplexer, :http_proxy_timeout, 10_000),
      recv_timeout: Application.get_env(:multiplexer, :http_proxy_timeout, 10_000)
    )

    {:reply, res, state}
  end

  def handle_info({_port_id, {:data, msg}}, %{port_info: port_info} = state) do
    Logger.debug("OS PID: #{inspect(port_info[:os_pid])} | message: #{String.trim(msg)}")
    {:noreply, state}
  end

  def handle_info({:EXIT, _port, :normal}, %{port_info: port_info} = state) do
    Logger.info("OS PID: #{port_info[:os_pid]} | exited, restart...")
    {:noreply, state, {:continue, :start_render_server}}
  end

  def handle_info(request, state) do
    Logger.debug("Handle info #{inspect(request)}")
    {:noreply, state}
  end

  def terminate(:shutdown, %{port_info: port_info}) do
    Logger.info("Terminate process: #{inspect(port_info[:name])} - pid: #{port_info[:os_pid]}, unused resource")

    case System.shell("kill -9 #{port_info[:os_pid]}") do
      {_, 0} -> nil
      s -> Logger.warn("Command: \"kill -9 #{port_info[:os_pid]}\" return not zero status, return atom: #{inspect(s)}")
    end

    :ok
  end
  def terminate(reason, _state), do: Logger.debug("[#{inspect( self() )}] Terminate with reason: #{inspect(reason)}")
end

defmodule Multiplexer.Pool.PortRing do
  use Agent
  def start_link(service_port_range), do: Agent.start_link(fn -> service_port_range end, name: __MODULE__)
  def get_port, do: Agent.get_and_update(__MODULE__, fn [x | xs] -> {x, xs ++ [x]} end)
end

defmodule Multiplexer.Http do
  import Plug.Conn
  require Logger

  def init(options), do: options

  def call(conn, _opts) do
    t1 = :erlang.timestamp()

    method = conn.method |> String.downcase |> String.to_atom

    query_string = conn.query_string != "" && "?#{conn.query_string}" || ""
    url = "#{conn.request_path}#{query_string}"
    headers = conn.req_headers
    body = get_body(conn)

    {response, t2, t3} = :poolboy.transaction(:worker, fn pid ->
      t2 = :erlang.timestamp()

      {:ok, response} = GenServer.call(pid, {:request, {method, url, body, headers}}, :infinity)

      t3 = :erlang.timestamp()

      {response, t2, t3}
    end, :infinity)

    conn = Enum.reduce(response.headers, conn, fn {k, v}, acc ->
      put_resp_header(acc, String.downcase(k), v)
    end) |> delete_resp_header("transfer-encoding")

    t4 = :erlang.timestamp()

    work_time = :timer.now_diff(t3, t2)
    all_time = :timer.now_diff(t4, t1)
    without_work_time = all_time - work_time

    Logger.info("""
      #{method |> to_string |> String.upcase} #{url}
      Status: #{response.status_code}
      Times:
        without external time: #{without_work_time / 1000}ms,
        render time: #{work_time / 1000}ms,
        all time: #{all_time / 1000}ms
    """)

    send_resp(conn, response.status_code, response.body)
  end

  defp get_body(conn) do
    case read_body(conn), do: (
      {:ok, body, _conn} -> body
      {:more, body, conn} ->
        {:stream,
          Stream.resource(
            fn -> {body, conn} end,
            fn
              {body, conn} -> {[body], conn}
              nil -> {:halt, nil}
              conn ->
                case read_body(conn) do
                  {:ok, body, _conn} -> {[body], nil}
                  {:more, body, conn} -> {[body], conn}
                end
            end,
            fn _ -> nil end
          )
        }
    )
  end
end

# ~~~~~~~~~~~~~~~~~~~~~~ Source code ~~~~~~~~~~~~~~~~~~~~~ #



# ~~~~~~~~~~~~~~~~~~~~~~~~ Script ~~~~~~~~~~~~~~~~~~~~~~~~ #

base_logger_level = :error
application_logger_level = :debug


:ok = Application.stop(:logger)

[config_path] = System.argv()
config = Config.Reader.read!(config_path)
Application.put_all_env(config)

:ok = Application.ensure_started(:logger)
Logger.configure(level: base_logger_level)

[ Multiplexer.Application, Multiplexer.Pool.Worker, Multiplexer.Pool.PortRing, Multiplexer.Http ]
|> Enum.map(fn mod -> Logger.put_module_level(mod, application_logger_level) end)

[ :cowboy, :plug, :poolboy, :httpoison ]
|> Enum.map(fn app -> :ok = Application.ensure_started(app) end)

Multiplexer.Application.start(nil, nil)

receive do
  :terminate -> System.stop()
  _ -> nil
end
