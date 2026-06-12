defmodule SetmyInfo.ElixirModuleLoader.Executor do
  @moduledoc """
  High-level facade for the load → execute → release lifecycle.

  Callers that only need a single result should prefer `run_and_release/3`,
  which cleans up resources automatically.  For repeated calls to the same
  module, use `run/3` and call `Loader.release/1` explicitly when done.
  """

  alias SetmyInfo.ElixirModuleLoader.{Loader, Worker}

  @doc """
  Load the module (if not already loaded) and execute the function, leaving
  the Worker running for subsequent calls.
  """
  @spec run(<<_::128>>, atom(), [term()]) :: {:ok, term()} | {:error, term()}
  def run(<<_::128>> = key, function, args) do
    with {:ok, _pid} <- Loader.load(key) do
      Worker.execute(key, function, args)
    end
  end

  @doc """
  Load the module, execute the function, then immediately release the module.
  The full load → execute → release lifecycle in a single call.

  The execute result is always returned, even when a concurrent caller has
  already released the key (the release is best-effort).
  """
  @spec run_and_release(<<_::128>>, atom(), [term()]) :: {:ok, term()} | {:error, term()}
  def run_and_release(<<_::128>> = key, function, args) do
    with {:ok, _pid} <- Loader.load(key) do
      result = Worker.execute(key, function, args)
      # Best-effort: a concurrent release may have won the race; the caller
      # still gets the execute result, not the release error.
      Loader.release(key)
      result
    end
  end
end
