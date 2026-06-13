defmodule SetmyInfo.ElixirModuleLoader.Integration.SafetyTest do
  @moduledoc """
  Process-safety regression tests for the library's own machinery:

    * concurrent compilation (global compiler flag is serialised)
    * release racing a concurrent load leaves consistent state
    * register_many/1 rejects malformed specs

  Fault handling of *calls* is deliberately out of scope: the library does
  not dispatch — the user calls loaded modules directly and owns the error
  handling, like any other Elixir call.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader, as: EML
  alias SetmyInfo.ElixirModuleLoader.{Compiler, Registry}

  describe "concurrent compilation" do
    test "many processes compiling distinct modules do not race on the global flag" do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            source = """
            defmodule SetmyInfo.ElixirModuleLoader.Safety.Mod#{i} do
              def value, do: #{i}
            end
            """

            Compiler.from_source(source)
          end)
        end

      results = Task.await_many(tasks, 30_000)
      assert Enum.all?(results, &match?({:ok, _}, &1))

      # Every module is actually loaded and callable.
      assert 7 == SetmyInfo.ElixirModuleLoader.Safety.Mod7.value()
    end
  end

  describe "release racing concurrent loads" do
    test "load/release from many processes leaves consistent state" do
      key = :crypto.strong_rand_bytes(16)

      {:ok, _} =
        EML.register_source(key, """
        defmodule SetmyInfo.ElixirModuleLoader.Safety.RacePlugin do
          def ping, do: :pong
        end
        """)

      on_exit(fn ->
        if EML.loaded?(key), do: EML.release(key)
        EML.unregister(key)
      end)

      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            case EML.load(key) do
              {:ok, module} ->
                _ = module.ping()
                EML.release(key)

              {:error, _} = e ->
                e
            end
          end)
        end

      results = Task.await_many(tasks, 10_000)
      # Every task either completed its cycle or saw an already-released key.
      assert Enum.all?(results, &(&1 in [:ok, {:error, :not_loaded}]))

      # The key is loadable again afterwards — state is consistent.
      assert {:ok, module} = EML.load(key)
      assert :pong == module.ping()
    end
  end

  describe "register_many/1 validation" do
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
