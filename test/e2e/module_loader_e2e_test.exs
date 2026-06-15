defmodule SetmyInfo.ElixirModuleLoader.E2E.ModuleLoaderTest do
  @moduledoc """
  End-to-end test exercising the full public API: compile, load, direct call,
  and release. No dispatch layer — the caller owns all function invocations
  after `load/1` returns the module.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader, as: EML
  alias SetmyInfo.ElixirModuleLoader.Registry

  @fixture_path Path.expand("../fixtures/sample_module.ex", __DIR__)
  @module SetmyInfo.ElixirModuleLoader.Support.SampleModule

  test "generate_key/0 returns a 16-byte binary" do
    key = EML.generate_key()
    assert is_binary(key)
    assert byte_size(key) == 16
  end

  test "generate_uuid/0 returns a UUID string" do
    uuid = EML.generate_uuid()
    assert is_binary(uuid)
    assert String.length(uuid) == 36
  end

  test "full e2e: compile file → load → direct call → release" do
    {:ok, key, module} = EML.compile_file(@fixture_path)
    assert module == @module
    assert EML.loaded?(key)

    assert 10 == module.add(3, 7)
    assert 21 == module.multiply(3, 7)
    assert "hello" == module.echo("hello")

    :ok = EML.release(key)
    refute EML.loaded?(key)

    on_exit(fn -> Registry.unregister(key) end)
  end

  test "load → call → release lifecycle" do
    {:ok, key, module} = EML.compile_file(@fixture_path)

    assert EML.loaded?(key)
    assert 5 == module.add(2, 3)
    :ok = EML.release(key)
    refute EML.loaded?(key)

    on_exit(fn -> Registry.unregister(key) end)
  end

  test "load is idempotent — multiple calls return same module" do
    {:ok, key, module} = EML.compile_file(@fixture_path)

    {:ok, m1} = EML.load(key)
    {:ok, m2} = EML.load(key)
    assert m1 == m2
    assert m1 == module
    assert 5 == m1.add(2, 3)

    on_exit(fn ->
      if EML.loaded?(key), do: EML.release(key)
      Registry.unregister(key)
    end)
  end

  test "release then reload restores from registered source" do
    {:ok, key, module} = EML.compile_file(@fixture_path)
    assert 5 == module.add(2, 3)

    :ok = EML.release(key)
    {:ok, restored} = EML.load(key)
    assert restored == module
    assert 5 == restored.add(2, 3)

    :ok = EML.release(key)
    on_exit(fn -> Registry.unregister(key) end)
  end

  test "two distinct keys, two distinct modules loaded concurrently" do
    source_a = """
    defmodule SetmyInfo.ElixirModuleLoader.E2E.PluginA do
      def value, do: :a
    end
    """

    source_b = """
    defmodule SetmyInfo.ElixirModuleLoader.E2E.PluginB do
      def value, do: :b
    end
    """

    {:ok, key1, m1} = EML.compile(source_a)
    {:ok, key2, m2} = EML.compile(source_b)

    on_exit(fn ->
      if EML.loaded?(key1), do: EML.release(key1)
      if EML.loaded?(key2), do: EML.release(key2)
      Registry.unregister(key1)
      Registry.unregister(key2)
    end)

    assert :a == m1.value()
    assert :b == m2.value()

    EML.release(key1)
    EML.release(key2)
  end

  test "load_by_name loads a statically compiled module" do
    {:ok, key, module} = EML.load_by_name(@module)
    assert module == @module
    assert EML.loaded?(key)
    assert 5 == module.add(2, 3)

    :ok = EML.release(key)
    refute EML.loaded?(key)

    on_exit(fn -> Registry.unregister(key) end)
  end

  test "functions/1 discovers exports without knowing the module in advance" do
    {:ok, key, _module} =
      EML.compile("""
      defmodule SetmyInfo.ElixirModuleLoader.E2E.DiscoverFixture do
        def alpha(x), do: x
        def beta(x, y), do: {x, y}
      end
      """)

    on_exit(fn ->
      if EML.loaded?(key), do: EML.release(key)
      Registry.unregister(key)
    end)

    {:ok, exports} = EML.functions(key)
    assert {:alpha, 1} in exports
    assert {:beta, 2} in exports
  end
end
