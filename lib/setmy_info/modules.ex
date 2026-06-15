defmodule SetmyInfo.Modules do
  @moduledoc """
  Path-based module loader layered on `SetmyInfo.ElixirModuleLoader`.

  Manages a single **root path** for the entire OS process. Each UUID maps to
  a sub-folder inside that root. The folder is expected to contain a single
  Elixir source file (`.ex`) and, after compilation, a corresponding `.beam`
  file. Both the UUID and the source file name are supplied in a `Request`
  struct.

      {root_path}/
        {uuid}/
          Masker.ex              ← source file (file_name in the Request)
          Elixir.SomeMasker.beam ← written by compile/1; read by load/1

  ## Two-phase workflow

  Compilation and loading are fully independent steps:

  1. **Compile** — translate the `.ex` source to a `.beam` file on disk.
     Nothing is loaded into the VM or registered. This step may happen in a
     separate process, at deploy time, or long before any request arrives.

  2. **Load** — read the `.beam` file from disk, load it into the VM, and
     register the module under the UUID in `SetmyInfo.ElixirModuleLoader`.
     No recompilation; no in-memory binary passing from the compile step.

  ## Typical workflow

      alias SetmyInfo.Modules
      alias SetmyInfo.Modules.Request
      alias SetmyInfo.ElixirModuleLoader, as: EML

      # Once at startup
      :ok = Modules.set_root_path("/var/app/modules")

      # Build phase (separate process / deploy time)
      request = %Request{uuid: uuid, file_name: "Masker.ex"}
      {:ok, [beam_path]} = Modules.compile(request)

      # Request phase — load from the .beam file on disk
      {:ok, _module} = Modules.load(request)

      # Discover and invoke functions by name (from config / DB)
      {:ok, fun} = EML.get_function(uuid, fn_name, 1)
      result = fun.([data])

      # Release when done
      :ok = EML.release(uuid)

  ## Path helpers

      {:ok, "/var/app/modules/550e8400-..."}           = Modules.uuid_path(uuid)
      {:ok, "/var/app/modules/550e8400-.../Masker.ex"} = Modules.module_path(request)
  """

  alias SetmyInfo.ElixirModuleLoader, as: EML
  alias SetmyInfo.ElixirModuleLoader.UUID

  @env_key :modules_root_path
  @app :elixir_module_loader

  defmodule Request do
    @moduledoc "Identifies a single Elixir source file to compile or load from its UUID folder."
    @enforce_keys [:uuid, :file_name]
    defstruct [:uuid, :file_name]
    @type t :: %__MODULE__{uuid: String.t(), file_name: String.t()}
  end

  # ── Root path ────────────────────────────────────────────────────────────────

  @doc """
  Set the root path for the whole process.

  Call once at application startup before any `compile/1` or `load/1` calls.
  The path is expanded to an absolute path and stored in the Application
  environment — it is visible to all processes in the VM.
  """
  @spec set_root_path(Path.t()) :: :ok
  def set_root_path(path) when is_binary(path) do
    Application.put_env(@app, @env_key, Path.expand(path))
  end

  @doc "Return the configured root path, or `{:error, :root_path_not_set}`."
  @spec root_path() :: {:ok, Path.t()} | {:error, :root_path_not_set}
  def root_path do
    case Application.get_env(@app, @env_key) do
      nil -> {:error, :root_path_not_set}
      path -> {:ok, path}
    end
  end

  # ── Path helpers ─────────────────────────────────────────────────────────────

  @doc """
  Return `root_path/uuid` — the folder for this UUID.

  `uuid` must be a well-formed UUID string. Any other value is rejected with
  `{:error, :invalid_uuid}` so a caller-supplied value can never contain path
  segments (`..`, `/`) that escape the configured root path.
  """
  @spec uuid_path(String.t()) :: {:ok, Path.t()} | {:error, term()}
  def uuid_path(uuid) when is_binary(uuid) do
    if UUID.uuid_string?(uuid) do
      with {:ok, root} <- root_path() do
        {:ok, Path.join(root, uuid)}
      end
    else
      {:error, :invalid_uuid}
    end
  end

  @doc """
  Return the full path to the `.ex` source file described by `request`.

  Both fields are validated: the UUID through `uuid_path/1`, and `file_name`
  must be a plain file name inside the UUID folder. A `file_name` containing a
  directory separator or a `.`/`..` segment is rejected with
  `{:error, :invalid_file_name}` so it cannot escape the folder.
  """
  @spec module_path(Request.t()) :: {:ok, Path.t()} | {:error, term()}
  def module_path(%Request{uuid: uuid, file_name: file_name}) do
    with {:ok, dir} <- uuid_path(uuid),
         :ok <- validate_file_name(file_name) do
      {:ok, Path.join(dir, file_name)}
    end
  end

  # ── Compilation ──────────────────────────────────────────────────────────────

  @doc """
  Compile the `.ex` source file described by `request` and write the
  resulting `.beam` file(s) to the same UUID folder on disk.

  This is a pure build step — nothing is loaded into the VM or registered
  in `SetmyInfo.ElixirModuleLoader`. Call `load/1` separately, at any later
  time and from any process, to load the compiled BEAM from disk.

  Returns `{:ok, [beam_path]}` listing the `.beam` files written to disk.
  """
  # sobelow_skip ["Traversal.FileModule"]
  # The write path is not attacker-controlled: `dir` comes from `uuid_path/1`,
  # which rejects any UUID containing path separators or `..`, and `module` is
  # a compiler-produced module atom (no separators). The path therefore cannot
  # escape the configured root. Covered by the path-traversal tests.
  @spec compile(Request.t()) :: {:ok, [Path.t()]} | {:error, term()}
  def compile(%Request{uuid: uuid} = request) do
    with {:ok, ex_path} <- module_path(request),
         {:ok, dir} <- uuid_path(uuid),
         {:ok, pairs} <- EML.compile_file(ex_path, load: false) do
      beam_paths =
        Enum.map(pairs, fn {module, binary} ->
          beam_path = Path.join(dir, "#{module}.beam")
          File.write!(beam_path, binary)
          beam_path
        end)

      # Code.compile_file (used internally) loads modules into the VM as a side
      # effect of compilation. Purge those here so a subsequent load/1 can read
      # cleanly from the .beam file on disk without hitting :not_purged.
      Enum.each(pairs, fn {module, _} ->
        :code.purge(module)
        :code.delete(module)
        :code.purge(module)
      end)

      {:ok, beam_paths}
    end
  end

  @doc """
  Load the pre-compiled `.beam` file from the UUID folder, register the
  module under `request.uuid` in `SetmyInfo.ElixirModuleLoader`, and return
  `{:ok, module}`.

  The `.beam` file must already exist in the UUID folder — call `compile/1`
  first, or place a pre-compiled `.beam` there by any other means. No
  recompilation occurs; this is a pure disk read followed by a VM load.

  Returns `{:error, :no_beam_file}` when no `.beam` file is found in the
  UUID folder.
  """
  @spec load(Request.t()) :: {:ok, module()} | {:error, term()}
  def load(%Request{uuid: uuid} = request) do
    with {:ok, dir} <- uuid_path(uuid),
         {:ok, beam_path} <- find_beam(dir, request) do
      EML.load_file(uuid, beam_path)
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  # A file name must be a plain name inside the UUID folder: no directory
  # separators and no `.`/`..` segments, so it cannot escape the folder when
  # joined onto the (already validated) UUID path.
  defp validate_file_name(name) when is_binary(name) do
    cond do
      name in ["", ".", ".."] -> {:error, :invalid_file_name}
      String.contains?(name, ["/", "\\", "\0"]) -> {:error, :invalid_file_name}
      true -> :ok
    end
  end

  defp validate_file_name(_), do: {:error, :invalid_file_name}

  defp find_beam(dir, _request) do
    case File.ls(dir) do
      {:ok, entries} ->
        case Enum.find(entries, &String.ends_with?(&1, ".beam")) do
          nil -> {:error, :no_beam_file}
          name -> {:ok, Path.join(dir, name)}
        end

      {:error, _} = err ->
        err
    end
  end
end
