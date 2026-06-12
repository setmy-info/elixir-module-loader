defmodule SetmyInfo.ElixirModuleLoader do
  @moduledoc """
  Public facade for dynamic Elixir module compilation, loading, and lifecycle management.

  Modules are registered and tracked under 128-bit keys. Every function that
  takes a key accepts it in either of two interchangeable forms:

  * a **UUID string** — `"550e8400-e29b-41d4-a716-446655440000"` (see `generate_uuid/0`)
  * a **16-byte binary** — `<<_::128>>` (see `generate_key/0`)

  A UUID is exactly 128 bits, so both forms address the same registry entry:
  registering under a UUID and looking up with its binary form (or vice versa)
  refer to the same module. Use `SetmyInfo.ElixirModuleLoader.UUID` to convert
  between the two explicitly.

  ## Invalid keys

  Every single-key function (`register/2`, `load/1`, `release/1`, `loaded?/1`,
  `lookup/1`, …) raises `ArgumentError` when given a binary that is neither a
  16-byte key nor a well-formed UUID string — an invalid key is treated as a
  caller bug, not a runtime error tuple. The only exception is `register_many/1`,
  which validates the whole batch and returns `{:error, :invalid_spec}` instead
  of raising.

  ## Typical workflow (UUID)

      # 1. Generate a UUID for the module
      uuid = SetmyInfo.ElixirModuleLoader.generate_uuid()

      # 2. Compile a .ex file (or load a .beam file) and register under the UUID
      {:ok, _module} =
        SetmyInfo.ElixirModuleLoader.register_file(uuid, "plugins/my_plugin.ex")

      # 3. Load (starts a supervised Worker process)
      {:ok, _pid} = SetmyInfo.ElixirModuleLoader.load(uuid)

      # 4. Execute a function on the loaded module
      {:ok, result} = SetmyInfo.ElixirModuleLoader.execute(uuid, :my_function, [arg1])

      # 5. Release (terminates the Worker, frees resources)
      :ok = SetmyInfo.ElixirModuleLoader.release(uuid)

  ## Typical workflow (128-bit key)

      {:ok, _} = SetmyInfo.ElixirModuleLoader.compile(source_code)
      key = SetmyInfo.ElixirModuleLoader.generate_key()
      :ok = SetmyInfo.ElixirModuleLoader.register(key, MyDynamicModule)
      {:ok, _pid} = SetmyInfo.ElixirModuleLoader.load(key)
      {:ok, result} = SetmyInfo.ElixirModuleLoader.execute(key, :my_function, [arg1])
      :ok = SetmyInfo.ElixirModuleLoader.release(key)
  """

  alias SetmyInfo.ElixirModuleLoader.{Compiler, Executor, Loader, Registry, UUID, Worker}

  @typedoc "A 16-byte binary module key."
  @type key :: <<_::128>>

  @typedoc "A canonical UUID string, e.g. `\"550e8400-e29b-41d4-a716-446655440000\"`."
  @type uuid :: String.t()

  @typedoc "Either accepted key form — a 16-byte binary or a UUID string."
  @type key_or_uuid :: key() | uuid()

  @default_timeout 5_000

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

  # ── Registry ─────────────────────────────────────────────────────────────────

  @doc "Register a module atom under a UUID string or 128-bit key."
  @spec register(key_or_uuid(), module()) :: :ok
  def register(key_or_uuid, module_name),
    do: Registry.register(normalize(key_or_uuid), module_name)

  @doc """
  Compile (`.ex`) or load (`.beam`) `path`, then register the resulting module
  under `key_or_uuid` in a single call.

  A file ending in `.beam` is loaded as a pre-compiled binary; any other
  extension is compiled as Elixir source. Returns `{:ok, module}` or
  `{:error, reason}`.

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

    with {:ok, module} <- compile_or_load(path) do
      :ok = Registry.register(key, module)
      {:ok, module}
    end
  end

  @doc "Look up which module atom is registered under a UUID string or key."
  @spec lookup(key_or_uuid()) :: {:ok, module()} | {:error, :not_found}
  def lookup(key_or_uuid), do: Registry.lookup(normalize(key_or_uuid))

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

  @doc "Remove a key→module mapping. Does NOT unload an active Worker."
  @spec unregister(key_or_uuid()) :: :ok
  def unregister(key_or_uuid), do: Registry.unregister(normalize(key_or_uuid))

  @doc "True if a UUID string or key is currently registered."
  @spec registered?(key_or_uuid()) :: boolean()
  def registered?(key_or_uuid), do: Registry.registered?(normalize(key_or_uuid))

  # ── Loader ───────────────────────────────────────────────────────────────────

  @doc "Load the module registered under `key_or_uuid` (starts a supervised Worker)."
  @spec load(key_or_uuid()) :: {:ok, pid()} | {:error, term()}
  def load(key_or_uuid), do: Loader.load(normalize(key_or_uuid))

  @doc "Reload the module: terminate any existing Worker and start a fresh one."
  @spec reload(key_or_uuid()) :: {:ok, pid()} | {:error, term()}
  def reload(key_or_uuid), do: Loader.reload(normalize(key_or_uuid))

  @doc "Release the module registered under `key_or_uuid` (terminates the Worker)."
  @spec release(key_or_uuid()) :: :ok | {:error, :not_loaded}
  def release(key_or_uuid), do: Loader.release(normalize(key_or_uuid))

  @doc "True if a Worker is currently running for `key_or_uuid`."
  @spec loaded?(key_or_uuid()) :: boolean()
  def loaded?(key_or_uuid), do: Loader.loaded?(normalize(key_or_uuid))

  @doc "Return the Worker PID for `key_or_uuid` if currently loaded."
  @spec pid_for(key_or_uuid()) :: {:ok, pid()} | {:error, :not_loaded}
  def pid_for(key_or_uuid), do: Loader.pid_for(normalize(key_or_uuid))

  # ── Execution ────────────────────────────────────────────────────────────────

  @doc """
  Execute `function(args)` on the Worker loaded under `key_or_uuid`.

  An optional `timeout` (ms, default #{@default_timeout}) bounds the call; a
  plugin exceeding it returns `{:error, :timeout}` without crashing the caller.
  """
  @spec execute(key_or_uuid(), atom(), [term()], timeout()) ::
          {:ok, term()} | {:error, term()}
  def execute(key_or_uuid, function, args, timeout \\ @default_timeout),
    do: Worker.execute(normalize(key_or_uuid), function, args, timeout)

  @doc "Load module (if not already loaded), execute, then keep it loaded."
  @spec run(key_or_uuid(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  def run(key_or_uuid, function, args),
    do: Executor.run(normalize(key_or_uuid), function, args)

  @doc "Load, execute, then immediately release the module."
  @spec run_and_release(key_or_uuid(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  def run_and_release(key_or_uuid, function, args),
    do: Executor.run_and_release(normalize(key_or_uuid), function, args)

  # ── Private ───────────────────────────────────────────────────────────────────

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

  defp compile_or_load(path) do
    if String.ends_with?(path, ".beam") do
      load_beam_file(path)
    else
      with {:ok, [{module, _binary} | _]} <- compile_file(path), do: {:ok, module}
    end
  end
end
