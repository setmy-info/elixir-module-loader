defmodule SetmyInfo.ElixirModuleLoader.Integration.FunctionsTest do
  @moduledoc """
  Integration tests for runtime function discovery: listing exports and
  calling dynamically discovered functions without knowing them in advance.
  The caller owns the dispatch — the library provides only the module.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader
  alias SetmyInfo.ElixirModuleLoader.Registry

  describe "functions/1 — runtime export discovery" do
    test "lists all public functions of a compiled module" do
      {:ok, key, _module} =
        ElixirModuleLoader.compile("""
        defmodule SetmyInfo.ElixirModuleLoader.Integration.FnDiscover do
          def alpha(x), do: x
          def beta(x, y), do: {x, y}
          def gamma, do: :gamma
        end
        """)

      on_exit(fn ->
        if ElixirModuleLoader.loaded?(key), do: ElixirModuleLoader.release(key)
        Registry.unregister(key)
      end)

      {:ok, exports} = ElixirModuleLoader.functions(key)
      assert {:alpha, 1} in exports
      assert {:beta, 2} in exports
      assert {:gamma, 0} in exports
    end

    test "functions/1 loads the module if not yet in working set" do
      {:ok, key, _module} =
        ElixirModuleLoader.compile("""
        defmodule SetmyInfo.ElixirModuleLoader.Integration.FnAutoLoad do
          def hello, do: :world
        end
        """)

      ElixirModuleLoader.release(key)
      refute ElixirModuleLoader.loaded?(key)

      {:ok, exports} = ElixirModuleLoader.functions(key)
      assert {:hello, 0} in exports
      assert ElixirModuleLoader.loaded?(key)

      on_exit(fn ->
        if ElixirModuleLoader.loaded?(key), do: ElixirModuleLoader.release(key)
        Registry.unregister(key)
      end)
    end

    test "accepts UUID string for key" do
      {:ok, key, _module} =
        ElixirModuleLoader.compile("""
        defmodule SetmyInfo.ElixirModuleLoader.Integration.FnUUID do
          def ping, do: :pong
        end
        """)

      uuid = ElixirModuleLoader.key_to_uuid(key)

      on_exit(fn ->
        if ElixirModuleLoader.loaded?(key), do: ElixirModuleLoader.release(key)
        Registry.unregister(key)
      end)

      {:ok, exports} = ElixirModuleLoader.functions(uuid)
      assert {:ping, 0} in exports
    end
  end

  describe "calling dynamically discovered functions" do
    test "discover all arity-1 functions and call them" do
      {:ok, key, _module} =
        ElixirModuleLoader.compile("""
        defmodule SetmyInfo.ElixirModuleLoader.Integration.FnDynamic do
          def shout(s), do: String.upcase(s)
          def whisper(s), do: String.downcase(s)
        end
        """)

      on_exit(fn ->
        if ElixirModuleLoader.loaded?(key), do: ElixirModuleLoader.release(key)
        Registry.unregister(key)
      end)

      {:ok, exports} = ElixirModuleLoader.functions(key)
      {:ok, module} = ElixirModuleLoader.load(key)

      results =
        for {name, 1} <- exports, into: %{} do
          {name, apply(module, name, ["Hey"])}
        end

      assert results == %{shout: "HEY", whisper: "hey"}
    end

    test "caller requests function by name using apply/3" do
      {:ok, key, module} =
        ElixirModuleLoader.compile("""
        defmodule SetmyInfo.ElixirModuleLoader.Integration.FnByName do
          def add(a, b), do: a + b
          def multiply(a, b), do: a * b
        end
        """)

      on_exit(fn ->
        if ElixirModuleLoader.loaded?(key), do: ElixirModuleLoader.release(key)
        Registry.unregister(key)
      end)

      function_name = :add
      assert 7 == apply(module, function_name, [3, 4])

      function_name = :multiply
      assert 12 == apply(module, function_name, [3, 4])
    end

    test "caller verifies a function exists before calling it" do
      {:ok, key, module} =
        ElixirModuleLoader.compile("""
        defmodule SetmyInfo.ElixirModuleLoader.Integration.FnCheck do
          def transform(x), do: x * 2
        end
        """)

      on_exit(fn ->
        if ElixirModuleLoader.loaded?(key), do: ElixirModuleLoader.release(key)
        Registry.unregister(key)
      end)

      {:ok, exports} = ElixirModuleLoader.functions(key)

      if {:transform, 1} in exports do
        assert 10 == apply(module, :transform, [5])
      else
        flunk("expected :transform/1 to be exported")
      end

      refute {:nonexistent, 1} in exports
    end
  end

  describe "function discovery via load_by_name/1" do
    test "discovers functions of a statically compiled module" do
      {:ok, key, _module} =
        ElixirModuleLoader.load_by_name(SetmyInfo.ElixirModuleLoader.Modules.Math)

      on_exit(fn ->
        if ElixirModuleLoader.loaded?(key), do: ElixirModuleLoader.release(key)
        Registry.unregister(key)
      end)

      {:ok, exports} = ElixirModuleLoader.functions(key)
      assert {:add, 2} in exports
      assert {:multiply, 2} in exports
      assert {:divide, 2} in exports
    end
  end
end
