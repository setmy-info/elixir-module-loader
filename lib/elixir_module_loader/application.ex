defmodule SetmyInfo.ElixirModuleLoader.Application do
  @moduledoc """
  OTP Application entry point for SetmyInfo.ElixirModuleLoader.

  Starts the main Supervisor which owns the module Registry (128-bit key →
  module/meta), the Loader (loaded working set + code memory management), and
  the CompileLock (serialised runtime compilation).
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SetmyInfo.ElixirModuleLoader.Supervisor
    ]

    opts = [strategy: :one_for_one, name: SetmyInfo.ElixirModuleLoader.ApplicationSupervisor]
    Supervisor.start_link(children, opts)
  end
end
