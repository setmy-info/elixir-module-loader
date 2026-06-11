defmodule SetmyInfo.ElixirModuleLoader.ExecutorTest do
  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader.{Executor, Loader, Registry}

  setup do
    key = :crypto.strong_rand_bytes(16)
    Registry.register(key, SetmyInfo.ElixirModuleLoader.Modules.Math)

    on_exit(fn ->
      Loader.list_loaded() |> Enum.each(&Loader.release/1)
      Registry.unregister(key)
    end)

    {:ok, key: key}
  end

  describe "run/3" do
    test "loads, executes, and keeps the module loaded", %{key: key} do
      assert {:ok, 5} = Executor.run(key, :add, [2, 3])
      assert Loader.loaded?(key)
    end

    test "multiple calls reuse the same Worker", %{key: key} do
      Executor.run(key, :add, [1, 1])
      Executor.run(key, :add, [2, 2])
      assert [key] == Loader.list_loaded()
    end

    test "unknown function returns error", %{key: key} do
      assert {:error, {:undefined_function, :unknown}} = Executor.run(key, :unknown, [])
    end
  end

  describe "run_and_release/3" do
    test "executes and releases the module", %{key: key} do
      assert {:ok, 5} = Executor.run_and_release(key, :add, [2, 3])
      refute Loader.loaded?(key)
    end

    test "multiply via run_and_release", %{key: key} do
      assert {:ok, 12} = Executor.run_and_release(key, :multiply, [3, 4])
    end

    test "unknown function returns error", %{key: key} do
      assert {:error, {:undefined_function, :unknown}} =
               Executor.run_and_release(key, :unknown, [])
    end
  end
end
