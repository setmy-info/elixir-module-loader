defmodule SetmyInfo.ElixirModuleLoader.Integration.FunctionsTest do
  @moduledoc """
  Integration tests for loadable *functions*: single functions as catalog
  entries, first-class captures, higher-order passing, compositions
  registered under their own keys, currying, and pure-function memoisation.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader
  alias SetmyInfo.ElixirModuleLoader.Fn

  describe "function targets" do
    test "a {m, f, a} registers under its own key; fun/1 captures it" do
      uuid = ElixirModuleLoader.generate_uuid()
      :ok = ElixirModuleLoader.register_function(uuid, {String, :upcase, 1})

      up = ElixirModuleLoader.fun(uuid)
      assert "HI" == up.("hi")
      assert ["A", "B"] == Enum.map(["a", "b"], up)

      assert {:ok, [upcase: 1]} = ElixirModuleLoader.functions(uuid)

      ElixirModuleLoader.unregister(uuid)
    end
  end

  describe "first-class captures of module functions" do
    test "fun/3 captures by name and arity, late-bound through the key" do
      uuid = ElixirModuleLoader.generate_uuid()
      :ok = ElixirModuleLoader.register(uuid, SetmyInfo.ElixirModuleLoader.Modules.Math)

      add = ElixirModuleLoader.fun(uuid, :add, 2)
      assert 5 == add.(2, 3)

      # Survives a release: the closure re-loads through the key.
      if ElixirModuleLoader.loaded?(uuid), do: ElixirModuleLoader.release(uuid)
      assert 7 == add.(3, 4)

      ElixirModuleLoader.release(uuid)
      ElixirModuleLoader.unregister(uuid)
    end
  end

  describe "higher-order functions across keys" do
    test "a loaded combinator receives a captured loaded function as argument" do
      mapper_uuid = ElixirModuleLoader.generate_uuid()
      f_uuid = ElixirModuleLoader.generate_uuid()

      {:ok, mapper} =
        ElixirModuleLoader.register_source(mapper_uuid, """
        defmodule HOFMapper do
          def map_with(fun, list), do: Enum.map(list, fun)
        end
        """)

      :ok = ElixirModuleLoader.register_function(f_uuid, {String, :upcase, 1})

      # fun/1 gives a plain closure — pass it to loaded code like any value.
      up = ElixirModuleLoader.fun(f_uuid)
      assert ["A", "B"] == mapper.map_with(up, ["a", "b"])

      ElixirModuleLoader.release(mapper_uuid)
      ElixirModuleLoader.unregister(mapper_uuid)
      ElixirModuleLoader.unregister(f_uuid)
    end
  end

  describe "compositions as catalog entries" do
    setup do
      trim = ElixirModuleLoader.generate_uuid()
      up = ElixirModuleLoader.generate_uuid()
      :ok = ElixirModuleLoader.register_function(trim, {String, :trim, 1})
      :ok = ElixirModuleLoader.register_function(up, {String, :upcase, 1})

      on_exit(fn ->
        for u <- [trim, up] do
          if ElixirModuleLoader.loaded?(u), do: ElixirModuleLoader.release(u)
          ElixirModuleLoader.unregister(u)
        end
      end)

      {:ok, trim: trim, up: up}
    end

    test "a pipe of refs registered under its own key is a new function", ctx do
      pipe_uuid = ElixirModuleLoader.generate_uuid()
      ast = {:pipe, [{:ref, ctx.trim}, {:ref, ctx.up}]}
      :ok = ElixirModuleLoader.register_composite(pipe_uuid, ast)

      f = ElixirModuleLoader.fun(pipe_uuid)
      assert "HELLO" == f.("  hello ")

      # Composites are catalog entries: discoverable and recursively usable.
      assert {:ok, [call: 1]} = ElixirModuleLoader.functions(pipe_uuid)

      outer_uuid = ElixirModuleLoader.generate_uuid()
      :ok = ElixirModuleLoader.register_composite(outer_uuid, {:pipe, [{:ref, pipe_uuid}]})
      assert "X" == ElixirModuleLoader.fun(outer_uuid).(" x ")

      ElixirModuleLoader.unregister(pipe_uuid)
      ElixirModuleLoader.unregister(outer_uuid)
    end

    test "pipelines short-circuit on the first {:error, _} stage result", ctx do
      failer = ElixirModuleLoader.generate_uuid()

      {:ok, _} =
        ElixirModuleLoader.register_source(failer, """
        defmodule PipeFailer do
          def fail(_), do: {:error, :stage_failed}
        end
        """)

      pipe_uuid = ElixirModuleLoader.generate_uuid()
      ast = {:pipe, [{:ref, ctx.trim}, {:ref, failer, :fail}, {:ref, ctx.up}]}
      :ok = ElixirModuleLoader.register_composite(pipe_uuid, ast)

      assert {:error, :stage_failed} == ElixirModuleLoader.fun(pipe_uuid).("  hello ")

      for u <- [pipe_uuid, failer] do
        if ElixirModuleLoader.loaded?(u), do: ElixirModuleLoader.release(u)
        ElixirModuleLoader.unregister(u)
      end
    end

    test "malformed composite ASTs are rejected" do
      uuid = ElixirModuleLoader.generate_uuid()

      assert {:error, :invalid_composite} =
               ElixirModuleLoader.register_composite(uuid, {:pipe, []})

      assert {:error, :invalid_composite} = ElixirModuleLoader.register_composite(uuid, :nonsense)
    end
  end

  describe "currying and partial application" do
    test "Fn.partial binds leading arguments" do
      uuid = ElixirModuleLoader.generate_uuid()
      :ok = ElixirModuleLoader.register(uuid, SetmyInfo.ElixirModuleLoader.Modules.Math)

      add5 = Fn.partial(uuid, :add, [5])
      assert 8 == add5.(3)
      assert [6, 7] == Enum.map([1, 2], add5)

      ElixirModuleLoader.release(uuid)
      ElixirModuleLoader.unregister(uuid)
    end

    test "a {:partial, ...} composite node is a registrable curried function" do
      uuid = ElixirModuleLoader.generate_uuid()
      math = ElixirModuleLoader.generate_uuid()
      :ok = ElixirModuleLoader.register(math, SetmyInfo.ElixirModuleLoader.Modules.Math)

      :ok = ElixirModuleLoader.register_composite(uuid, {:partial, math, :add, [100]})
      assert 103 == ElixirModuleLoader.fun(uuid).(3)

      for u <- [uuid, math] do
        if ElixirModuleLoader.loaded?(u), do: ElixirModuleLoader.release(u)
        ElixirModuleLoader.unregister(u)
      end
    end
  end

  describe "pure functions: memoisation" do
    test "pure results are memoised per {key, args}" do
      uuid = ElixirModuleLoader.generate_uuid()

      {:ok, _} =
        ElixirModuleLoader.compile("""
        defmodule PureCounter do
          def slow_double(x) do
            send(:pure_test_listener, {:computed, x})
            x * 2
          end
        end
        """)

      # The name unregisters itself when the test process exits.
      Process.register(self(), :pure_test_listener)

      :ok = ElixirModuleLoader.register_function(uuid, {PureCounter, :slow_double, 1}, pure: true)
      double = ElixirModuleLoader.fun(uuid)

      assert 42 == double.(21)
      assert_received {:computed, 21}

      # Same args — served from the memo cache.
      assert 42 == double.(21)
      refute_received {:computed, 21}

      # Different args compute again.
      assert 6 == double.(3)
      assert_received {:computed, 3}

      # Unregistering clears the cache.
      ElixirModuleLoader.unregister(uuid)
      :ok = ElixirModuleLoader.register_function(uuid, {PureCounter, :slow_double, 1}, pure: true)
      assert 42 == ElixirModuleLoader.fun(uuid).(21)
      assert_received {:computed, 21}

      ElixirModuleLoader.unregister(uuid)
    end
  end
end
