defmodule SetmyInfo.ElixirModuleLoader.Integration.MemoryLifecycleTest do
  @moduledoc """
  Integration tests for the memory side of the lifecycle: releasing frees the
  module's compiled code, purging is reference-counted across keys, and a
  released module is restorable on the next load — from an in-memory BEAM
  binary, a `.beam` file, or by recompiling the `.ex` source.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader

  defp probe_source(name) do
    """
    defmodule #{name} do
      def ping(x), do: {:pong, x}
    end
    """
  end

  describe "release purges library-managed code" do
    test "register_source: code is gone after release, restored on next load" do
      uuid = ElixirModuleLoader.generate_uuid()
      {:ok, module} = ElixirModuleLoader.register_source(uuid, probe_source("MemProbeA"))

      {:ok, ^module} = ElixirModuleLoader.load(uuid)
      assert {:pong, 1} == module.ping(1)

      :ok = ElixirModuleLoader.release(uuid)
      # Compiled code is removed from the VM code server.
      assert :code.is_loaded(module) == false

      # Loading again restores the code from the kept binary.
      {:ok, restored} = ElixirModuleLoader.load(uuid)
      assert {:pong, 2} == restored.ping(2)

      :ok = ElixirModuleLoader.release(uuid)
      ElixirModuleLoader.unregister(uuid)
    end

    test "register_file (.ex): code purged on release, restored by recompile" do
      dir = Path.join(System.tmp_dir!(), "eml_mem_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      path = Path.join(dir, "probe.ex")
      File.write!(path, probe_source("MemProbeB"))

      uuid = ElixirModuleLoader.generate_uuid()
      {:ok, module} = ElixirModuleLoader.register_file(uuid, path)

      {:ok, _} = ElixirModuleLoader.load(uuid)
      :ok = ElixirModuleLoader.release(uuid)
      assert :code.is_loaded(module) == false

      {:ok, restored} = ElixirModuleLoader.load(uuid)
      assert {:pong, :again} == restored.ping(:again)

      :ok = ElixirModuleLoader.release(uuid)
      ElixirModuleLoader.unregister(uuid)
    end

    test "plain register/2: code is NOT purged (externally managed)" do
      uuid = ElixirModuleLoader.generate_uuid()
      {:ok, [{module, _}]} = ElixirModuleLoader.compile(probe_source("MemProbeC"))
      :ok = ElixirModuleLoader.register(uuid, module)

      {:ok, _} = ElixirModuleLoader.load(uuid)
      :ok = ElixirModuleLoader.release(uuid)

      # No beam_source registered — the library must not purge what it
      # cannot restore.
      assert {:file, _} = :code.is_loaded(module)

      ElixirModuleLoader.unregister(uuid)
    end
  end

  describe "reference-counted purge across keys" do
    test "code survives while another loaded key uses the same module" do
      uuid_a = ElixirModuleLoader.generate_uuid()
      uuid_b = ElixirModuleLoader.generate_uuid()

      {:ok, module} = ElixirModuleLoader.register_source(uuid_a, probe_source("MemProbeD"))
      # Second key, same module, also library-managed.
      {:ok, ^module} = ElixirModuleLoader.register_source(uuid_b, probe_source("MemProbeD"))

      {:ok, _} = ElixirModuleLoader.load(uuid_a)
      {:ok, _} = ElixirModuleLoader.load(uuid_b)

      # Releasing one key must not purge — the other key still uses the module.
      :ok = ElixirModuleLoader.release(uuid_a)
      assert {:file, _} = :code.is_loaded(module)
      assert {:pong, :b} == module.ping(:b)

      # Releasing the last user purges.
      :ok = ElixirModuleLoader.release(uuid_b)
      assert :code.is_loaded(module) == false

      ElixirModuleLoader.unregister(uuid_a)
      ElixirModuleLoader.unregister(uuid_b)
    end
  end

  describe "reload re-restores code from its source" do
    test "a changed .ex file is recompiled on reload (hot swap)" do
      dir = Path.join(System.tmp_dir!(), "eml_reload_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      path = Path.join(dir, "versioned.ex")
      File.write!(path, "defmodule MemProbeE do def version, do: 1 end")

      uuid = ElixirModuleLoader.generate_uuid()
      {:ok, module} = ElixirModuleLoader.register_file(uuid, path)
      {:ok, _} = ElixirModuleLoader.load(uuid)
      assert 1 == module.version()

      File.write!(path, "defmodule MemProbeE do def version, do: 2 end")
      {:ok, ^module} = ElixirModuleLoader.reload(uuid)
      assert 2 == module.version()

      :ok = ElixirModuleLoader.release(uuid)
      ElixirModuleLoader.unregister(uuid)
    end
  end

  describe "public working-set API" do
    test "list_registered/list_loaded/loaded_at expose tracking state" do
      uuid = ElixirModuleLoader.generate_uuid()
      key = SetmyInfo.ElixirModuleLoader.UUID.to_key!(uuid)
      {:ok, module} = ElixirModuleLoader.register_source(uuid, probe_source("MemProbeG"))

      assert {key, module} in ElixirModuleLoader.list_registered()
      refute key in ElixirModuleLoader.list_loaded()
      assert {:error, :not_loaded} = ElixirModuleLoader.loaded_at(uuid)

      {:ok, _} = ElixirModuleLoader.load(uuid)
      assert key in ElixirModuleLoader.list_loaded()
      assert {:ok, %DateTime{}} = ElixirModuleLoader.loaded_at(uuid)
      assert ElixirModuleLoader.count() >= 1

      :ok = ElixirModuleLoader.release(uuid)
      ElixirModuleLoader.unregister(uuid)
    end
  end
end
