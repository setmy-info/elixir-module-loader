defmodule SetmyInfo.ElixirModuleLoader.Application do
  @moduledoc """
  OTP Application entry point for SetmyInfo.ElixirModuleLoader.

  Starts a Registry for named worker lookup, then the main Supervisor
  which owns the DynamicSupervisor (for Worker processes), the module
  Registry (128-bit key → module atom), and the Loader (tracks loaded
  modules via ETS).
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: SetmyInfo.ElixirModuleLoader.WorkerRegistry},
      SetmyInfo.ElixirModuleLoader.Supervisor
    ]

    opts = [strategy: :one_for_one, name: SetmyInfo.ElixirModuleLoader.ApplicationSupervisor]
    Supervisor.start_link(children, opts)
  end
end
