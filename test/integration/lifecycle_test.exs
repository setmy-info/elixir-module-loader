defmodule SetmyInfo.ElixirModuleLoader.Integration.LifecycleTest do
  @moduledoc """
  Integration test: compile → register → load → direct call → release.

  All assertions run against the live OTP supervision tree — no mocks. The
  library hands the module back on load; calls are plain Elixir.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader, as: EML
  alias SetmyInfo.ElixirModuleLoader.{Loader, Registry}

  @source """
  defmodule SetmyInfo.ElixirModuleLoader.Integration.MathPlugin do
    def add(a, b), do: a + b
    def multiply(a, b), do: a * b
  end
  """

  setup do
    key = :crypto.strong_rand_bytes(16)
    {:ok, module} = EML.register_source(key, @source)

    on_exit(fn ->
      if Loader.loaded?(key), do: Loader.release(key)
      Registry.unregister(key)
    end)

    {:ok, key: key, module: module}
  end

  test "step 1 – compile: source loads into VM", %{module: module} do
    assert function_exported?(module, :add, 2)
  end

  test "step 2 – register: key maps to module", %{key: key, module: module} do
    assert {:ok, module} == Registry.lookup(key)
  end

  test "step 3 – load: returns the module itself", %{key: key, module: module} do
    assert {:ok, ^module} = EML.load(key)
    assert EML.loaded?(key)
  end

  test "step 4 – direct call: add(2, 3) returns 5", %{key: key} do
    {:ok, math} = EML.load(key)
    assert 5 == math.add(2, 3)
    # Dynamic form — function name as runtime data.
    assert 5 == apply(math, :add, [2, 3])
  end

  test "step 5 – release: key leaves the working set", %{key: key} do
    {:ok, _module} = EML.load(key)
    :ok = EML.release(key)
    refute EML.loaded?(key)
  end

  test "full lifecycle: compile → register → load → call → release", %{key: key} do
    {:ok, math} = EML.load(key)
    assert 12 == math.multiply(3, 4)
    :ok = EML.release(key)
    refute EML.loaded?(key)
  end

  test "module can be loaded again after release", %{key: key} do
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
