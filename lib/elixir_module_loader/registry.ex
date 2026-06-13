defmodule SetmyInfo.ElixirModuleLoader.Registry do
  @moduledoc """
  ETS-backed registry mapping 128-bit binary keys to loadable targets.

  ## Entries

  Every entry is `{key, module, meta}`. `module` is the module atom backing
  the key (for composites it is the `Composite` interpreter). `meta` is a map:

  * `:target` — what the key addresses:
    * `{:module, module}` — a whole module (the classic case)
    * `{:function, {module, function, arity}}` — a single loadable function
    * `{:composite, ast}` — a composition of other keys (see `Composite`)
  * `:beam_source` — how the module's code can be restored after a purge:
    `{:binary, beam}`, `{:file, beam_path}`, `{:ex_file, source_path}` or
    `nil` (code is not managed by the library — never purged on release)
  * `:pure` — the registrant declares the function side-effect free; pure
    function targets are memoised and executed in the caller process.

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
  @memo :elixir_module_loader_memo

  @type meta :: %{
          target:
            {:module, module()}
            | {:function, {module(), atom(), non_neg_integer()}}
            | {:composite, term()},
          beam_source: {:binary, binary()} | {:file, Path.t()} | {:ex_file, Path.t()} | nil,
          pure: boolean()
        }

  # ── Public API ────────────────────────────────────────────────────────────

  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Register a 128-bit key → module mapping with optional metadata.

  `meta` keys: `:target`, `:beam_source`, `:pure` (see the moduledoc).
  Missing keys are filled with defaults for a plain module registration.
  """
  @spec register(<<_::128>>, module(), map()) :: :ok
  def register(<<_::128>> = key, module_name, meta \\ %{}) when is_atom(module_name) do
    GenServer.call(__MODULE__, {:register, key, module_name, normalize_meta(module_name, meta)})
  end

  @doc "Look up the module atom for a 128-bit key."
  @spec lookup(<<_::128>>) :: {:ok, module()} | {:error, :not_found}
  def lookup(<<_::128>> = key) do
    case :ets.lookup(@table, key) do
      [{^key, module_name, _meta}] -> {:ok, module_name}
      [] -> {:error, :not_found}
    end
  end

  @doc "Look up the full `{module, meta}` entry for a key."
  @spec lookup_entry(<<_::128>>) :: {:ok, module(), meta()} | {:error, :not_found}
  def lookup_entry(<<_::128>> = key) do
    case :ets.lookup(@table, key) do
      [{^key, module_name, meta}] -> {:ok, module_name, meta}
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
      entries = Enum.map(specs, fn {key, mod} -> {key, mod, normalize_meta(mod, %{})} end)
      GenServer.call(__MODULE__, {:register_many, entries})
    else
      {:error, :invalid_spec}
    end
  end

  @doc "Remove a key→module mapping. Does NOT unload any active Worker."
  @spec unregister(<<_::128>>) :: :ok
  def unregister(<<_::128>> = key) do
    GenServer.call(__MODULE__, {:unregister, key})
  end

  @doc "Update the module atom a key points to. Resets target/beam_source meta."
  @spec update(<<_::128>>, module()) :: :ok | {:error, :not_found}
  def update(<<_::128>> = key, new_module) when is_atom(new_module) do
    GenServer.call(__MODULE__, {:update, key, new_module})
  end

  @doc "True if a key is currently registered."
  @spec registered?(<<_::128>>) :: boolean()
  def registered?(<<_::128>> = key), do: :ets.member(@table, key)

  @doc "Return all registered {key, module} pairs."
  @spec list_registered() :: [{<<_::128>>, module()}]
  def list_registered do
    :ets.tab2list(@table) |> Enum.map(fn {key, module_name, _meta} -> {key, module_name} end)
  end

  @doc "Number of registered keys."
  @spec count() :: non_neg_integer()
  def count, do: :ets.info(@table, :size)

  # ── Memoisation cache (pure function targets) ─────────────────────────────

  @doc false
  # Cached result for a pure call, or :miss. The memo table is :public so the
  # calling process reads/writes directly — no GenServer round-trip.
  def memo_get(key, args) do
    case :ets.lookup(@memo, {key, args}) do
      [{_, result}] -> {:hit, result}
      [] -> :miss
    end
  end

  @doc false
  def memo_put(key, args, result), do: :ets.insert(@memo, {{key, args}, result})

  @doc false
  # Drop all cached results for a key — called whenever the key's meaning
  # changes (unregister, update, re-register).
  def memo_clear(key), do: :ets.match_delete(@memo, {{key, :_}, :_})

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(_init_arg) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])

    :ets.new(@memo, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    Logger.debug("[Registry] initialised")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, key, module_name, meta}, _from, state) do
    memo_clear(key)
    :ets.insert(@table, {key, module_name, meta})
    Logger.debug("[Registry] registered #{inspect(module_name)} under #{Base.encode16(key)}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:register_many, entries}, _from, state) do
    Enum.each(entries, fn {key, _mod, _meta} -> memo_clear(key) end)
    :ets.insert(@table, entries)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister, key}, _from, state) do
    memo_clear(key)
    :ets.delete(@table, key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update, key, new_module}, _from, state) do
    case :ets.member(@table, key) do
      true ->
        memo_clear(key)
        :ets.insert(@table, {key, new_module, normalize_meta(new_module, %{})})
        {:reply, :ok, state}

      false ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp normalize_meta(module_name, meta) when is_map(meta) do
    Map.merge(
      %{target: {:module, module_name}, beam_source: nil, pure: false},
      Map.take(meta, [:target, :beam_source, :pure])
    )
  end

  defp valid_spec?({<<_::128>>, module_name}) when is_atom(module_name), do: true
  defp valid_spec?(_), do: false
end
