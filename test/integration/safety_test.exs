defmodule SetmyInfo.ElixirModuleLoader.Integration.SafetyTest do
  @moduledoc """
  Thread/process-safety regression tests for the gaps identified in review:

    * concurrent compilation (global compiler flag is serialised)
    * Loader self-heals its ETS tracking when a Worker dies
    * a crashing plugin does not take down the caller
    * release racing an in-flight execute leaves consistent state
    * register_many/1 rejects malformed specs
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader.{Compiler, Loader, Registry, Worker}

  # Poll `fun` until it returns true or the timeout elapses.
  defp wait_until(fun, timeout \\ 2_000, step \\ 20)
  defp wait_until(_fun, timeout, _step) when timeout <= 0, do: false

  defp wait_until(fun, timeout, step) do
    if fun.() do
      true
    else
      Process.sleep(step)
      wait_until(fun, timeout - step, step)
    end
  end

  describe "concurrent compilation (fix 1)" do
    test "many processes compiling distinct modules do not race on the global flag" do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            source = """
            defmodule SetmyInfo.ElixirModuleLoader.Safety.Mod#{i} do
              @behaviour SetmyInfo.ElixirModuleLoader.Behaviour
              def name, do: :safety_mod
              def execute(:value, []), do: {:ok, #{i}}
              def execute(f, _), do: {:error, {:undefined_function, f}}
            end
            """

            Compiler.from_source(source)
          end)
        end

      results = Task.await_many(tasks, 30_000)
      assert Enum.all?(results, &match?({:ok, _}, &1))

      # Every module is actually loaded and callable.
      assert 7 ==
               apply(SetmyInfo.ElixirModuleLoader.Safety.Mod7, :execute, [:value, []]) |> elem(1)
    end
  end

  describe "Loader self-heals on Worker death (fixes 2 & 3)" do
    setup do
      key = :crypto.strong_rand_bytes(16)
      Registry.register(key, SetmyInfo.ElixirModuleLoader.Modules.Math)
      on_exit(fn -> Registry.unregister(key) end)
      {:ok, key: key}
    end

    test "killing a Worker clears stale ETS tracking", %{key: key} do
      {:ok, pid} = Loader.load(key)
      assert Loader.loaded?(key)

      Process.exit(pid, :kill)

      assert wait_until(fn -> not Loader.loaded?(key) end),
             "Loader should drop tracking after the Worker dies"

      refute Loader.loaded?(key)
      assert {:error, :not_loaded} == Loader.pid_for(key)
      # restart: :temporary — the dead Worker is NOT silently respawned.
      refute Process.alive?(pid)
    end
  end

  describe "plugin fault isolation (fix 4)" do
    test "a plugin that raises returns an error tuple and keeps the Worker alive" do
      key = :crypto.strong_rand_bytes(16)

      source = """
      defmodule SetmyInfo.ElixirModuleLoader.Safety.CrashPlugin do
        @behaviour SetmyInfo.ElixirModuleLoader.Behaviour
        def name, do: :crash_plugin
        def execute(:boom, []), do: raise "boom"
        def execute(f, _), do: {:error, {:undefined_function, f}}
      end
      """

      {:ok, _} = Compiler.from_source(source)
      Registry.register(key, SetmyInfo.ElixirModuleLoader.Safety.CrashPlugin)
      {:ok, pid} = Loader.load(key)

      on_exit(fn ->
        if Loader.loaded?(key), do: Loader.release(key)
        Registry.unregister(key)
      end)

      assert {:error, {:plugin_error, _}} = Worker.execute(key, :boom, [])
      assert Process.alive?(pid), "Worker must survive a crashing plugin call"
      # And it still works afterwards.
      assert {:error, {:undefined_function, :nope}} = Worker.execute(key, :nope, [])
    end
  end

  describe "execute timeout isolation" do
    test "a plugin exceeding the call timeout returns {:error, :timeout} without crashing the caller" do
      key = :crypto.strong_rand_bytes(16)

      source = """
      defmodule SetmyInfo.ElixirModuleLoader.Safety.TimeoutPlugin do
        @behaviour SetmyInfo.ElixirModuleLoader.Behaviour
        def name, do: :timeout_plugin
        def execute(:hang, []), do: (Process.sleep(500); {:ok, :late})
        def execute(f, _), do: {:error, {:undefined_function, f}}
      end
      """

      {:ok, _} = Compiler.from_source(source)
      Registry.register(key, SetmyInfo.ElixirModuleLoader.Safety.TimeoutPlugin)
      {:ok, pid} = Loader.load(key)

      on_exit(fn ->
        if Loader.loaded?(key), do: Loader.release(key)
        Registry.unregister(key)
      end)

      assert {:error, :timeout} = Worker.execute(key, :hang, [], 100)
      # The caller (this test process) survived; the Worker is still alive
      # and usable once the slow call finishes.
      assert Process.alive?(pid)
      Process.sleep(500)
      assert {:error, {:undefined_function, :ping}} = Worker.execute(key, :ping, [])
    end

    test "a Worker killed mid-call returns {:error, :not_loaded} without crashing the caller" do
      key = :crypto.strong_rand_bytes(16)

      source = """
      defmodule SetmyInfo.ElixirModuleLoader.Safety.KilledPlugin do
        @behaviour SetmyInfo.ElixirModuleLoader.Behaviour
        def name, do: :killed_plugin
        def execute(:slow, []), do: (Process.sleep(1_000); {:ok, :done})
        def execute(f, _), do: {:error, {:undefined_function, f}}
      end
      """

      {:ok, _} = Compiler.from_source(source)
      Registry.register(key, SetmyInfo.ElixirModuleLoader.Safety.KilledPlugin)
      {:ok, pid} = Loader.load(key)

      on_exit(fn ->
        if Loader.loaded?(key), do: Loader.release(key)
        Registry.unregister(key)
      end)

      exec = Task.async(fn -> Worker.execute(key, :slow, []) end)
      Process.sleep(50)
      Process.exit(pid, :kill)

      assert {:error, :not_loaded} = Task.await(exec, 5_000)
    end
  end

  describe "release racing in-flight execute (fix 7d)" do
    test "release during a slow execute leaves consistent state" do
      key = :crypto.strong_rand_bytes(16)

      source = """
      defmodule SetmyInfo.ElixirModuleLoader.Safety.SlowPlugin do
        @behaviour SetmyInfo.ElixirModuleLoader.Behaviour
        def name, do: :slow_plugin
        def execute(:slow, []), do: (Process.sleep(200); {:ok, :done})
        def execute(f, _), do: {:error, {:undefined_function, f}}
      end
      """

      {:ok, _} = Compiler.from_source(source)
      Registry.register(key, SetmyInfo.ElixirModuleLoader.Safety.SlowPlugin)
      {:ok, _pid} = Loader.load(key)

      on_exit(fn ->
        if Loader.loaded?(key), do: Loader.release(key)
        Registry.unregister(key)
      end)

      exec = Task.async(fn -> Worker.execute(key, :slow, []) end)
      Process.sleep(50)
      rel = Task.async(fn -> Loader.release(key) end)

      exec_result = Task.await(exec, 5_000)
      assert :ok == Task.await(rel, 5_000)

      # The execute either completed before termination or was reported as gone.
      assert exec_result in [{:ok, :done}, {:error, :not_loaded}]
      refute Loader.loaded?(key)
    end
  end

  describe "register_many/1 validation (fix 5)" do
    test "rejects malformed specs and inserts nothing" do
      good = :crypto.strong_rand_bytes(16)
      before = Registry.count()

      assert {:error, :invalid_spec} =
               Registry.register_many([{good, SomeModule}, {"too-short", SomeModule}])

      assert Registry.count() == before
      refute Registry.registered?(good)
    end

    test "accepts a well-formed batch" do
      keys = for _ <- 1..3, do: :crypto.strong_rand_bytes(16)
      specs = Enum.map(keys, &{&1, SomeModule})

      on_exit(fn -> Enum.each(keys, &Registry.unregister/1) end)

      assert :ok == Registry.register_many(specs)
      assert Enum.all?(keys, &Registry.registered?/1)
    end
  end
end
