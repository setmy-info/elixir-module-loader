defmodule SetmyInfo.ElixirModuleLoader.Compiler do
  @moduledoc """
  Utilities for compiling Elixir code and loading BEAM binaries into the VM.

  ## Entry points

  * `from_source/1` — compile an Elixir source string at runtime via
    `Code.compile_string/1` and load into the VM.

  * `from_file/1` — compile an Elixir .ex source file via
    `Code.compile_file/1` and load into the VM.

  * `from_beam_file/1` — load a pre-compiled .beam file from disk.

  * `from_beam_binary/2` — load a BEAM binary already in memory (e.g.
    received over the network).

  ## Concurrency

  Source/file compilation toggles the **VM-global** `:ignore_module_conflict`
  compiler option. That flag is not process-local, so two callers compiling at
  the same time can clobber each other's setting. To make compilation
  process-safe, `from_source/1` and `from_file/1` run their critical section
  serialised through the `SetmyInfo.ElixirModuleLoader.CompileLock` GenServer —
  only one compilation toggles the flag at a time. The previous flag value is
  saved and restored, so a host application's own compiler settings are never
  clobbered.

  Note this only serialises compilations going through this library. Code in
  the host application that calls `Code.compile_string/1` directly (or an IEx
  recompile) still races on the same global flag — that is outside this
  library's control.

  The BEAM-binary loaders (`from_beam_file/1`, `from_beam_binary/2`) do **not**
  touch the global flag; they go straight to the code server, which the VM
  already serialises, so they are safe to call concurrently.

  ## Hot reload

  The BEAM supports two live versions of any module simultaneously.
  Calling any `from_*` function while the module is already loaded performs
  a hot swap: existing processes calling the module pick up the new code on
  their next call without a restart.
  """

  alias SetmyInfo.ElixirModuleLoader.CompileLock

  require Logger

  # Compilation can be slow; allow well beyond the 5s GenServer.call default.
  @compile_timeout 60_000

  @doc """
  Compile an Elixir source string and load all defined modules into the VM.

  Returns `{:ok, [{module, binary}]}` on success. Modules are immediately
  callable after this returns. Serialised through the CompileLock GenServer so
  concurrent callers cannot corrupt the global compiler flag.
  """
  @spec from_source(String.t()) :: {:ok, [{module(), binary()}]} | {:error, term()}
  def from_source(elixir_source) when is_binary(elixir_source) do
    GenServer.call(CompileLock, {:compile, {:source, elixir_source}}, @compile_timeout)
  end

  @doc """
  Compile an Elixir .ex source file and load all defined modules into the VM.

  Returns `{:ok, [{module, binary}]}` on success. Serialised through the
  CompileLock GenServer (see the module's Concurrency section).
  """
  @spec from_file(Path.t()) :: {:ok, [{module(), binary()}]} | {:error, term()}
  def from_file(path) when is_binary(path) do
    GenServer.call(CompileLock, {:compile, {:file, path}}, @compile_timeout)
  end

  @doc false
  # Raw compilation critical section. Invoked ONLY from inside the CompileLock
  # GenServer (via the `{:compile, _}` call) so that the VM-global
  # `:ignore_module_conflict` flag is never toggled by two processes at once.
  # Do not call directly — use `from_source/1` / `from_file/1`.
  @spec run_compile({:source, String.t()} | {:file, Path.t()}) ::
          {:ok, [{module(), binary()}]} | {:error, term()}
  def run_compile({:source, elixir_source}) do
    with_conflict_ignored(fn ->
      modules = Code.compile_string(elixir_source)

      Logger.info(
        "[Compiler] loaded #{length(modules)} module(s) from source: #{module_names(modules)}"
      )

      modules
    end)
  end

  def run_compile({:file, path}) do
    with_conflict_ignored(
      fn ->
        modules = Code.compile_file(path)

        Logger.info(
          "[Compiler] loaded #{length(modules)} module(s) from #{path}: #{module_names(modules)}"
        )

        modules
      end,
      "from file #{path}"
    )
  end

  @doc """
  Load a pre-compiled .beam file from the filesystem into the VM.

  Pass the full path including the `.beam` extension, or without — both work.
  Returns `{:ok, module_name}` on success.
  """
  @spec from_beam_file(Path.t()) :: {:ok, module()} | {:error, term()}
  def from_beam_file(path) when is_binary(path) do
    charpath = path |> Path.rootname() |> String.to_charlist()

    case :code.load_abs(charpath) do
      {:module, module_name} ->
        Logger.info("[Compiler] loaded #{module_name} from #{path}")
        {:ok, module_name}

      {:error, reason} ->
        Logger.error("[Compiler] failed to load from #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Load a pre-compiled BEAM binary for `module_name` into the VM.

  Use when you have the BEAM bytes in memory (e.g. distributed over the network).
  """
  @spec from_beam_binary(module(), binary()) :: :ok | {:error, term()}
  def from_beam_binary(module_name, beam_binary)
      when is_atom(module_name) and is_binary(beam_binary) do
    filename = ~c"#{module_name}.beam"

    case :code.load_binary(module_name, filename, beam_binary) do
      {:module, ^module_name} ->
        Logger.info("[Compiler] loaded #{module_name} from BEAM binary")
        :ok

      {:error, reason} ->
        Logger.error("[Compiler] failed to load #{module_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Soft-purge the old version of a module after a hot swap."
  @spec purge(module()) :: boolean()
  def purge(module_name) do
    result = :code.soft_purge(module_name)
    Logger.debug("[Compiler] soft_purge #{module_name}: #{result}")
    result
  end

  @doc "Delete a module from the code server entirely."
  @spec delete(module()) :: boolean()
  def delete(module_name), do: :code.delete(module_name)

  @doc "Return the MD5 of the currently loaded version of a module, or `nil`."
  @spec module_md5(module()) :: String.t() | nil
  def module_md5(module_name) do
    module_name.module_info(:md5) |> Base.encode16()
  rescue
    _ -> nil
  end

  # ── Private ───────────────────────────────────────────────────────────────

  # Runs `fun` with the global `:ignore_module_conflict` flag enabled and
  # guarantees the host application's previous value is restored afterwards.
  # Caller must already hold the compile serialisation lock.
  defp with_conflict_ignored(fun, context \\ "from source") do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      {:ok, fun.()}
    rescue
      e ->
        Logger.error("[Compiler] compile error #{context}: #{Exception.message(e)}")
        {:error, e}
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end

  defp module_names(modules) do
    modules |> Enum.map(fn {name, _} -> name end) |> Enum.join(", ")
  end
end
