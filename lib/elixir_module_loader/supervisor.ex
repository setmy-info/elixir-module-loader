defmodule SetmyInfo.ElixirModuleLoader.Supervisor do
  @moduledoc """
  Root supervisor for SetmyInfo.ElixirModuleLoader.

  Owns:
  - `SetmyInfo.ElixirModuleLoader.Registry` (GenServer) — 128-bit key → module/meta, ETS-backed
  - `SetmyInfo.ElixirModuleLoader.Loader` (GenServer) — loaded working set + code purge/restore
  - `SetmyInfo.ElixirModuleLoader.CompileLock` (GenServer) — serialises runtime compilation

  The library starts no per-module processes: loaded code is called directly
  by the library user, and any processes the loaded code starts are its own.

  Restart strategy is `:rest_for_one`:
  - Registry crash → Loader + CompileLock restart (ETS tables rebuilt)
  - Loader crash → Loader + CompileLock restart (working set re-tracked by user)
  - CompileLock crash → only CompileLock restarts (it is stateless)
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      SetmyInfo.ElixirModuleLoader.Registry,
      SetmyInfo.ElixirModuleLoader.Loader,
      SetmyInfo.ElixirModuleLoader.CompileLock
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
