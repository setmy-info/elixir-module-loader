defmodule SetmyInfo.ElixirModuleLoader.E2E.UUIDFlowTest do
  @moduledoc """
  End-to-end test of the UUID-facing API: a library user generates a UUID,
  registers a module file under it, then loads / calls / releases by UUID.
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

    test "register a .ex file, then load and call by UUID", %{uuid: uuid} do
      assert {:ok, @module} = ML.register_file(uuid, @fixture_path)
      assert ML.registered?(uuid)

      {:ok, module} = ML.load(uuid)
      assert ML.loaded?(uuid)
      assert 5 == module.add(2, 3)

      assert :ok = ML.release(uuid)
      refute ML.loaded?(uuid)
    end

    test "load → call → release pattern by UUID", %{uuid: uuid} do
      {:ok, @module} = ML.register_file(uuid, @fixture_path)
      refute ML.loaded?(uuid)

      {:ok, module} = ML.load(uuid)
      result = module.multiply(3, 4)
      :ok = ML.release(uuid)

      assert result == 12
      refute ML.loaded?(uuid)
    end
  end

  describe "UUID and 128-bit forms are interchangeable" do
    test "register by UUID, look up and call by its binary key" do
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

      {:ok, module} = ML.load(key)
      assert 7 == module.add(3, 4)
    end

    test "register by binary key, release by UUID" do
      key = ML.generate_key()
      uuid = UUID.from_key(key)

      on_exit(fn ->
        if ML.loaded?(uuid), do: ML.release(uuid)
        ML.unregister(uuid)
      end)

      :ok = ML.register(key, @module)
      {:ok, _module} = ML.load(uuid)
      assert ML.loaded?(key)
      assert :ok = ML.release(uuid)
      refute ML.loaded?(key)
    end
  end
end
