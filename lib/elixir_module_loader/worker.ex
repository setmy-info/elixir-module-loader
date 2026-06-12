defmodule SetmyInfo.ElixirModuleLoader.Worker do
  @moduledoc """
  GenServer representing a single loaded module instance.

  Each loaded module runs in its own isolated process, registered under
  `SetmyInfo.ElixirModuleLoader.WorkerRegistry` so it can be found by its 128-bit key
  without going through the Loader.

  State tracks call count for observability and debugging.

  ## Fault isolation

  * The implementation module's `execute/2` is wrapped in a `try` so a crashing
    plugin returns `{:error, {:plugin_error, _}}` to the caller instead of
    taking down both the Worker and the caller.
  * Workers are `restart: :temporary` — if a Worker process itself dies, the
    DynamicSupervisor does **not** silently respawn it under a new PID. The
    Loader observes the `:DOWN` and clears its tracking, keeping state
    consistent with `release/1` semantics.
  """

  use GenServer, restart: :temporary
  require Logger

  @default_timeout 5_000

  # ── Public API ────────────────────────────────────────────────────────────

  def start_link({key, impl_module}) do
    GenServer.start_link(
      __MODULE__,
      {key, impl_module},
      name: via(key)
    )
  end

  @doc """
  Execute `function(args)` on the Worker running under `key`.

  `timeout` (milliseconds, default #{@default_timeout}) bounds how long the
  caller waits for the plugin. A plugin that exceeds it returns
  `{:error, :timeout}` — the caller never crashes. Likewise a Worker that is
  killed or shut down mid-call returns `{:error, :not_loaded}`.
  """
  @spec execute(<<_::128>>, atom(), [term()], timeout()) :: {:ok, term()} | {:error, term()}
  def execute(<<_::128>> = key, function, args, timeout \\ @default_timeout) do
    case Registry.lookup(SetmyInfo.ElixirModuleLoader.WorkerRegistry, key) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, {:execute, function, args}, timeout)
        catch
          :exit, {:noproc, _} -> {:error, :not_loaded}
          :exit, {:normal, _} -> {:error, :not_loaded}
          :exit, {:shutdown, _} -> {:error, :not_loaded}
          :exit, {:killed, _} -> {:error, :not_loaded}
          :exit, {:timeout, _} -> {:error, :timeout}
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
    result = safe_execute(state.impl_module, function, args)
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

  # Run the plugin's execute/2 without letting a crash propagate to the Worker
  # (and therefore to the caller). Errors are normalised to an error tuple.
  defp safe_execute(impl_module, function, args) do
    impl_module.execute(function, args)
  rescue
    e ->
      Logger.warning("[Worker] plugin #{inspect(impl_module)} raised: #{Exception.message(e)}")
      {:error, {:plugin_error, Exception.message(e)}}
  catch
    kind, reason ->
      Logger.warning("[Worker] plugin #{inspect(impl_module)} #{kind}: #{inspect(reason)}")
      {:error, {:plugin_error, {kind, reason}}}
  end

  defp via(key) do
    {:via, Registry, {SetmyInfo.ElixirModuleLoader.WorkerRegistry, key}}
  end
end
