defmodule SetmyInfo.ElixirModuleLoader.E2E.ModuleLoaderTest do
  @moduledoc """
  End-to-end test exercising the full public API facade (`ElixirModuleLoader`).

  Uses the file-based fixture to verify compile-from-file, register, load,
  execute, and release.
  """

  use ExUnit.Case, async: false

  @fixture_path Path.expand("../fixtures/sample_module.ex", __DIR__)

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

  test "full e2e: compile file → register → load → execute → release", %{key: key} do
    assert {:ok, _modules} = SetmyInfo.ElixirModuleLoader.compile_file(@fixture_path)

    :ok =
      SetmyInfo.ElixirModuleLoader.register(
        key,
        SetmyInfo.ElixirModuleLoader.Support.SampleModule
      )

    assert SetmyInfo.ElixirModuleLoader.registered?(key)

    {:ok, _pid} = SetmyInfo.ElixirModuleLoader.load(key)
    assert SetmyInfo.ElixirModuleLoader.loaded?(key)

    assert {:ok, 10} == SetmyInfo.ElixirModuleLoader.execute(key, :add, [3, 7])
    assert {:ok, 21} == SetmyInfo.ElixirModuleLoader.execute(key, :multiply, [3, 7])
    assert {:ok, "hello"} == SetmyInfo.ElixirModuleLoader.execute(key, :echo, ["hello"])

    :ok = SetmyInfo.ElixirModuleLoader.release(key)
    refute SetmyInfo.ElixirModuleLoader.loaded?(key)
  end

  test "run_and_release/3: compile → register → run → auto-release", %{key: key} do
    SetmyInfo.ElixirModuleLoader.compile_file(@fixture_path)
    SetmyInfo.ElixirModuleLoader.register(key, SetmyInfo.ElixirModuleLoader.Support.SampleModule)

    refute SetmyInfo.ElixirModuleLoader.loaded?(key)
    assert {:ok, 5} == SetmyInfo.ElixirModuleLoader.run_and_release(key, :add, [2, 3])
    refute SetmyInfo.ElixirModuleLoader.loaded?(key)
  end

  test "run/3: loads and keeps module alive for repeated calls", %{key: key} do
    SetmyInfo.ElixirModuleLoader.compile_file(@fixture_path)
    SetmyInfo.ElixirModuleLoader.register(key, SetmyInfo.ElixirModuleLoader.Support.SampleModule)

    assert {:ok, 5} == SetmyInfo.ElixirModuleLoader.run(key, :add, [2, 3])
    assert {:ok, 6} == SetmyInfo.ElixirModuleLoader.run(key, :add, [2, 4])
    assert SetmyInfo.ElixirModuleLoader.loaded?(key)
  end

  test "reload/1 starts a fresh Worker and pid_for/1 tracks it", %{key: key} do
    SetmyInfo.ElixirModuleLoader.compile_file(@fixture_path)
    SetmyInfo.ElixirModuleLoader.register(key, SetmyInfo.ElixirModuleLoader.Support.SampleModule)

    {:ok, pid1} = SetmyInfo.ElixirModuleLoader.load(key)
    assert {:ok, ^pid1} = SetmyInfo.ElixirModuleLoader.pid_for(key)

    {:ok, pid2} = SetmyInfo.ElixirModuleLoader.reload(key)
    assert pid1 != pid2
    assert {:ok, ^pid2} = SetmyInfo.ElixirModuleLoader.pid_for(key)
  end

  test "load_beam_binary/2 loads module from BEAM binary", %{key: _key} do
    {:ok, [{module, binary}]} = SetmyInfo.ElixirModuleLoader.compile_file(@fixture_path)
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)

    assert :ok == SetmyInfo.ElixirModuleLoader.load_beam_binary(module, binary)
    assert function_exported?(module, :execute, 2)
  end

  test "two distinct keys, two distinct modules loaded concurrently", %{key: key1} do
    key2 = SetmyInfo.ElixirModuleLoader.generate_key()

    source_a = """
    defmodule SetmyInfo.ElixirModuleLoader.E2E.PluginA do
      @behaviour SetmyInfo.ElixirModuleLoader.Behaviour
      def name, do: :plugin_a
      def execute(:value, []), do: {:ok, :a}
      def execute(f, _), do: {:error, {:undefined_function, f}}
    end
    """

    source_b = """
    defmodule SetmyInfo.ElixirModuleLoader.E2E.PluginB do
      @behaviour SetmyInfo.ElixirModuleLoader.Behaviour
      def name, do: :plugin_b
      def execute(:value, []), do: {:ok, :b}
      def execute(f, _), do: {:error, {:undefined_function, f}}
    end
    """

    SetmyInfo.ElixirModuleLoader.compile(source_a)
    SetmyInfo.ElixirModuleLoader.compile(source_b)
    SetmyInfo.ElixirModuleLoader.register(key1, SetmyInfo.ElixirModuleLoader.E2E.PluginA)
    SetmyInfo.ElixirModuleLoader.register(key2, SetmyInfo.ElixirModuleLoader.E2E.PluginB)

    on_exit(fn ->
      if SetmyInfo.ElixirModuleLoader.loaded?(key2),
        do: SetmyInfo.ElixirModuleLoader.release(key2)

      SetmyInfo.ElixirModuleLoader.unregister(key2)
    end)

    assert {:ok, :a} == SetmyInfo.ElixirModuleLoader.run_and_release(key1, :value, [])
    assert {:ok, :b} == SetmyInfo.ElixirModuleLoader.run_and_release(key2, :value, [])
  end
end
