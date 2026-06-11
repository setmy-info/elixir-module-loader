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

  ## Hot reload

  The BEAM supports two live versions of any module simultaneously.
  Calling any `from_*` function while the module is already loaded performs
  a hot swap: existing Worker processes pick up the new code on their next
  call without a restart.
  """

  require Logger

  @doc """
  Compile an Elixir source string and load all defined modules into the VM.

  Returns `{:ok, [{module, binary}]}` on success. Modules are immediately
  callable after this returns.
  """
  @spec from_source(String.t()) :: {:ok, [{module(), binary()}]} | {:error, term()}
  def from_source(elixir_source) when is_binary(elixir_source) do
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      modules = Code.compile_string(elixir_source)

      Logger.info(
        "[Compiler] loaded #{length(modules)} module(s) from source: #{module_names(modules)}"
      )

      {:ok, modules}
    rescue
      e ->
        Logger.warning("[Compiler] compile error: #{Exception.message(e)}")
        {:error, e}
    after
      Code.put_compiler_option(:ignore_module_conflict, false)
    end
  end

  @doc """
  Compile an Elixir .ex source file and load all defined modules into the VM.

  Returns `{:ok, [{module, binary}]}` on success.
  """
  @spec from_file(Path.t()) :: {:ok, [{module(), binary()}]} | {:error, term()}
  def from_file(path) when is_binary(path) do
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      modules = Code.compile_file(path)

      Logger.info(
        "[Compiler] loaded #{length(modules)} module(s) from #{path}: #{module_names(modules)}"
      )

      {:ok, modules}
    rescue
      e ->
        Logger.warning("[Compiler] compile error from file #{path}: #{Exception.message(e)}")
        {:error, e}
    after
      Code.put_compiler_option(:ignore_module_conflict, false)
    end
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
        Logger.warning("[Compiler] failed to load from #{path}: #{inspect(reason)}")
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
        Logger.warning("[Compiler] failed to load #{module_name}: #{inspect(reason)}")
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

  defp module_names(modules) do
    modules |> Enum.map(fn {name, _} -> name end) |> Enum.join(", ")
  end
end
