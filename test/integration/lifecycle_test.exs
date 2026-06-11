defmodule SetmyInfo.ElixirModuleLoader.Integration.LifecycleTest do
  @moduledoc """
  Integration test: compile → load → execute → release full lifecycle.

  All assertions run against the live OTP supervision tree — no mocks.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader.{Compiler, Executor, Loader, Registry, Worker}

  @source """
  defmodule SetmyInfo.ElixirModuleLoader.Integration.MathPlugin do
    @behaviour SetmyInfo.ElixirModuleLoader.Behaviour
    def name, do: :math_plugin
    def execute(:add, [a, b]), do: {:ok, a + b}
    def execute(:multiply, [a, b]), do: {:ok, a * b}
    def execute(f, _), do: {:error, {:undefined_function, f}}
  end
  """

  setup do
    key = :crypto.strong_rand_bytes(16)
    {:ok, _} = Compiler.from_source(@source)
    :ok = Registry.register(key, SetmyInfo.ElixirModuleLoader.Integration.MathPlugin)

    on_exit(fn ->
      if Loader.loaded?(key), do: Loader.release(key)
      Registry.unregister(key)
    end)

    {:ok, key: key}
  end

  test "step 1 – compile: source loads into VM", %{key: _key} do
    assert function_exported?(SetmyInfo.ElixirModuleLoader.Integration.MathPlugin, :execute, 2)
  end

  test "step 2 – register: key maps to module", %{key: key} do
    assert {:ok, SetmyInfo.ElixirModuleLoader.Integration.MathPlugin} == Registry.lookup(key)
  end

  test "step 3 – load: starts a supervised Worker", %{key: key} do
    {:ok, pid} = Loader.load(key)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "step 4 – execute: add(2, 3) returns 5", %{key: key} do
    Loader.load(key)
    assert {:ok, 5} == Worker.execute(key, :add, [2, 3])
  end

  test "step 5 – release: Worker is gone", %{key: key} do
    {:ok, pid} = Loader.load(key)
    :ok = Loader.release(key)
    refute Process.alive?(pid)
    refute Loader.loaded?(key)
  end

  test "full lifecycle: compile → register → load → execute → release", %{key: key} do
    {:ok, pid} = Loader.load(key)
    assert {:ok, 12} == Worker.execute(key, :multiply, [3, 4])
    :ok = Loader.release(key)
    refute Process.alive?(pid)
    refute Loader.loaded?(key)
  end

  test "Executor.run_and_release/3: full lifecycle in one call", %{key: key} do
    refute Loader.loaded?(key)
    assert {:ok, 7} == Executor.run_and_release(key, :add, [3, 4])
    refute Loader.loaded?(key)
  end

  test "module can be reloaded after release", %{key: key} do
    Loader.load(key)
    Loader.release(key)
    {:ok, _pid} = Loader.load(key)
    assert {:ok, 5} == Worker.execute(key, :add, [2, 3])
  end

  test "executing after release returns :not_loaded", %{key: key} do
    Loader.load(key)
    Loader.release(key)
    assert {:error, :not_loaded} == Worker.execute(key, :add, [1, 2])
  end
end
