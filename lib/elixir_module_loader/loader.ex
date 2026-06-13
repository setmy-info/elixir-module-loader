defmodule SetmyInfo.ElixirModuleLoader.Loader do
  @moduledoc """
  GenServer tracking the loaded working set and managing code memory.

  The library does not wrap calls in any process: `load/1` makes the module's
  code available in the VM and returns the **module itself** — the caller
  invokes its functions directly (`module.fun(args)` or `apply/3`). What this
  GenServer owns is the bookkeeping around that:

  * **Load on demand** — restores the module's code from the registry's
    `beam_source` if it is not in the VM (e.g. after an earlier release),
    marks the key as loaded, returns the module. Idempotent.
  * **Release** — removes the key from the working set and — when the code is
    library-managed (`beam_source` present) and no other loaded key uses the
    same module — deletes and soft-purges the module's code from the VM, so
    releasing frees code memory.
  * **Reload** — re-restores the code from its source (recompiles a `.ex`,
    reloads a `.beam`/binary), hot-swapping the running version.

  ## Concurrency

  ETS is `:protected` — `loaded?/1`, `module_for/1`, and `list_loaded/0` read
  it from any process without touching the GenServer mailbox (O(1)), while
  only the Loader process itself can write. All mutations go through
  `GenServer.call` to ensure serialisation and atomicity.

  ## Lifecycle

      load(key)    → restores code if purged, tracks {key, module}, returns module
      reload(key)  → forces a code re-restore (hot swap), returns module
      release(key) → drops tracking, purges unused library-managed code
  """

  use GenServer
  require Logger

  alias SetmyInfo.ElixirModuleLoader.{Compiler, Registry}

  @table :elixir_module_loader_loaded

  # Loading may trigger a code restore that recompiles a source file, so the
  # call timeout must comfortably exceed normal compilation time.
  @load_timeout 60_000

  # ── Public API ────────────────────────────────────────────────────────────

  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Load the entry registered under `key`: make its code available in the VM
  (restoring it from the registered source if needed) and return the module.
  Idempotent — loading a loaded key returns the same module.
  """
  @spec load(<<_::128>>) :: {:ok, module()} | {:error, term()}
  def load(<<_::128>> = key) do
    case module_for(key) do
      {:ok, module} -> {:ok, module}
      {:error, :not_loaded} -> GenServer.call(__MODULE__, {:load, key}, @load_timeout)
    end
  end

  @doc """
  Re-restore the module's code from its registered source — recompile the
  `.ex`, reload the `.beam` file or binary — hot-swapping the loaded version.
  Loads the key if it was not loaded.
  """
  @spec reload(<<_::128>>) :: {:ok, module()} | {:error, term()}
  def reload(<<_::128>> = key) do
    GenServer.call(__MODULE__, {:reload, key}, @load_timeout)
  end

  @doc """
  Release the key: remove it from the loaded working set and purge the
  module's code from the VM when it is library-managed and no other loaded
  key still uses it.
  """
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

  @doc "The module a loaded key resolves to, without loading it."
  @spec module_for(<<_::128>>) :: {:ok, module()} | {:error, :not_loaded}
  def module_for(<<_::128>> = key) do
    case :ets.lookup(@table, key) do
      [{^key, module, _loaded_at}] -> {:ok, module}
      [] -> {:error, :not_loaded}
    end
  end

  @doc "When the key was loaded, for external usage trackers."
  @spec loaded_at(<<_::128>>) :: {:ok, DateTime.t()} | {:error, :not_loaded}
  def loaded_at(<<_::128>> = key) do
    case :ets.lookup(@table, key) do
      [{^key, _module, loaded_at}] -> {:ok, loaded_at}
      [] -> {:error, :not_loaded}
    end
  end

  @spec list_loaded() :: [<<_::128>>]
  def list_loaded do
    :ets.tab2list(@table) |> Enum.map(fn {key, _module, _loaded_at} -> key end)
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(_init_arg) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:load, key}, _from, state) do
    case :ets.lookup(@table, key) do
      [{^key, module, _t}] ->
        {:reply, {:ok, module}, state}

      [] ->
        {:reply, do_load(key, _force_restore = false), state}
    end
  end

  @impl true
  def handle_call({:reload, key}, _from, state) do
    {:reply, do_load(key, _force_restore = true), state}
  end

  @impl true
  def handle_call({:release, key}, _from, state) do
    case :ets.lookup(@table, key) do
      [{^key, module, _t}] ->
        :ets.delete(@table, key)
        Logger.info("[Loader] released #{Base.encode16(key)} (#{inspect(module)})")
        maybe_purge(key, module)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_loaded}, state}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp do_load(key, force_restore) do
    case Registry.lookup_entry(key) do
      {:ok, module, meta} ->
        with :ok <- ensure_code_loaded(module, meta, force_restore) do
          :ets.insert(@table, {key, module, DateTime.utc_now()})
          Logger.info("[Loader] loaded #{Base.encode16(key)} → #{inspect(module)}")
          {:ok, module}
        end

      {:error, :not_found} = error ->
        Logger.error("[Loader] key #{Base.encode16(key)} is not registered in Registry")
        error
    end
  end

  # Composite targets run on library code; nothing to restore.
  defp ensure_code_loaded(_module, %{target: {:composite, _}}, _force), do: :ok

  defp ensure_code_loaded(module, meta, force) do
    if not force and :code.is_loaded(module) != false do
      :ok
    else
      restore_code(module, meta[:beam_source])
    end
  end

  defp restore_code(_module, nil), do: :ok

  defp restore_code(module, {:binary, beam}),
    do: Compiler.from_beam_binary(module, beam)

  defp restore_code(module, {:file, path}) do
    with {:ok, ^module} <- Compiler.from_beam_file(path), do: :ok
  end

  defp restore_code(module, {:ex_file, path}) do
    with {:ok, modules} <- Compiler.from_file(path) do
      if List.keymember?(modules, module, 0),
        do: :ok,
        else: {:error, {:module_not_in_file, module, path}}
    end
  end

  # Releasing must also free the module's code memory (requirements):
  # when the code is library-managed (beam_source present — i.e. restorable)
  # and no other loaded key still uses the same module, delete + soft-purge it.
  # Registered-but-unloaded keys are safe: their next load restores the code.
  defp maybe_purge(key, module) do
    with {:ok, ^module, %{beam_source: source}} when not is_nil(source) <-
           Registry.lookup_entry(key),
         [] <- :ets.match(@table, {:"$1", module, :_}) do
      # Clear any stale old version first (hot swaps leave one behind),
      # otherwise :code.delete refuses to retire the current version.
      Compiler.purge(module)
      Compiler.delete(module)

      unless Compiler.purge(module) do
        Logger.warning(
          "[Loader] soft purge of #{inspect(module)} skipped — " <>
            "processes still running its old code"
        )
      end

      Logger.info("[Loader] purged code of #{inspect(module)} after release")
    else
      _ -> :ok
    end
  end
end
