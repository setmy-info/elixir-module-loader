defmodule SetmyInfo.ElixirModuleLoader.Worker do
  @moduledoc """
  GenServer representing a single loaded module instance.

  Each loaded module runs in its own isolated process, registered under
  `SetmyInfo.ElixirModuleLoader.WorkerRegistry` so it can be found by its 128-bit key
  without going through the Loader.

  State tracks call count for observability and debugging.
  """

  use GenServer
  require Logger

  # ── Public API ────────────────────────────────────────────────────────────

  def start_link({key, impl_module}) do
    GenServer.start_link(
      __MODULE__,
      {key, impl_module},
      name: via(key)
    )
  end

  @doc "Execute `function(args)` on the Worker running under `key`."
  @spec execute(<<_::128>>, atom(), [term()]) :: {:ok, term()} | {:error, term()}
  def execute(<<_::128>> = key, function, args) do
    case Registry.lookup(SetmyInfo.ElixirModuleLoader.WorkerRegistry, key) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, {:execute, function, args})
        catch
          :exit, {:noproc, _} -> {:error, :not_loaded}
          :exit, {:normal, _} -> {:error, :not_loaded}
          :exit, {:shutdown, _} -> {:error, :not_loaded}
        end

      [] ->
        {:error, :not_loaded}
    end
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init({key, impl_module}) do
    Logger.debug("[Worker] started for #{Base.encode16(key)} via #{inspect(impl_module)}")
    {:ok, %{key: key, impl_module: impl_module, call_count: 0}}
  end

  @impl true
  def handle_call({:execute, function, args}, _from, state) do
    result = state.impl_module.execute(function, args)
    {:reply, result, %{state | call_count: state.call_count + 1}}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug(
      "[Worker] terminating #{Base.encode16(state.key)}, " <>
        "calls=#{state.call_count}, reason=#{inspect(reason)}"
    )
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp via(key) do
    {:via, Registry, {SetmyInfo.ElixirModuleLoader.WorkerRegistry, key}}
  end
end
