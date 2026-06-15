defmodule SetmyInfo.ElixirModuleLoader.Integration.ConcurrentTest do
  @moduledoc """
  Integration test: concurrent compile, load, call, and release from many
  processes. Verifies that the GenServer-backed Registry and Loader are
  process-safe.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader, as: EML
  alias SetmyInfo.ElixirModuleLoader.Registry

  test "many processes compiling and loading distinct keys without races" do
    n = 20

    tasks =
      for i <- 1..n do
        Task.async(fn ->
          source = """
          defmodule SetmyInfo.ElixirModuleLoader.Integration.ConcurrentMod#{i} do
            def double(n), do: n * 2
          end
          """

          {:ok, key, module} = EML.compile(source)
          assert i * 2 == module.double(i)
          :ok = EML.release(key)
          Registry.unregister(key)
          :done
        end)
      end

    results = Task.await_many(tasks, 30_000)
    assert Enum.all?(results, &(&1 == :done))
  end

  test "concurrent loads on the same compiled key are idempotent" do
    {:ok, key, _module} =
      EML.compile("""
      defmodule SetmyInfo.ElixirModuleLoader.Integration.ConcurrentShared do
        def double(n), do: n * 2
      end
      """)

    on_exit(fn ->
      if EML.loaded?(key), do: EML.release(key)
      Registry.unregister(key)
    end)

    tasks = for _ <- 1..10, do: Task.async(fn -> EML.load(key) end)
    results = Task.await_many(tasks, 5_000)

    modules = Enum.map(results, fn {:ok, module} -> module end)
    assert [_one] = Enum.uniq(modules)
  end

  test "hot swap: calls pick up new code after re-compile" do
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

    {:ok, key, module} = EML.compile(v1)
    assert 1 == module.value()

    on_exit(fn ->
      if EML.loaded?(key), do: EML.release(key)
      Registry.unregister(key)
    end)

    {:ok, _key2, _module2} = EML.compile(v2)
    assert 99 == module.value()

    EML.release(key)
  end
end
