defmodule SetmyInfo.ElixirModuleLoader.Integration.ConcurrentTest do
  @moduledoc """
  Integration test: concurrent register, load, call, and release from many
  processes. Verifies that the GenServer-backed Registry and Loader are
  process-safe.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader, as: EML
  alias SetmyInfo.ElixirModuleLoader.{Compiler, Loader, Registry}

  @source """
  defmodule SetmyInfo.ElixirModuleLoader.Integration.ConcurrentPlugin do
    def double(n), do: n * 2
  end
  """

  setup do
    {:ok, _} = Compiler.from_source(@source)
    :ok
  end

  test "many processes can register, load, call and release distinct keys without races" do
    n = 20

    tasks =
      for i <- 1..n do
        Task.async(fn ->
          key = :crypto.strong_rand_bytes(16)
          :ok = Registry.register(key, SetmyInfo.ElixirModuleLoader.Integration.ConcurrentPlugin)
          {:ok, module} = EML.load(key)
          assert i * 2 == module.double(i)
          :ok = EML.release(key)
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

    tasks = for _ <- 1..10, do: Task.async(fn -> EML.load(key) end)
    results = Task.await_many(tasks, 5_000)

    modules = Enum.map(results, fn {:ok, module} -> module end)
    assert [_one] = Enum.uniq(modules)
  end

  test "hot swap: direct calls pick up new code without re-loading" do
    key = :crypto.strong_rand_bytes(16)

    v1 = """
    defmodule SetmyInfo.ElixirModuleLoader.Integration.HotPlugin do
      def value, do: 1
    end
    """

    v2 = """
    defmodule SetmyInfo.ElixirModuleLoader.Integration.HotPlugin do
      def value, do: 99
    end
    """

    {:ok, _} = Compiler.from_source(v1)
    :ok = Registry.register(key, SetmyInfo.ElixirModuleLoader.Integration.HotPlugin)
    {:ok, module} = EML.load(key)

    assert 1 == module.value()

    {:ok, _} = Compiler.from_source(v2)

    # Fully-qualified calls always hit the current code version.
    assert 99 == module.value()

    EML.release(key)
    Registry.unregister(key)
  end
end
