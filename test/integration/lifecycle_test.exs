defmodule SetmyInfo.ElixirModuleLoader.Integration.LifecycleTest do
  @moduledoc """
  Integration test: compile → load → direct call → release lifecycle using
  the public API. All assertions run against the live OTP supervision tree.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader, as: EML
  alias SetmyInfo.ElixirModuleLoader.Registry

  @source """
  defmodule SetmyInfo.ElixirModuleLoader.Integration.MathPlugin do
    def add(a, b), do: a + b
    def multiply(a, b), do: a * b
  end
  """

  setup do
    {:ok, key, module} = EML.compile(@source)

    on_exit(fn ->
      if EML.loaded?(key), do: EML.release(key)
      Registry.unregister(key)
    end)

    {:ok, key: key, module: module}
  end

  test "compile returns the module, already loaded", %{key: key, module: module} do
    assert function_exported?(module, :add, 2)
    assert EML.loaded?(key)
  end

  test "load/1 by key returns the same module", %{key: key, module: module} do
    assert {:ok, ^module} = EML.load(key)
  end

  test "load/1 is idempotent", %{key: key, module: module} do
    assert {:ok, ^module} = EML.load(key)
    assert {:ok, ^module} = EML.load(key)
  end

  test "direct call: add(2, 3) returns 5", %{key: key} do
    {:ok, math} = EML.load(key)
    assert 5 == math.add(2, 3)
    assert 5 == apply(math, :add, [2, 3])
  end

  test "release removes the key from the working set", %{key: key} do
    assert EML.loaded?(key)
    :ok = EML.release(key)
    refute EML.loaded?(key)
  end

  test "full lifecycle: compile → load → call → release", %{key: key} do
    {:ok, math} = EML.load(key)
    assert 12 == math.multiply(3, 4)
    :ok = EML.release(key)
    refute EML.loaded?(key)
  end

  test "module is loadable again after release", %{key: key} do
    {:ok, _} = EML.load(key)
    :ok = EML.release(key)
    {:ok, math} = EML.load(key)
    assert 5 == math.add(2, 3)
  end

  test "functions/1 discovers the exports dynamically", %{key: key} do
    {:ok, exports} = EML.functions(key)
    assert {:add, 2} in exports
    assert {:multiply, 2} in exports
  end
end
