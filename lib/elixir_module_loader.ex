defmodule SetmyInfo.ElixirModuleLoader do
  @moduledoc """
  Public facade for dynamic Elixir module compilation, loading, and lifecycle management.

  Modules are registered and tracked under 128-bit binary keys (`<<_::128>>`).
  Use `generate_key/0` to create a cryptographically-random key.

  ## Typical workflow

      # 1. Compile an Elixir source string or file
      {:ok, _} = SetmyInfo.ElixirModuleLoader.compile(source_code)

      # 2. Generate a 128-bit key and register the module
      key = SetmyInfo.ElixirModuleLoader.generate_key()
      :ok  = SetmyInfo.ElixirModuleLoader.register(key, MyDynamicModule)

      # 3. Load (starts a supervised Worker process)
      {:ok, _pid} = SetmyInfo.ElixirModuleLoader.load(key)

      # 4. Execute a function on the loaded module
      {:ok, result} = SetmyInfo.ElixirModuleLoader.execute(key, :my_function, [arg1])

      # 5. Release (terminates the Worker, frees resources)
      :ok = SetmyInfo.ElixirModuleLoader.release(key)

  ## Key type

  All public functions that accept a key expect a 16-byte binary (`<<_::128>>`).
  """

  alias SetmyInfo.ElixirModuleLoader.{Compiler, Executor, Loader, Registry, Worker}

  @type key :: <<_::128>>

  @doc "Generate a cryptographically-random 128-bit key."
  @spec generate_key() :: key()
  def generate_key, do: :crypto.strong_rand_bytes(16)

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

  @doc "Register a module atom under a 128-bit key."
  @spec register(key(), module()) :: :ok
  defdelegate register(key, module_name), to: Registry

  @doc "Look up which module atom is registered under a key."
  @spec lookup(key()) :: {:ok, module()} | {:error, :not_found}
  defdelegate lookup(key), to: Registry

  @doc "Register many `{key, module}` pairs at once — more efficient than repeated `register/2`."
  @spec register_many([{key(), module()}]) :: :ok
  defdelegate register_many(specs), to: Registry

  @doc "Remove a key→module mapping. Does NOT unload an active Worker."
  @spec unregister(key()) :: :ok
  defdelegate unregister(key), to: Registry

  @doc "True if a key is currently registered."
  @spec registered?(key()) :: boolean()
  defdelegate registered?(key), to: Registry

  # ── Loader ───────────────────────────────────────────────────────────────────

  @doc "Load the module registered under `key` (starts a supervised Worker)."
  @spec load(key()) :: {:ok, pid()} | {:error, term()}
  defdelegate load(key), to: Loader

  @doc "Reload the module: terminate any existing Worker and start a fresh one."
  @spec reload(key()) :: {:ok, pid()} | {:error, term()}
  defdelegate reload(key), to: Loader

  @doc "Release the module registered under `key` (terminates the Worker)."
  @spec release(key()) :: :ok | {:error, :not_loaded}
  defdelegate release(key), to: Loader

  @doc "True if a Worker is currently running for `key`."
  @spec loaded?(key()) :: boolean()
  defdelegate loaded?(key), to: Loader

  @doc "Return the Worker PID for `key` if currently loaded."
  @spec pid_for(key()) :: {:ok, pid()} | {:error, :not_loaded}
  defdelegate pid_for(key), to: Loader

  # ── Execution ────────────────────────────────────────────────────────────────

  @doc "Execute `function(args)` on the Worker loaded under `key`."
  @spec execute(key(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  defdelegate execute(key, function, args), to: Worker

  @doc "Load module (if not already loaded), execute, then keep it loaded."
  @spec run(key(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  defdelegate run(key, function, args), to: Executor

  @doc "Load, execute, then immediately release the module."
  @spec run_and_release(key(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  defdelegate run_and_release(key, function, args), to: Executor
end
