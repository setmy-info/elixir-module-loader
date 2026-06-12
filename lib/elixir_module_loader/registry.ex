defmodule SetmyInfo.ElixirModuleLoader.Registry do
  @moduledoc """
  ETS-backed registry mapping 128-bit binary keys to module atoms.

  ## Key type

  All keys are 16-byte binaries (`<<_::128>>`). Use
  `SetmyInfo.ElixirModuleLoader.generate_key/0` to create cryptographically-random keys.

  ## Concurrency

  Reads bypass the GenServer (direct ETS lookup, O(1), safe for many concurrent
  readers). Writes are serialised through the GenServer to prevent race conditions
  on concurrent registrations.

  ## Design

  This registry is intentionally separate from the Loader's tracking table.
  A key can be registered without having an active Worker (lazy loading), and
  a Worker can be released without removing the key registration (it can be
  reloaded later).

  Compilation serialisation lives in its own process —
  `SetmyInfo.ElixirModuleLoader.CompileLock` — so a slow compile can never
  block registry writes.
  """

  use GenServer
  require Logger

  @table :elixir_module_loader_registry

  # ── Public API ────────────────────────────────────────────────────────────

  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc "Register a 128-bit key → module atom mapping."
  @spec register(<<_::128>>, module()) :: :ok
  def register(<<_::128>> = key, module_name) when is_atom(module_name) do
    GenServer.call(__MODULE__, {:register, key, module_name})
  end

  @doc "Look up the module atom for a 128-bit key."
  @spec lookup(<<_::128>>) :: {:ok, module()} | {:error, :not_found}
  def lookup(<<_::128>> = key) do
    case :ets.lookup(@table, key) do
      [{^key, module_name}] -> {:ok, module_name}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Register many `{key, module}` pairs at once — more efficient than repeated
  `register/2`.

  Every spec must be a `{<<_::128>>, atom}` tuple. If any spec is malformed the
  whole batch is rejected with `{:error, :invalid_spec}` and nothing is
  inserted, preserving the 128-bit key contract that `register/2` enforces.
  """
  @spec register_many([{<<_::128>>, module()}]) :: :ok | {:error, :invalid_spec}
  def register_many(specs) when is_list(specs) do
    if Enum.all?(specs, &valid_spec?/1) do
      GenServer.call(__MODULE__, {:register_many, specs})
    else
      {:error, :invalid_spec}
    end
  end

  @doc "Remove a key→module mapping. Does NOT unload any active Worker."
  @spec unregister(<<_::128>>) :: :ok
  def unregister(<<_::128>> = key) do
    GenServer.call(__MODULE__, {:unregister, key})
  end

  @doc "Update the module atom a key points to."
  @spec update(<<_::128>>, module()) :: :ok | {:error, :not_found}
  def update(<<_::128>> = key, new_module) when is_atom(new_module) do
    GenServer.call(__MODULE__, {:update, key, new_module})
  end

  @doc "True if a key is currently registered."
  @spec registered?(<<_::128>>) :: boolean()
  def registered?(<<_::128>> = key), do: :ets.member(@table, key)

  @doc "Return all registered {key, module} pairs."
  @spec list_registered() :: [{<<_::128>>, module()}]
  def list_registered, do: :ets.tab2list(@table)

  @doc "Number of registered keys."
  @spec count() :: non_neg_integer()
  def count, do: :ets.info(@table, :size)

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(_init_arg) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    Logger.debug("[Registry] initialised")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, key, module_name}, _from, state) do
    :ets.insert(@table, {key, module_name})
    Logger.debug("[Registry] registered #{inspect(module_name)} under #{Base.encode16(key)}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:register_many, specs}, _from, state) do
    :ets.insert(@table, specs)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister, key}, _from, state) do
    :ets.delete(@table, key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update, key, new_module}, _from, state) do
    case :ets.member(@table, key) do
      true ->
        :ets.insert(@table, {key, new_module})
        {:reply, :ok, state}

      false ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp valid_spec?({<<_::128>>, module_name}) when is_atom(module_name), do: true
  defp valid_spec?(_), do: false
end
