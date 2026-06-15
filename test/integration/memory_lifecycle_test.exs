defmodule SetmyInfo.ElixirModuleLoader.Integration.MemoryLifecycleTest do
  @moduledoc """
  Integration tests for the memory side of the lifecycle: releasing frees the
  module's compiled code, purging is reference-counted across keys, and a
  released module is restorable on the next load — from an in-memory BEAM
  binary or by recompiling the `.ex` source.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader
  alias SetmyInfo.ElixirModuleLoader.Registry

  defp probe_source(name) do
    """
    defmodule #{name} do
      def ping(x), do: {:pong, x}
    end
    """
  end

  describe "release purges library-managed code" do
    test "compile: code is gone after release, restored on next load" do
      {:ok, key, module} = ElixirModuleLoader.compile(probe_source("MemProbeA"))

      assert {:pong, 1} == module.ping(1)
      :ok = ElixirModuleLoader.release(key)

      assert :code.is_loaded(module) == false

      {:ok, restored} = ElixirModuleLoader.load(key)
      assert {:pong, 2} == restored.ping(2)

      :ok = ElixirModuleLoader.release(key)
      Registry.unregister(key)
    end

    test "compile_file (.ex): code purged on release, restored by recompile" do
      dir = Path.join(System.tmp_dir!(), "eml_mem_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      path = Path.join(dir, "probe.ex")
      File.write!(path, probe_source("MemProbeB"))

      {:ok, key, module} = ElixirModuleLoader.compile_file(path)

      :ok = ElixirModuleLoader.release(key)
      assert :code.is_loaded(module) == false

      {:ok, restored} = ElixirModuleLoader.load(key)
      assert {:pong, :again} == restored.ping(:again)

      :ok = ElixirModuleLoader.release(key)
      Registry.unregister(key)
    end

    test "load_by_name: code is NOT purged (externally managed)" do
      {:ok, key, module} =
        ElixirModuleLoader.load_by_name(SetmyInfo.ElixirModuleLoader.Modules.Math)

      :ok = ElixirModuleLoader.release(key)

      assert {:file, _} = :code.is_loaded(module)

      Registry.unregister(key)
    end
  end

  describe "reference-counted purge across keys" do
    test "code survives while another loaded key uses the same module" do
      {:ok, key_a, module} = ElixirModuleLoader.compile(probe_source("MemProbeD"))
      {:ok, key_b, ^module} = ElixirModuleLoader.compile(probe_source("MemProbeD"))

      assert {:pong, :a} == module.ping(:a)

      :ok = ElixirModuleLoader.release(key_a)
      assert {:file, _} = :code.is_loaded(module)
      assert {:pong, :b} == module.ping(:b)

      :ok = ElixirModuleLoader.release(key_b)
      assert :code.is_loaded(module) == false

      Registry.unregister(key_a)
      Registry.unregister(key_b)
    end
  end

  describe "reload by release + load triggers recompile" do
    test "a changed .ex file is recompiled on next load after release" do
      dir = Path.join(System.tmp_dir!(), "eml_reload_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      path = Path.join(dir, "versioned.ex")
      File.write!(path, "defmodule MemProbeE do def version, do: 1 end")

      {:ok, key, module} = ElixirModuleLoader.compile_file(path)
      assert 1 == module.version()

      File.write!(path, "defmodule MemProbeE do def version, do: 2 end")

      :ok = ElixirModuleLoader.release(key)
      {:ok, ^module} = ElixirModuleLoader.load(key)
      assert 2 == module.version()

      :ok = ElixirModuleLoader.release(key)
      Registry.unregister(key)
    end
  end
end
