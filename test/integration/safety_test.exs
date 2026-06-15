defmodule SetmyInfo.ElixirModuleLoader.Integration.SafetyTest do
  @moduledoc """
  Process-safety regression tests for the library's own machinery:

    * concurrent compilation (global compiler flag is serialised)
    * release racing a concurrent load leaves consistent state
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader, as: EML
  alias SetmyInfo.ElixirModuleLoader.Registry

  describe "concurrent compilation" do
    test "many processes compiling distinct modules do not race on the global flag" do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            EML.compile("""
            defmodule SetmyInfo.ElixirModuleLoader.Safety.Mod#{i} do
              def value, do: #{i}
            end
            """)
          end)
        end

      results = Task.await_many(tasks, 30_000)
      assert Enum.all?(results, &match?({:ok, _, _}, &1))

      # Use the module atom returned by compile (results preserve task order,
      # so index 6 is i == 7) rather than a literal the compiler can't see —
      # these modules are defined at runtime.
      {:ok, _key, mod7} = Enum.at(results, 6)
      assert 7 == mod7.value()

      for {:ok, key, _} <- results do
        if EML.loaded?(key), do: EML.release(key)
        Registry.unregister(key)
      end
    end
  end

  describe "release racing concurrent loads" do
    test "load/release from many processes leaves consistent state" do
      {:ok, key, _} =
        EML.compile("""
        defmodule SetmyInfo.ElixirModuleLoader.Safety.RacePlugin do
          def ping, do: :pong
        end
        """)

      on_exit(fn ->
        if EML.loaded?(key), do: EML.release(key)
        Registry.unregister(key)
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
      assert Enum.all?(results, &(&1 in [:ok, {:error, :not_loaded}]))

      assert {:ok, module} = EML.load(key)
      assert :pong == module.ping()
    end
  end
end
