defmodule SetmyInfo.ElixirModuleLoader.E2E.UUIDFlowTest do
  @moduledoc """
  End-to-end test of the UUID-facing API: a Library user generates a UUID,
  registers a module file under it, then loads / requests / releases by UUID.
  Also verifies UUID and 128-bit forms address the same registry entry.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader, as: ML
  alias SetmyInfo.ElixirModuleLoader.UUID

  @fixture_path Path.expand("../fixtures/sample_module.ex", __DIR__)
  @module SetmyInfo.ElixirModuleLoader.Support.SampleModule

  describe "register_file/2 + UUID lifecycle" do
    setup do
      uuid = ML.generate_uuid()

      on_exit(fn ->
        if ML.loaded?(uuid), do: ML.release(uuid)
        ML.unregister(uuid)
      end)

      {:ok, uuid: uuid}
    end

    test "register a .ex file, then request and release by UUID", %{uuid: uuid} do
      assert {:ok, @module} = ML.register_file(uuid, @fixture_path)
      assert ML.registered?(uuid)

      assert {:ok, _pid} = ML.load(uuid)
      assert ML.loaded?(uuid)
      assert {:ok, 5} = ML.execute(uuid, :add, [2, 3])

      assert :ok = ML.release(uuid)
      refute ML.loaded?(uuid)
    end

    test "run_and_release/3 by UUID", %{uuid: uuid} do
      {:ok, @module} = ML.register_file(uuid, @fixture_path)
      refute ML.loaded?(uuid)
      assert {:ok, 12} = ML.run_and_release(uuid, :multiply, [3, 4])
      refute ML.loaded?(uuid)
    end
  end

  describe "UUID and 128-bit forms are interchangeable" do
    test "register by UUID, look up / execute by its binary key" do
      uuid = ML.generate_uuid()
      key = UUID.to_key!(uuid)

      on_exit(fn ->
        if ML.loaded?(key), do: ML.release(key)
        ML.unregister(key)
      end)

      {:ok, @module} = ML.register_file(uuid, @fixture_path)

      # Looked up by the binary form of the same id.
      assert {:ok, @module} = ML.lookup(key)
      assert ML.registered?(key)

      {:ok, _pid} = ML.load(key)
      assert {:ok, 7} = ML.execute(key, :add, [3, 4])
    end

    test "register by binary key, release by UUID" do
      key = ML.generate_key()
      uuid = UUID.from_key(key)

      on_exit(fn ->
        if ML.loaded?(uuid), do: ML.release(uuid)
        ML.unregister(uuid)
      end)

      :ok = ML.register(key, @module)
      {:ok, _pid} = ML.load(uuid)
      assert ML.loaded?(key)
      assert :ok = ML.release(uuid)
      refute ML.loaded?(key)
    end
  end
end
