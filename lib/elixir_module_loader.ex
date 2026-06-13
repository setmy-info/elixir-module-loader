defmodule SetmyInfo.ElixirModuleLoader do
  @moduledoc """
  Public facade for dynamic Elixir module compilation, loading, and memory
  lifecycle management.

  The library manages a catalog of dynamically loadable code addressed by
  128-bit keys: compile it, register it, load it, discover its functions,
  and release it (freeing code memory). **Calling the code is the library
  user's business** — `load/1` returns the module itself, and there is no
  dispatch layer, no required interface, no wrapping of results:

      {:ok, module} = SetmyInfo.ElixirModuleLoader.load(key)
      module.anything(args)            # direct call
      apply(module, fun_atom, args)    # dynamic call with runtime names

  Every key-taking function accepts either of two interchangeable forms:

  * a **UUID string** — `"550e8400-e29b-41d4-a716-446655440000"` (see `generate_uuid/0`)
  * a **16-byte binary** — `<<_::128>>` (see `generate_key/0`)

  ## What a key can address

  * **A module** — `register/2`, `register_file/2`, `register_source/2`.
    Any module; no interface required.
  * **A single function** — `register_function/3` with a `{module, fun, arity}`;
    capture it as a first-class closure with `fun/1`.
  * **A composition** — `register_composite/2` with a data AST referencing
    other keys (see `SetmyInfo.ElixirModuleLoader.Composite`); the composed
    function is a catalog entry like any other.

  ## Discovering functions at runtime

  Loadable code is often not known to the caller (AI-generated, catalog
  modules). `functions/1` lists what a key exports; `fun/3` captures any of
  them as a closure without hard-coding module names:

      {:ok, exports} = SetmyInfo.ElixirModuleLoader.functions(key)
      #=> {:ok, [add: 2, multiply: 2]}
      add = SetmyInfo.ElixirModuleLoader.fun(key, :add, 2)
      add.(2, 3)  #=> 5

  ## Memory lifecycle

  `release/1` removes the key from the loaded working set **and frees the
  module's code**: when the code is library-managed (registered via
  `register_file/2` or `register_source/2`) and no other loaded key uses the
  same module, the code is deleted and soft-purged from the VM. The registry
  remembers how to restore it (`.beam` file, `.ex` source, or in-memory BEAM
  binary), so a later `load/1` brings it back transparently. Modules
  registered with plain `register/2` are never purged — the library does not
  purge what it cannot restore.

  ## Invalid keys

  Every single-key function raises `ArgumentError` when given a binary that
  is neither a 16-byte key nor a well-formed UUID string — an invalid key is
  treated as a caller bug, not a runtime error tuple. The only exception is
  `register_many/1`, which validates the whole batch and returns
  `{:error, :invalid_spec}` instead of raising.

  ## Typical workflow

      # 1. Generate a UUID for the module
      uuid = SetmyInfo.ElixirModuleLoader.generate_uuid()

      # 2. Compile a .ex file (or load a .beam) and register — one call,
      #    the module comes back immediately
      {:ok, module} = SetmyInfo.ElixirModuleLoader.register_file(uuid, "plugins/my_plugin.ex")

      # 3. Use it directly — the user knows (or discovers) the functions
      result = module.transform(data)

      # 4. Later, by key: load (restores code if purged) and call dynamically
      {:ok, module} = SetmyInfo.ElixirModuleLoader.load(uuid)
      result = apply(module, :transform, [data])

      # 5. Release — frees the working-set slot AND the code memory
      :ok = SetmyInfo.ElixirModuleLoader.release(uuid)
  """

  alias SetmyInfo.ElixirModuleLoader.{
    Compiler,
    Composite,
    Fn,
    Loader,
    Registry,
    UUID
  }

  @typedoc "A 16-byte binary module key."
  @type key :: <<_::128>>

  @typedoc "A canonical UUID string, e.g. `\"550e8400-e29b-41d4-a716-446655440000\"`."
  @type uuid :: String.t()

  @typedoc "Either accepted key form — a 16-byte binary or a UUID string."
  @type key_or_uuid :: key() | uuid()

  @doc "Generate a cryptographically-random 128-bit binary key."
  @spec generate_key() :: key()
  def generate_key, do: :crypto.strong_rand_bytes(16)

  @doc "Generate a random version-4 UUID string."
  @spec generate_uuid() :: uuid()
  def generate_uuid, do: UUID.generate()

  # ── Compilation ─────────────────────────────────────────────────────────────

  @doc "Compile an Elixir source string and load all defined modules into the VM."
  @spec compile(String.t()) :: {:ok, [{module(), binary()}]} | {:error, term()}
  defdelegate compile(source), to: Compiler, as: :from_source

  @doc "Compile an Elixir .ex file and load all defined modules into the VM."
  @spec compile_file(Path.t()) :: {:ok, [{module(), binary()}]} | {:error, term()}
  defdelegate compile_file(path), to: Compiler, as: :from_file

  @doc "Load a pre-compiled .beam file into the VM."
  @spec load_beam_file(Path.t()) :: {:ok, module()} | {:error, term()}
  defdelegate load_beam_file(path), to: Compiler, as: :from_beam_file

  @doc "Load a raw BEAM binary for a named module into the VM."
  @spec load_beam_binary(module(), binary()) :: :ok | {:error, term()}
  defdelegate load_beam_binary(module_name, binary), to: Compiler, as: :from_beam_binary

  # ── Registration ─────────────────────────────────────────────────────────────

  @doc """
  Register a module atom under a UUID string or 128-bit key.

  The module's code is treated as externally managed: `release/1` will not
  purge it. Use `register_file/2` or `register_source/2` when the library
  should also manage (and free) the code memory.
  """
  @spec register(key_or_uuid(), module()) :: :ok
  def register(key_or_uuid, module_name),
    do: Registry.register(normalize(key_or_uuid), module_name)

  @doc """
  Compile (`.ex`) or load (`.beam`) `path`, then register the resulting module
  under `key_or_uuid` in a single call.

  A file ending in `.beam` is loaded as a pre-compiled binary; any other
  extension is compiled as Elixir source. Returns `{:ok, module}` — the
  module is immediately usable, no further registry call needed — or
  `{:error, reason}`. The same module remains requestable later by its key.

  The path is remembered as the module's code source: after `release/1`
  purges the code, the next `load/1` restores it from the `.beam` file or by
  recompiling the `.ex` file.

  > #### Multi-module source files {: .info}
  >
  > For a `.ex` file that defines several modules, the first entry returned by
  > the compiler is registered. The Elixir compiler does not guarantee that
  > order matches source order, so this convenience is intended for the common
  > one-module-per-file case. For multi-module files, compile with
  > `compile_file/1` and `register/2` the specific module yourself.
  """
  @spec register_file(key_or_uuid(), Path.t()) :: {:ok, module()} | {:error, term()}
  def register_file(key_or_uuid, path) when is_binary(path) do
    key = normalize(key_or_uuid)

    if String.ends_with?(path, ".beam") do
      with {:ok, module} <- load_beam_file(path) do
        :ok = Registry.register(key, module, %{beam_source: {:file, path}})
        {:ok, module}
      end
    else
      with {:ok, [{module, _beam} | _]} <- compile_file(path) do
        :ok = Registry.register(key, module, %{beam_source: {:ex_file, path}})
        {:ok, module}
      end
    end
  end

  @doc """
  Compile an Elixir source string and register the (first) resulting module
  under `key_or_uuid` in a single call — the AI-generated-code path.

  Returns `{:ok, module}`; the module is immediately usable. The compiled
  BEAM binary is kept in the registry entry so the code can be purged on
  `release/1` and restored on the next `load/1` without any source file.
  """
  @spec register_source(key_or_uuid(), String.t()) :: {:ok, module()} | {:error, term()}
  def register_source(key_or_uuid, source) when is_binary(source) do
    key = normalize(key_or_uuid)

    with {:ok, [{module, beam} | _]} <- compile(source) do
      :ok = Registry.register(key, module, %{beam_source: {:binary, beam}})
      {:ok, module}
    end
  end

  @doc """
  Register a single function `{module, function, arity}` under its own key.

  The function becomes an addressable catalog entry; capture it as a
  first-class closure with `fun/1`.

  Options:

  * `:pure` — declare the function side-effect free (default `false`). Calls
    through `fun/1` (and composite refs) are then memoised per `{key, args}`.
  """
  @spec register_function(key_or_uuid(), {module(), atom(), non_neg_integer()}, keyword()) :: :ok
  def register_function(key_or_uuid, {m, f, a}, opts \\ [])
      when is_atom(m) and is_atom(f) and is_integer(a) and a >= 0 do
    Registry.register(normalize(key_or_uuid), m, %{
      target: {:function, {m, f, a}},
      pure: Keyword.get(opts, :pure, false)
    })
  end

  @doc """
  Register a composition of loaded functions, described as data, under its
  own key — composing two functions yields a new catalog entry.

  See `SetmyInfo.ElixirModuleLoader.Composite` for the AST node types
  (`{:ref, key}`, `{:ref, key, function}`, `{:partial, key, function, args}`,
  `{:pipe, [stages]}`). A pipe stage returning `{:error, _}` short-circuits.

  Returns `{:error, :invalid_composite}` for a malformed AST.
  """
  @spec register_composite(key_or_uuid(), term()) :: :ok | {:error, :invalid_composite}
  def register_composite(key_or_uuid, ast) do
    if Composite.valid?(ast) do
      Registry.register(normalize(key_or_uuid), Composite, %{target: {:composite, ast}})
    else
      {:error, :invalid_composite}
    end
  end

  @doc """
  Register many `{key_or_uuid, module}` pairs at once — more efficient than
  repeated `register/2`. Each key may be a UUID string or a 128-bit binary.

  Unlike the single-key functions, a malformed spec or key does **not** raise:
  the whole batch is rejected with `{:error, :invalid_spec}` and nothing is
  inserted.
  """
  @spec register_many([{key_or_uuid(), module()}]) :: :ok | {:error, :invalid_spec}
  def register_many(specs) when is_list(specs) do
    case normalize_specs(specs, []) do
      {:ok, normalized} -> Registry.register_many(normalized)
      :error -> {:error, :invalid_spec}
    end
  end

  @doc "Look up which module atom is registered under a UUID string or key."
  @spec lookup(key_or_uuid()) :: {:ok, module()} | {:error, :not_found}
  def lookup(key_or_uuid), do: Registry.lookup(normalize(key_or_uuid))

  @doc "Remove a key→module mapping. Does NOT release a loaded key."
  @spec unregister(key_or_uuid()) :: :ok
  def unregister(key_or_uuid), do: Registry.unregister(normalize(key_or_uuid))

  @doc "True if a UUID string or key is currently registered."
  @spec registered?(key_or_uuid()) :: boolean()
  def registered?(key_or_uuid), do: Registry.registered?(normalize(key_or_uuid))

  @doc "All registered `{key, module}` pairs (keys as 16-byte binaries)."
  @spec list_registered() :: [{key(), module()}]
  defdelegate list_registered, to: Registry

  @doc "Number of registered keys."
  @spec count() :: non_neg_integer()
  defdelegate count, to: Registry

  # ── Loaded working set ───────────────────────────────────────────────────────

  @doc """
  Load the entry registered under `key_or_uuid` and return **the module** —
  call its functions directly, no further registry or dispatch involved.

  If the code was purged by an earlier `release/1`, it is restored first from
  the registered source (`.beam` file, `.ex` recompile, or in-memory binary).
  Idempotent: loading a loaded key returns the same module.
  """
  @spec load(key_or_uuid()) :: {:ok, module()} | {:error, term()}
  def load(key_or_uuid), do: Loader.load(normalize(key_or_uuid))

  @doc """
  Re-restore the module's code from its registered source (recompile the
  `.ex`, reload the `.beam`/binary), hot-swapping the loaded version.
  """
  @spec reload(key_or_uuid()) :: {:ok, module()} | {:error, term()}
  def reload(key_or_uuid), do: Loader.reload(normalize(key_or_uuid))

  @doc """
  Release the entry loaded under `key_or_uuid`.

  Removes the key from the loaded working set and, when the code is
  library-managed and no other loaded key uses the same module, deletes and
  soft-purges the module's code from the VM. The key stays registered and can
  be loaded again later — the code is restored automatically.
  """
  @spec release(key_or_uuid()) :: :ok | {:error, :not_loaded}
  def release(key_or_uuid), do: Loader.release(normalize(key_or_uuid))

  @doc "True if `key_or_uuid` is currently in the loaded working set."
  @spec loaded?(key_or_uuid()) :: boolean()
  def loaded?(key_or_uuid), do: Loader.loaded?(normalize(key_or_uuid))

  @doc "All currently loaded keys (16-byte binaries)."
  @spec list_loaded() :: [key()]
  defdelegate list_loaded, to: Loader

  @doc """
  When `key_or_uuid` was loaded, for external systems deciding what is no
  longer in use. (Call-level usage tracking is the external system's concern —
  the library does not intercept calls.)
  """
  @spec loaded_at(key_or_uuid()) :: {:ok, DateTime.t()} | {:error, :not_loaded}
  def loaded_at(key_or_uuid), do: Loader.loaded_at(normalize(key_or_uuid))

  # ── Functions as values ──────────────────────────────────────────────────────

  @doc """
  The functions a key exports, as `[{name, arity}]` — for callers that do not
  know the loaded code in advance (AI-generated or catalog modules). Loads
  the key (restoring code if needed).

  Module targets list the module's public functions; a function target lists
  its one `{name, arity}`; a composite lists `[call: 1]`.
  """
  @spec functions(key_or_uuid()) :: {:ok, [{atom(), non_neg_integer()}]} | {:error, term()}
  def functions(key_or_uuid) do
    key = normalize(key_or_uuid)

    case Registry.lookup_entry(key) do
      {:ok, _m, %{target: {:function, {_m2, f, a}}}} ->
        {:ok, [{f, a}]}

      {:ok, _m, %{target: {:composite, _}}} ->
        {:ok, [call: 1]}

      {:ok, _m, _meta} ->
        with {:ok, module} <- Loader.load(key), do: {:ok, exported_functions(module)}

      {:error, :not_found} = error ->
        error
    end
  end

  @doc """
  Capture the function or composite registered under `key_or_uuid` as a
  first-class Elixir function value of its registered arity.

  The closure is late-bound (it resolves the key on every call), returns the
  raw result of the underlying code, and is usable anywhere a function is —
  `Enum`, `Stream`, `Task`, or as an argument to another loaded function.
  Pure function targets are memoised.

  Raises `ArgumentError` for unregistered keys; for whole-module keys use
  `fun/3` with an explicit function name and arity.
  """
  @spec fun(key_or_uuid()) :: function()
  def fun(key_or_uuid) do
    key = normalize(key_or_uuid)

    case Registry.lookup_entry(key) do
      {:ok, _m, %{target: {:function, {_, _, arity}}}} ->
        Fn.make_closure(arity, &Fn.invoke(key, &1))

      {:ok, _m, %{target: {:composite, _}}} ->
        Fn.make_closure(1, &Fn.invoke(key, &1))

      {:ok, _m, _meta} ->
        raise ArgumentError,
              "key addresses a whole module — use fun/3 with a function name and arity"

      {:error, :not_found} ->
        raise ArgumentError, "no entry registered under #{inspect(key_or_uuid)}"
    end
  end

  @doc """
  Capture `function` (of `arity`, default 1) of the module registered under
  `key_or_uuid` as a first-class closure. The module is loaded on demand at
  call time (late-bound), so the capture survives release/reload cycles.
  """
  @spec fun(key_or_uuid(), atom(), non_neg_integer()) :: function()
  def fun(key_or_uuid, function, arity \\ 1) when is_atom(function) do
    key = normalize(key_or_uuid)
    Fn.make_closure(arity, fn args -> Fn.apply_module(key, function, args) end)
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp exported_functions(module) do
    if function_exported?(module, :__info__, 1) do
      module.__info__(:functions)
    else
      for {f, a} <- module.module_info(:exports), f != :module_info, do: {f, a}
    end
  end

  # Accept either key form. A 16-byte binary passes through unchanged; a UUID
  # string is converted to its binary key. Anything else raises ArgumentError.
  defp normalize(<<_::128>> = key), do: key
  defp normalize(uuid) when is_binary(uuid), do: UUID.to_key!(uuid)

  # Like normalize/1 but never raises — returns {:ok, key} | :error so batch
  # operations can reject malformed input instead of crashing.
  defp normalize_key(<<_::128>> = key), do: {:ok, key}
  defp normalize_key(uuid) when is_binary(uuid), do: UUID.to_key(uuid)
  defp normalize_key(_), do: :error

  # Validate and normalize a list of {key_or_uuid, module} specs, accumulating
  # in order. Any malformed entry aborts the whole batch with :error.
  defp normalize_specs([], acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_specs([{key_or_uuid, module} | rest], acc) when is_atom(module) do
    case normalize_key(key_or_uuid) do
      {:ok, key} -> normalize_specs(rest, [{key, module} | acc])
      :error -> :error
    end
  end

  defp normalize_specs(_, _), do: :error
end
