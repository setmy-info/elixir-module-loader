defmodule SetmyInfo.ElixirModuleLoader.LoaderTest do
  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader.{Compiler, Loader, Registry}

  @fixture_source """
  defmodule SetmyInfo.ElixirModuleLoader.Test.LoaderFixture do
    def ping, do: :pong
  end
  """

  setup do
    key = :crypto.strong_rand_bytes(16)
    {:ok, _} = Compiler.from_source(@fixture_source)
    Registry.register(key, SetmyInfo.ElixirModuleLoader.Test.LoaderFixture)

    on_exit(fn ->
      if Loader.loaded?(key), do: Loader.release(key)
      Registry.unregister(key)
    end)

    {:ok, key: key}
  end

  test "load returns the registered module", %{key: key} do
    assert {:ok, module} = Loader.load(key)
    assert module == SetmyInfo.ElixirModuleLoader.Test.LoaderFixture
    assert Loader.loaded?(key)
    assert :pong == module.ping()
  end

  test "load is idempotent", %{key: key} do
    {:ok, mod1} = Loader.load(key)
    {:ok, mod2} = Loader.load(key)
    assert mod1 == mod2
  end

  test "release removes the key from the working set", %{key: key} do
    {:ok, _} = Loader.load(key)
    :ok = Loader.release(key)
    refute Loader.loaded?(key)
    assert {:error, :not_loaded} = Loader.module_for(key)
  end

  test "release on a not-loaded key returns an error", %{key: key} do
    assert {:error, :not_loaded} = Loader.release(key)
  end

  test "reload returns the module again", %{key: key} do
    {:ok, mod1} = Loader.load(key)
    {:ok, mod2} = Loader.reload(key)
    assert mod1 == mod2
    assert Loader.loaded?(key)
  end

  test "module_for and loaded_at report tracking state", %{key: key} do
    assert {:error, :not_loaded} = Loader.module_for(key)
    {:ok, module} = Loader.load(key)
    assert {:ok, ^module} = Loader.module_for(key)
    assert {:ok, %DateTime{}} = Loader.loaded_at(key)
  end

  test "loading an unregistered key fails" do
    unregistered = :crypto.strong_rand_bytes(16)
    assert {:error, :not_found} = Loader.load(unregistered)
  end

  test "list_loaded tracks load/release", %{key: key} do
    refute key in Loader.list_loaded()
    Loader.load(key)
    assert key in Loader.list_loaded()
    Loader.release(key)
    refute key in Loader.list_loaded()
  end
end
