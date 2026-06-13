defmodule SetmyInfo.ElixirModuleLoader.E2E.ModuleLoaderTest do
  @moduledoc """
  End-to-end test exercising the full public API facade (`ElixirModuleLoader`).

  Uses the file-based fixture to verify compile-from-file, register, load,
  direct call, and release — no execute/run dispatch, all calls are the
  caller's responsibility after `load/1` returns the module.
  """

  use ExUnit.Case, async: false

  @fixture_path Path.expand("../fixtures/sample_module.ex", __DIR__)
  @module SetmyInfo.ElixirModuleLoader.Support.SampleModule

  setup do
    key = SetmyInfo.ElixirModuleLoader.generate_key()

    on_exit(fn ->
      if SetmyInfo.ElixirModuleLoader.loaded?(key), do: SetmyInfo.ElixirModuleLoader.release(key)
      SetmyInfo.ElixirModuleLoader.unregister(key)
    end)

    {:ok, key: key}
  end

  test "generate_key/0 returns a 16-byte binary" do
    key = SetmyInfo.ElixirModuleLoader.generate_key()
    assert is_binary(key)
    assert byte_size(key) == 16
  end

  test "full e2e: compile file → register → load → direct call → release", %{key: key} do
    assert {:ok, _modules} = SetmyInfo.ElixirModuleLoader.compile_file(@fixture_path)

    :ok = SetmyInfo.ElixirModuleLoader.register(key, @module)
    assert SetmyInfo.ElixirModuleLoader.registered?(key)

    {:ok, module} = SetmyInfo.ElixirModuleLoader.load(key)
    assert SetmyInfo.ElixirModuleLoader.loaded?(key)

    assert 10 == module.add(3, 7)
    assert 21 == module.multiply(3, 7)
    assert "hello" == module.echo("hello")

    :ok = SetmyInfo.ElixirModuleLoader.release(key)
    refute SetmyInfo.ElixirModuleLoader.loaded?(key)
  end

  test "load → call → release lifecycle", %{key: key} do
    SetmyInfo.ElixirModuleLoader.compile_file(@fixture_path)
    SetmyInfo.ElixirModuleLoader.register(key, @module)

    refute SetmyInfo.ElixirModuleLoader.loaded?(key)
    {:ok, module} = SetmyInfo.ElixirModuleLoader.load(key)
    assert 5 == module.add(2, 3)
    :ok = SetmyInfo.ElixirModuleLoader.release(key)
    refute SetmyInfo.ElixirModuleLoader.loaded?(key)
  end

  test "load is idempotent — multiple calls return same module", %{key: key} do
    SetmyInfo.ElixirModuleLoader.compile_file(@fixture_path)
    SetmyInfo.ElixirModuleLoader.register(key, @module)

    {:ok, m1} = SetmyInfo.ElixirModuleLoader.load(key)
    {:ok, m2} = SetmyInfo.ElixirModuleLoader.load(key)
    assert m1 == m2
    assert 5 == m1.add(2, 3)
    assert 6 == m1.add(2, 4)
    assert SetmyInfo.ElixirModuleLoader.loaded?(key)
  end

  test "reload/1 returns the module and keeps it callable", %{key: key} do
    SetmyInfo.ElixirModuleLoader.compile_file(@fixture_path)
    SetmyInfo.ElixirModuleLoader.register(key, @module)

    {:ok, module} = SetmyInfo.ElixirModuleLoader.load(key)
    assert 5 == module.add(2, 3)

    {:ok, reloaded} = SetmyInfo.ElixirModuleLoader.reload(key)
    assert reloaded == module
    assert 5 == reloaded.add(2, 3)
  end

  test "load_beam_binary/2 loads module from BEAM binary and makes it callable", %{key: _key} do
    {:ok, [{module, binary}]} = SetmyInfo.ElixirModuleLoader.compile_file(@fixture_path)
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)

    assert :ok == SetmyInfo.ElixirModuleLoader.load_beam_binary(module, binary)
    assert 5 == module.add(2, 3)
  end

  test "two distinct keys, two distinct modules loaded concurrently", %{key: key1} do
    key2 = SetmyInfo.ElixirModuleLoader.generate_key()

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

    {:ok, [{mod_a, _}]} = SetmyInfo.ElixirModuleLoader.compile(source_a)
    {:ok, [{mod_b, _}]} = SetmyInfo.ElixirModuleLoader.compile(source_b)
    SetmyInfo.ElixirModuleLoader.register(key1, mod_a)
    SetmyInfo.ElixirModuleLoader.register(key2, mod_b)

    on_exit(fn ->
      if SetmyInfo.ElixirModuleLoader.loaded?(key2),
        do: SetmyInfo.ElixirModuleLoader.release(key2)

      SetmyInfo.ElixirModuleLoader.unregister(key2)
    end)

    {:ok, m1} = SetmyInfo.ElixirModuleLoader.load(key1)
    {:ok, m2} = SetmyInfo.ElixirModuleLoader.load(key2)

    assert :a == m1.value()
    assert :b == m2.value()

    SetmyInfo.ElixirModuleLoader.release(key1)
    SetmyInfo.ElixirModuleLoader.release(key2)
  end
end
