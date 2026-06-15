defmodule SetmyInfo.ElixirModuleLoader.E2E.UUIDFlowTest do
  @moduledoc """
  End-to-end test of UUID/key interchangeability: compile assigns a 128-bit
  key; `key_to_uuid/1` converts it to a UUID string; both forms address the
  same registry entry for load, release, and function discovery.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader, as: ML
  alias SetmyInfo.ElixirModuleLoader.{Registry, UUID}

  @fixture_path Path.expand("../fixtures/sample_module.ex", __DIR__)
  @module SetmyInfo.ElixirModuleLoader.Support.SampleModule

  describe "binary key and UUID string are interchangeable" do
    test "compile returns a binary key; key_to_uuid converts it to UUID" do
      {:ok, key, _module} = ML.compile_file(@fixture_path)
      uuid = ML.key_to_uuid(key)

      assert byte_size(key) == 16
      assert String.length(uuid) == 36
      assert UUID.to_key!(uuid) == key

      on_exit(fn ->
        if ML.loaded?(key), do: ML.release(key)
        Registry.unregister(key)
      end)
    end

    test "load/1 accepts both key and UUID for the same entry" do
      {:ok, key, _module} = ML.compile_file(@fixture_path)
      uuid = ML.key_to_uuid(key)

      on_exit(fn ->
        if ML.loaded?(key), do: ML.release(key)
        Registry.unregister(key)
      end)

      {:ok, m1} = ML.load(key)
      {:ok, m2} = ML.load(uuid)
      assert m1 == m2
      assert m1 == @module
    end

    test "loaded?/1 reports the same state via both forms" do
      {:ok, key, _module} = ML.compile_file(@fixture_path)
      uuid = ML.key_to_uuid(key)

      on_exit(fn ->
        if ML.loaded?(key), do: ML.release(key)
        Registry.unregister(key)
      end)

      assert ML.loaded?(key)
      assert ML.loaded?(uuid)

      ML.release(uuid)
      refute ML.loaded?(key)
      refute ML.loaded?(uuid)
    end

    test "release by UUID removes the entry tracked under the binary key" do
      {:ok, key, module} = ML.compile_file(@fixture_path)
      uuid = ML.key_to_uuid(key)

      on_exit(fn ->
        if ML.loaded?(key), do: ML.release(key)
        Registry.unregister(key)
      end)

      assert 5 == module.add(2, 3)
      assert ML.loaded?(key)

      :ok = ML.release(uuid)
      refute ML.loaded?(key)
    end

    test "functions/1 works with UUID string" do
      {:ok, key, _module} = ML.compile_file(@fixture_path)
      uuid = ML.key_to_uuid(key)

      on_exit(fn ->
        if ML.loaded?(key), do: ML.release(key)
        Registry.unregister(key)
      end)

      {:ok, exports} = ML.functions(uuid)
      assert {:add, 2} in exports
      assert {:multiply, 2} in exports
    end
  end

  describe "generate_uuid workflow" do
    test "a UUID generated upfront can address a compiled module" do
      uuid = ML.generate_uuid()
      key = UUID.to_key!(uuid)

      {:ok, compiled_key, _module} = ML.compile_file(@fixture_path)
      compiled_uuid = ML.key_to_uuid(compiled_key)

      on_exit(fn ->
        if ML.loaded?(compiled_key), do: ML.release(compiled_key)
        Registry.unregister(compiled_key)
      end)

      assert is_binary(uuid)
      assert byte_size(key) == 16
      assert String.length(compiled_uuid) == 36

      {:ok, m} = ML.load(compiled_uuid)
      assert 7 == m.add(3, 4)
    end
  end
end
