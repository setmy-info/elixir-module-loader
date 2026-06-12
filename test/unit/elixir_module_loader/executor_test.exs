defmodule SetmyInfo.ElixirModuleLoader.ExecutorTest do
  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader.{Executor, Loader, Registry}

  setup do
    math_key = :crypto.strong_rand_bytes(16)
    string_key = :crypto.strong_rand_bytes(16)
    Registry.register(math_key, SetmyInfo.ElixirModuleLoader.Modules.Math)
    Registry.register(string_key, SetmyInfo.ElixirModuleLoader.Modules.StringOps)

    on_exit(fn ->
      Loader.list_loaded() |> Enum.each(&Loader.release/1)
      Registry.unregister(math_key)
      Registry.unregister(string_key)
    end)

    {:ok, key: math_key, string_key: string_key}
  end

  describe "run/3 — Math" do
    test "loads, executes, and keeps the module loaded", %{key: key} do
      assert {:ok, 5} = Executor.run(key, :add, [2, 3])
      assert Loader.loaded?(key)
    end

    test "multiple calls reuse the same Worker", %{key: key} do
      Executor.run(key, :add, [1, 1])
      Executor.run(key, :add, [2, 2])
      assert key in Loader.list_loaded()
    end

    test "unknown function returns error", %{key: key} do
      assert {:error, {:undefined_function, :unknown}} = Executor.run(key, :unknown, [])
    end
  end

  describe "run_and_release/3 — Math" do
    test "add", %{key: key} do
      assert {:ok, 5} = Executor.run_and_release(key, :add, [2, 3])
      refute Loader.loaded?(key)
    end

    test "subtract", %{key: key} do
      assert {:ok, 1} = Executor.run_and_release(key, :subtract, [3, 2])
    end

    test "multiply", %{key: key} do
      assert {:ok, 12} = Executor.run_and_release(key, :multiply, [3, 4])
    end

    test "divide", %{key: key} do
      assert {:ok, 2.5} = Executor.run_and_release(key, :divide, [5, 2])
    end

    test "divide by zero returns error", %{key: key} do
      assert {:error, :division_by_zero} = Executor.run_and_release(key, :divide, [1, 0])
    end

    test "undefined function returns error", %{key: key} do
      assert {:error, {:undefined_function, :unknown}} =
               Executor.run_and_release(key, :unknown, [])
    end
  end

  describe "run_and_release/3 — StringOps" do
    test "upcase", %{string_key: key} do
      assert {:ok, "HELLO"} = Executor.run_and_release(key, :upcase, ["hello"])
    end

    test "downcase", %{string_key: key} do
      assert {:ok, "hello"} = Executor.run_and_release(key, :downcase, ["HELLO"])
    end

    test "reverse", %{string_key: key} do
      assert {:ok, "olleh"} = Executor.run_and_release(key, :reverse, ["hello"])
    end

    test "length", %{string_key: key} do
      assert {:ok, 5} = Executor.run_and_release(key, :length, ["hello"])
    end

    test "trim", %{string_key: key} do
      assert {:ok, "hello"} = Executor.run_and_release(key, :trim, ["  hello  "])
    end

    test "undefined function returns error", %{string_key: key} do
      assert {:error, {:undefined_function, :unknown}} =
               Executor.run_and_release(key, :unknown, [])
    end
  end
end
