defmodule SetmyInfo.ElixirModuleLoader.CompileLock do
  @moduledoc """
  Serialisation point for runtime compilation.

  `SetmyInfo.ElixirModuleLoader.Compiler` source/file compilation toggles the
  VM-global `:ignore_module_conflict` compiler flag, so only one compilation
  may run at a time. Funnelling every compile through this GenServer's mailbox
  provides that mutual exclusion.

  This lock is deliberately its own process (rather than reusing the Registry
  GenServer) so a slow compilation — up to 60 seconds — can never block
  registry writes like `register/2` or `unregister/1`.
  """

  use GenServer

  alias SetmyInfo.ElixirModuleLoader.Compiler

  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:compile, spec}, _from, state) do
    {:reply, Compiler.run_compile(spec), state}
  end
end
