defmodule SetmyInfo.ElixirModuleLoader.Supervisor do
  @moduledoc """
  Root supervisor for SetmyInfo.ElixirModuleLoader.

  Owns:
  - `SetmyInfo.ElixirModuleLoader.Registry` (GenServer) — 128-bit key → module atom, ETS-backed
  - `SetmyInfo.ElixirModuleLoader.DynamicSupervisor` — starts/stops Worker processes on demand
  - `SetmyInfo.ElixirModuleLoader.Loader` (GenServer) — tracks loaded modules in ETS

  Restart strategy is `:rest_for_one`:
  - Registry crash → DynamicSupervisor + Loader restart (Workers terminated, ETS rebuilt)
  - DynamicSupervisor crash → Loader restarts; reconciles with WorkerRegistry
  - Loader crash → only Loader restarts; Workers survive, Loader reconciles
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
      SetmyInfo.ElixirModuleLoader.Loader
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
