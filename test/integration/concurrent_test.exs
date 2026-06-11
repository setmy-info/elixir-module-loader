defmodule SetmyInfo.ElixirModuleLoader.Integration.ConcurrentTest do
  @moduledoc """
  Integration test: concurrent register, load, execute, and release from many processes.

  Verifies that the GenServer-backed Registry and Loader are process-safe.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader.{Compiler, Loader, Registry, Worker}

  @source """
  defmodule SetmyInfo.ElixirModuleLoader.Integration.ConcurrentPlugin do
    @behaviour SetmyInfo.ElixirModuleLoader.Behaviour
    def name, do: :concurrent_plugin
    def execute(:double, [n]), do: {:ok, n * 2}
    def execute(f, _), do: {:error, {:undefined_function, f}}
  end
  """

  setup do
    {:ok, _} = Compiler.from_source(@source)
    :ok
  end

  test "many processes can register and load distinct keys without races" do
    n = 20

    tasks =
      for i <- 1..n do
        Task.async(fn ->
          key = :crypto.strong_rand_bytes(16)
          :ok = Registry.register(key, SetmyInfo.ElixirModuleLoader.Integration.ConcurrentPlugin)
          {:ok, _pid} = Loader.load(key)
          assert {:ok, i * 2} == Worker.execute(key, :double, [i])
          :ok = Loader.release(key)
          Registry.unregister(key)
          :done
        end)
      end

    results = Task.await_many(tasks, 5_000)
    assert Enum.all?(results, &(&1 == :done))
  end

  test "concurrent loads on the same key are idempotent" do
    key = :crypto.strong_rand_bytes(16)
    :ok = Registry.register(key, SetmyInfo.ElixirModuleLoader.Integration.ConcurrentPlugin)

    on_exit(fn ->
      if Loader.loaded?(key), do: Loader.release(key)
      Registry.unregister(key)
    end)

    tasks = for _ <- 1..10, do: Task.async(fn -> Loader.load(key) end)
    results = Task.await_many(tasks, 5_000)

    pids = Enum.map(results, fn {:ok, pid} -> pid end)
    unique_pids = Enum.uniq(pids)

    assert length(unique_pids) == 1, "All concurrent loads must return the same Worker PID"
    assert Process.alive?(hd(unique_pids))
  end

  test "hot swap: Worker stays alive, new code is picked up" do
    key = :crypto.strong_rand_bytes(16)

    v1 = """
    defmodule SetmyInfo.ElixirModuleLoader.Integration.HotPlugin do
      @behaviour SetmyInfo.ElixirModuleLoader.Behaviour
      def name, do: :hot_plugin
      def execute(:value, []), do: {:ok, 1}
      def execute(f, _), do: {:error, {:undefined_function, f}}
    end
    """

    v2 = """
    defmodule SetmyInfo.ElixirModuleLoader.Integration.HotPlugin do
      @behaviour SetmyInfo.ElixirModuleLoader.Behaviour
      def name, do: :hot_plugin
      def execute(:value, []), do: {:ok, 99}
      def execute(f, _), do: {:error, {:undefined_function, f}}
    end
    """

    {:ok, _} = Compiler.from_source(v1)
    :ok = Registry.register(key, SetmyInfo.ElixirModuleLoader.Integration.HotPlugin)
    {:ok, pid} = Loader.load(key)

    assert {:ok, 1} == Worker.execute(key, :value, [])

    {:ok, _} = Compiler.from_source(v2)

    assert Process.alive?(pid), "Worker must survive hot swap"
    assert {:ok, 99} == Worker.execute(key, :value, [])

    Loader.release(key)
    Registry.unregister(key)
  end
end
