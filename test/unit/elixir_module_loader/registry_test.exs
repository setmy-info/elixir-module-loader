defmodule SetmyInfo.ElixirModuleLoader.RegistryTest do
  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader.Registry

  setup do
    key = :crypto.strong_rand_bytes(16)
    on_exit(fn -> Registry.unregister(key) end)
    {:ok, key: key}
  end

  describe "register/2 and lookup/1" do
    test "registers a key and looks it up", %{key: key} do
      :ok = Registry.register(key, SomeFakeModule)
      assert {:ok, SomeFakeModule} == Registry.lookup(key)
    end

    test "lookup returns :not_found for unknown key" do
      unknown = :crypto.strong_rand_bytes(16)
      assert {:error, :not_found} == Registry.lookup(unknown)
    end
  end

  describe "registered?/1" do
    test "true after register, false after unregister", %{key: key} do
      refute Registry.registered?(key)
      Registry.register(key, SomeFakeModule)
      assert Registry.registered?(key)
      Registry.unregister(key)
      refute Registry.registered?(key)
    end
  end

  describe "update/2" do
    test "updates the module for an existing key", %{key: key} do
      Registry.register(key, OldModule)
      :ok = Registry.update(key, NewModule)
      assert {:ok, NewModule} == Registry.lookup(key)
    end

    test "returns :not_found when key does not exist" do
      missing = :crypto.strong_rand_bytes(16)
      assert {:error, :not_found} == Registry.update(missing, AnyModule)
    end
  end

  describe "register_many/1" do
    test "bulk registers multiple key→module pairs", %{key: _} do
      keys = for _ <- 1..5, do: :crypto.strong_rand_bytes(16)
      specs = Enum.map(keys, &{&1, SomeFakeModule})
      :ok = Registry.register_many(specs)

      for key <- keys do
        assert {:ok, SomeFakeModule} == Registry.lookup(key)
        Registry.unregister(key)
      end
    end

    test "handles 500 specs without bloat" do
      specs = for _ <- 1..500, do: {:crypto.strong_rand_bytes(16), SomeFakeModule}
      :ok = Registry.register_many(specs)
      before_cleanup = Registry.count()
      assert before_cleanup >= 500

      for {k, _} <- specs, do: Registry.unregister(k)
    end
  end

  describe "count/0" do
    test "increments after register", %{key: key} do
      before = Registry.count()
      Registry.register(key, SomeFakeModule)
      assert Registry.count() == before + 1
    end
  end
end
