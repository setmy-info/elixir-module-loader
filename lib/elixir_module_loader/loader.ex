defmodule SetmyInfo.ElixirModuleLoader.Loader do
  @moduledoc """
  GenServer managing the lifecycle of runtime module Workers.

  ## Responsibilities

  * **Load on demand** — starts a Worker under DynamicSupervisor when a key is
    first requested; subsequent `load/1` calls return the existing PID (idempotent).
  * **Release** — terminates the Worker and removes the ETS entry.
  * **Reload** — terminates any running Worker and starts a fresh one; useful
    after a hot code swap where Worker state also needs resetting.
  * **Crash recovery** — on restart, reconciles its ETS table from the live
    WorkerRegistry so orphaned Workers are re-tracked immediately.

  ## Concurrency

  ETS is `:public` so `loaded?/1`, `list_loaded/0`, and `pid_for/1` bypass the
  GenServer mailbox (O(1)). All mutations go through `GenServer.call` to ensure
  serialisation and atomicity.

  ## Lifecycle

      load(key)    → looks up Registry, starts Worker, inserts {key, pid} into ETS
      reload(key)  → terminates old Worker (if any), starts fresh one
      release(key) → terminates Worker, deletes ETS entry
  """

  use GenServer
  require Logger

  @table :elixir_module_loader_loaded

  # ── Public API ────────────────────────────────────────────────────────────

  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec load(<<_::128>>) :: {:ok, pid()} | {:error, term()}
  def load(<<_::128>> = key) do
    GenServer.call(__MODULE__, {:load, key})
  end

  @doc """
  Reload: terminate the running Worker (if any) and start a fresh one.

  Use after `Compiler.from_source/1` when Worker state also needs resetting.
  If the key is not currently loaded, this behaves identically to `load/1`.
  """
  @spec reload(<<_::128>>) :: {:ok, pid()} | {:error, term()}
  def reload(<<_::128>> = key) do
    GenServer.call(__MODULE__, {:reload, key})
  end

  @spec release(<<_::128>>) :: :ok | {:error, :not_loaded}
  def release(<<_::128>> = key) do
    GenServer.call(__MODULE__, {:release, key})
  end

  @spec loaded?(<<_::128>>) :: boolean()
  def loaded?(<<_::128>> = key) do
    case :ets.lookup(@table, key) do
      [_] -> true
      [] -> false
    end
  end

  @spec pid_for(<<_::128>>) :: {:ok, pid()} | {:error, :not_loaded}
  def pid_for(<<_::128>> = key) do
    case :ets.lookup(@table, key) do
      [{^key, pid}] -> {:ok, pid}
      [] -> {:error, :not_loaded}
    end
  end

  @spec list_loaded() :: [<<_::128>>]
  def list_loaded do
    :ets.tab2list(@table) |> Enum.map(fn {key, _pid} -> key end)
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(_init_arg) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    reconcile_with_worker_registry()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:load, key}, _from, state) do
    case :ets.lookup(@table, key) do
      [{^key, pid}] ->
        {:reply, {:ok, pid}, state}

      [] ->
        {:reply, start_worker(key), state}
    end
  end

  @impl true
  def handle_call({:reload, key}, _from, state) do
    terminate_worker(key)
    {:reply, start_worker(key), state}
  end

  @impl true
  def handle_call({:release, key}, _from, state) do
    case :ets.lookup(@table, key) do
      [{^key, _pid}] ->
        terminate_worker(key)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_loaded}, state}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp start_worker(key) do
    case SetmyInfo.ElixirModuleLoader.Registry.lookup(key) do
      {:ok, impl_module} ->
        case DynamicSupervisor.start_child(
               SetmyInfo.ElixirModuleLoader.DynamicSupervisor,
               {SetmyInfo.ElixirModuleLoader.Worker, {key, impl_module}}
             ) do
          {:ok, pid} ->
            :ets.insert(@table, {key, pid})

            Logger.info(
              "[Loader] loaded #{Base.encode16(key)} via #{inspect(impl_module)} (#{inspect(pid)})"
            )

            {:ok, pid}

          {:error, reason} = error ->
            Logger.warning("[Loader] failed to load #{Base.encode16(key)}: #{inspect(reason)}")
            error
        end

      {:error, :not_found} = error ->
        Logger.warning("[Loader] key #{Base.encode16(key)} is not registered in Registry")
        error
    end
  end

  defp terminate_worker(key) do
    case :ets.lookup(@table, key) do
      [{^key, pid}] ->
        DynamicSupervisor.terminate_child(SetmyInfo.ElixirModuleLoader.DynamicSupervisor, pid)
        :ets.delete(@table, key)
        Logger.info("[Loader] released #{Base.encode16(key)} (#{inspect(pid)})")

      [] ->
        :ok
    end
  end

  defp reconcile_with_worker_registry do
    entries =
      Registry.select(SetmyInfo.ElixirModuleLoader.WorkerRegistry, [
        {{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}
      ])

    if entries != [] do
      :ets.insert(@table, entries)

      Logger.info(
        "[Loader] reconciled #{length(entries)} surviving Worker(s) from WorkerRegistry"
      )
    end
  end
end
