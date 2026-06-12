defmodule SetmyInfo.ElixirModuleLoader.Supervisor do
  @moduledoc """
  Root supervisor for SetmyInfo.ElixirModuleLoader.

  Owns:
  - `SetmyInfo.ElixirModuleLoader.Registry` (GenServer) — 128-bit key → module atom, ETS-backed
  - `SetmyInfo.ElixirModuleLoader.DynamicSupervisor` — starts/stops Worker processes on demand
  - `SetmyInfo.ElixirModuleLoader.Loader` (GenServer) — tracks loaded modules in ETS
  - `SetmyInfo.ElixirModuleLoader.CompileLock` (GenServer) — serialises runtime compilation

  Restart strategy is `:rest_for_one`:
  - Registry crash → DynamicSupervisor + Loader + CompileLock restart (Workers terminated, ETS rebuilt)
  - DynamicSupervisor crash → Loader + CompileLock restart; Loader reconciles with WorkerRegistry
  - Loader crash → Loader + CompileLock restart; Workers survive, Loader reconciles
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
      {DynamicSupervisor,
       name: SetmyInfo.ElixirModuleLoader.DynamicSupervisor, strategy: :one_for_one},
      SetmyInfo.ElixirModuleLoader.Loader,
      SetmyInfo.ElixirModuleLoader.CompileLock
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
