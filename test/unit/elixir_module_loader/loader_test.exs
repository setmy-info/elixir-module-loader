defmodule SetmyInfo.ElixirModuleLoader.LoaderTest do
  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader.{Loader, Registry}

  # Inline fixture module registered in setup
  @fixture_source """
  defmodule SetmyInfo.ElixirModuleLoader.Test.LoaderFixture do
    @behaviour SetmyInfo.ElixirModuleLoader.Behaviour
    def name, do: :loader_fixture
    def execute(:ping, []), do: {:ok, :pong}
    def execute(f, _), do: {:error, {:undefined_function, f}}
  end
  """

  setup do
    key = :crypto.strong_rand_bytes(16)
    SetmyInfo.ElixirModuleLoader.Compiler.from_source(@fixture_source)
    Registry.register(key, SetmyInfo.ElixirModuleLoader.Test.LoaderFixture)

    on_exit(fn ->
      if Loader.loaded?(key), do: Loader.release(key)
      Registry.unregister(key)
    end)

    {:ok, key: key}
  end

  test "load/1 starts a Worker and returns {:ok, pid}", %{key: key} do
    assert {:ok, pid} = Loader.load(key)
    assert is_pid(pid)
    assert Process.alive?(pid)
    assert Loader.loaded?(key)
  end

  test "load/1 is idempotent — same PID on second call", %{key: key} do
    {:ok, pid1} = Loader.load(key)
    {:ok, pid2} = Loader.load(key)
    assert pid1 == pid2
  end

  test "release/1 terminates the Worker", %{key: key} do
    {:ok, pid} = Loader.load(key)
    :ok = Loader.release(key)
    refute Process.alive?(pid)
    refute Loader.loaded?(key)
  end

  test "release/1 returns :not_loaded when not loaded", %{key: key} do
    assert {:error, :not_loaded} = Loader.release(key)
  end

  test "reload/1 starts a fresh Worker", %{key: key} do
    {:ok, pid1} = Loader.load(key)
    {:ok, pid2} = Loader.reload(key)
    refute pid1 == pid2
    assert Process.alive?(pid2)
  end

  test "pid_for/1 returns :not_loaded when not loaded", %{key: key} do
    assert {:error, :not_loaded} = Loader.pid_for(key)
  end

  test "load/1 returns error when key is not registered" do
    unregistered = :crypto.strong_rand_bytes(16)
    assert {:error, :not_found} = Loader.load(unregistered)
  end
end
