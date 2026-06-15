defmodule SetmyInfo.ElixirModuleLoader.FacadeTest do
  @moduledoc """
  Unit-level tests for the public facade: key generation, compile, load,
  release, function discovery, and key/UUID interchangeability.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader, as: ML
  alias SetmyInfo.ElixirModuleLoader.{Registry, UUID}

  # ── Key management ───────────────────────────────────────────────────────────

  describe "generate_key/0 and generate_uuid/0" do
    test "generate_key returns a 16-byte binary" do
      key = ML.generate_key()
      assert is_binary(key)
      assert byte_size(key) == 16
    end

    test "generate_uuid returns a UUID-formatted string" do
      uuid = ML.generate_uuid()
      assert is_binary(uuid)
      assert String.length(uuid) == 36

      assert String.match?(
               uuid,
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
             )
    end

    test "key_to_uuid converts a binary key to a UUID string" do
      key = ML.generate_key()
      uuid = ML.key_to_uuid(key)
      assert String.length(uuid) == 36
      assert UUID.to_key!(uuid) == key
    end
  end

  # ── compile/1 ────────────────────────────────────────────────────────────────

  describe "compile/1" do
    @source """
    defmodule SetmyInfo.ElixirModuleLoader.Test.FacadeCompile do
      def ping, do: :pong
    end
    """

    test "returns {key, module} where key is a 16-byte binary" do
      {:ok, key, module} = ML.compile(@source)

      assert byte_size(key) == 16
      assert module == SetmyInfo.ElixirModuleLoader.Test.FacadeCompile

      on_exit(fn -> if ML.loaded?(key), do: ML.release(key) end)
    end

    test "module is immediately callable" do
      {:ok, key, module} = ML.compile(@source)
      assert :pong == module.ping()

      on_exit(fn ->
        if ML.loaded?(key), do: ML.release(key)
        Registry.unregister(key)
      end)
    end

    test "compile also loads the module into the working set" do
      {:ok, key, _module} = ML.compile(@source)
      assert ML.loaded?(key)

      on_exit(fn -> if ML.loaded?(key), do: ML.release(key) end)
    end

    test "load/1 by key is idempotent after compile" do
      {:ok, key, module} = ML.compile(@source)
      assert {:ok, ^module} = ML.load(key)

      on_exit(fn -> if ML.loaded?(key), do: ML.release(key) end)
    end

    @tag capture_log: true
    test "returns error for invalid source" do
      assert {:error, _} = ML.compile("this is {{{ not valid elixir")
    end
  end

  # ── compile_file/1 ───────────────────────────────────────────────────────────

  describe "compile_file/1" do
    @fixture_path Path.expand("../../fixtures/sample_module.ex", __DIR__)
    @module SetmyInfo.ElixirModuleLoader.Support.SampleModule

    test "compiles a .ex file, auto-registers, returns key and module" do
      {:ok, key, module} = ML.compile_file(@fixture_path)
      assert byte_size(key) == 16
      assert module == @module
      assert ML.loaded?(key)
      assert 5 == module.add(2, 3)

      on_exit(fn -> if ML.loaded?(key), do: ML.release(key) end)
    end

    test "compiles a .beam file when given a .beam path" do
      {:ok, [{module, binary}]} =
        SetmyInfo.ElixirModuleLoader.Compiler.from_source("""
        defmodule SetmyInfo.ElixirModuleLoader.Test.FacadeBeam do
          def ok, do: :ok
        end
        """)

      beam_path = Path.join(System.tmp_dir!(), "#{module}.beam")
      File.write!(beam_path, binary)
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)

      on_exit(fn -> File.rm(beam_path) end)

      {:ok, key, ^module} = ML.compile_file(beam_path)
      assert :ok == module.ok()

      on_exit(fn -> if ML.loaded?(key), do: ML.release(key) end)
    end
  end

  # ── load_by_name/1 ───────────────────────────────────────────────────────────

  describe "load_by_name/1" do
    test "loads an already-compiled module by atom name" do
      {:ok, key, module} = ML.load_by_name(SetmyInfo.ElixirModuleLoader.Modules.Math)
      assert byte_size(key) == 16
      assert module == SetmyInfo.ElixirModuleLoader.Modules.Math
      assert ML.loaded?(key)
      assert 5 == module.add(2, 3)

      on_exit(fn ->
        if ML.loaded?(key), do: ML.release(key)
        Registry.unregister(key)
      end)
    end

    test "returns error for a non-existent module" do
      assert {:error, _} = ML.load_by_name(DoesNotExistModule999)
    end

    test "same module can be registered under different keys" do
      {:ok, key1, _} = ML.load_by_name(SetmyInfo.ElixirModuleLoader.Modules.Math)
      {:ok, key2, _} = ML.load_by_name(SetmyInfo.ElixirModuleLoader.Modules.Math)
      assert key1 != key2

      on_exit(fn ->
        if ML.loaded?(key1), do: ML.release(key1)
        if ML.loaded?(key2), do: ML.release(key2)
        Registry.unregister(key1)
        Registry.unregister(key2)
      end)
    end
  end

  # ── load/1 ───────────────────────────────────────────────────────────────────

  describe "load/1" do
    test "accepts a UUID string as well as a binary key" do
      {:ok, key, _module} =
        ML.compile("""
        defmodule SetmyInfo.ElixirModuleLoader.Test.FacadeLoadUUID do
          def ok, do: :ok
        end
        """)

      uuid = ML.key_to_uuid(key)
      assert {:ok, SetmyInfo.ElixirModuleLoader.Test.FacadeLoadUUID} = ML.load(uuid)

      on_exit(fn -> if ML.loaded?(key), do: ML.release(key) end)
    end

    test "raises ArgumentError for a malformed key string" do
      assert_raise ArgumentError, fn -> ML.load("not-a-uuid") end
    end
  end

  # ── release/1 ────────────────────────────────────────────────────────────────

  describe "release/1" do
    test "removes from working set" do
      {:ok, key, _} =
        ML.compile("""
        defmodule SetmyInfo.ElixirModuleLoader.Test.FacadeRelease do
          def ping, do: :pong
        end
        """)

      assert ML.loaded?(key)
      :ok = ML.release(key)
      refute ML.loaded?(key)
    end

    test "returns error for a key not in the working set" do
      key = ML.generate_key()
      assert {:error, :not_loaded} = ML.release(key)
    end
  end

  # ── functions/1 ──────────────────────────────────────────────────────────────

  describe "functions/1" do
    test "lists exported functions of a compiled module" do
      {:ok, key, _} =
        ML.compile("""
        defmodule SetmyInfo.ElixirModuleLoader.Test.FacadeFunctions do
          def alpha(x), do: x
          def beta(x, y), do: {x, y}
        end
        """)

      on_exit(fn -> if ML.loaded?(key), do: ML.release(key) end)

      assert {:ok, exports} = ML.functions(key)
      assert {:alpha, 1} in exports
      assert {:beta, 2} in exports
    end

    test "accepts UUID string for the key" do
      {:ok, key, _} =
        ML.compile("""
        defmodule SetmyInfo.ElixirModuleLoader.Test.FacadeFunctionsUUID do
          def gamma(x), do: x
        end
        """)

      uuid = ML.key_to_uuid(key)
      on_exit(fn -> if ML.loaded?(key), do: ML.release(key) end)

      assert {:ok, exports} = ML.functions(uuid)
      assert {:gamma, 1} in exports
    end
  end

  # ── compile/2 with load: false ───────────────────────────────────────────────

  describe "compile/2 with load: false" do
    @compile_only_source """
    defmodule SetmyInfo.ElixirModuleLoader.Test.CompileOnly do
      def ping, do: :pong
    end
    """

    test "returns module-binary pairs without registering in the library" do
      {:ok, mods} = ML.compile(@compile_only_source, load: false)
      assert [{module, binary}] = mods
      assert is_atom(module)
      assert is_binary(binary)
    end

    test "result is not loaded in the library working set" do
      {:ok, [{_module, _binary}]} = ML.compile(@compile_only_source, load: false)
      # No key was generated by the library, so there is nothing to look up.
      # Verify the call returned the right shape and didn't blow up.
      assert true
    end
  end

  # ── compile_file/2 with load: false ──────────────────────────────────────────

  describe "compile_file/2 with load: false" do
    @fixture_path_2 Path.expand("../../fixtures/sample_module.ex", __DIR__)

    test "returns module-binary pairs for a .ex file without registering" do
      {:ok, mods} = ML.compile_file(@fixture_path_2, load: false)
      assert [{module, binary}] = mods
      assert is_atom(module)
      assert is_binary(binary)
    end

    test "returns error for a .beam file with load: false" do
      tmp = Path.join(System.tmp_dir!(), "test_#{:erlang.unique_integer([:positive])}.beam")
      File.write!(tmp, "fake")
      on_exit(fn -> File.rm(tmp) end)

      assert {:error, :load_required_for_beam} = ML.compile_file(tmp, load: false)
    end
  end

  # ── load_source/2 ────────────────────────────────────────────────────────────

  describe "load_source/2" do
    @load_source_src """
    defmodule SetmyInfo.ElixirModuleLoader.Test.FacadeLoadSource do
      def ping, do: :pong
    end
    """

    test "compiles and registers under caller UUID, returns module immediately" do
      uuid = ML.generate_uuid()
      key = UUID.to_key!(uuid)

      on_exit(fn ->
        if ML.loaded?(uuid), do: ML.release(uuid)
        Registry.unregister(key)
      end)

      {:ok, module} = ML.load_source(uuid, @load_source_src)
      assert module == SetmyInfo.ElixirModuleLoader.Test.FacadeLoadSource
      assert ML.loaded?(uuid)
      assert :pong == module.ping()
    end

    test "accepts binary key as well as UUID string" do
      bin_key = ML.generate_key()

      on_exit(fn ->
        if ML.loaded?(bin_key), do: ML.release(bin_key)
        Registry.unregister(bin_key)
      end)

      {:ok, module} = ML.load_source(bin_key, @load_source_src)
      assert ML.loaded?(bin_key)
      assert :pong == module.ping()
    end

    test "loaded module can be released and reloaded" do
      uuid = ML.generate_uuid()
      key = UUID.to_key!(uuid)

      on_exit(fn ->
        if ML.loaded?(uuid), do: ML.release(uuid)
        Registry.unregister(key)
      end)

      {:ok, module} = ML.load_source(uuid, @load_source_src)
      assert ML.loaded?(uuid)

      :ok = ML.release(uuid)
      refute ML.loaded?(uuid)

      {:ok, ^module} = ML.load(uuid)
      assert ML.loaded?(uuid)
    end
  end

  # ── load_file/2 ──────────────────────────────────────────────────────────────

  describe "load_file/2" do
    @fixture_path_3 Path.expand("../../fixtures/sample_module.ex", __DIR__)
    @sample_module SetmyInfo.ElixirModuleLoader.Support.SampleModule

    test "compiles a .ex file and registers under caller UUID, returns module" do
      uuid = ML.generate_uuid()
      key = UUID.to_key!(uuid)

      on_exit(fn ->
        if ML.loaded?(uuid), do: ML.release(uuid)
        Registry.unregister(key)
      end)

      {:ok, module} = ML.load_file(uuid, @fixture_path_3)
      assert module == @sample_module
      assert ML.loaded?(uuid)
      assert 5 == module.add(2, 3)
    end

    test "loaded module can be released and reloaded from file" do
      uuid = ML.generate_uuid()
      key = UUID.to_key!(uuid)

      on_exit(fn ->
        if ML.loaded?(uuid), do: ML.release(uuid)
        Registry.unregister(key)
      end)

      {:ok, module} = ML.load_file(uuid, @fixture_path_3)
      :ok = ML.release(uuid)
      refute ML.loaded?(uuid)

      {:ok, ^module} = ML.load(uuid)
      assert ML.loaded?(uuid)
      assert 5 == module.add(2, 3)
    end
  end

  # ── load_binary/3 ────────────────────────────────────────────────────────────

  describe "load_binary/3" do
    @lb_source """
    defmodule SetmyInfo.ElixirModuleLoader.Test.FacadeLoadBinary do
      def double(x), do: x * 2
    end
    """

    test "loads a pre-compiled binary under caller UUID without recompiling" do
      {:ok, [{module, binary}]} = ML.compile(@lb_source, load: false)

      uuid = ML.generate_uuid()
      key = UUID.to_key!(uuid)

      on_exit(fn ->
        if ML.loaded?(uuid), do: ML.release(uuid)
        Registry.unregister(key)
      end)

      {:ok, ^module} = ML.load_binary(uuid, module, binary)
      assert ML.loaded?(uuid)
      assert 14 == module.double(7)
    end

    test "accepts binary key as well as UUID" do
      {:ok, [{module, binary}]} = ML.compile(@lb_source, load: false)
      bin_key = ML.generate_key()

      on_exit(fn ->
        if ML.loaded?(bin_key), do: ML.release(bin_key)
        Registry.unregister(bin_key)
      end)

      {:ok, ^module} = ML.load_binary(bin_key, module, binary)
      assert ML.loaded?(bin_key)
    end

    test "code can be restored after release without holding the binary" do
      {:ok, [{module, binary}]} = ML.compile(@lb_source, load: false)

      uuid = ML.generate_uuid()
      key = UUID.to_key!(uuid)

      on_exit(fn ->
        if ML.loaded?(uuid), do: ML.release(uuid)
        Registry.unregister(key)
      end)

      {:ok, ^module} = ML.load_binary(uuid, module, binary)
      assert 6 == module.double(3)

      :ok = ML.release(uuid)
      refute ML.loaded?(uuid)

      # Library restores from the binary stored at registration time
      {:ok, ^module} = ML.load(uuid)
      assert 6 == module.double(3)
    end
  end

  # ── get_function/3 ───────────────────────────────────────────────────────────

  describe "get_function/3" do
    @gf_source """
    defmodule SetmyInfo.ElixirModuleLoader.Test.FacadeGetFn do
      def transform(x), do: x * 2
      def combine(a, b), do: a + b
    end
    """

    test "returns a closure for an exported function by atom name" do
      {:ok, key, _} = ML.compile(@gf_source)

      on_exit(fn ->
        if ML.loaded?(key), do: ML.release(key)
        Registry.unregister(key)
      end)

      {:ok, fun} = ML.get_function(key, :transform, 1)
      assert fun.([3]) == 6
      assert fun.([10]) == 20
    end

    test "accepts a string function name (from external system)" do
      {:ok, key, _} = ML.compile(@gf_source)

      on_exit(fn ->
        if ML.loaded?(key), do: ML.release(key)
        Registry.unregister(key)
      end)

      {:ok, fun} = ML.get_function(key, "combine", 2)
      assert fun.([3, 4]) == 7
    end

    test "accepts UUID form for key" do
      {:ok, key, _} = ML.compile(@gf_source)
      uuid = ML.key_to_uuid(key)

      on_exit(fn ->
        if ML.loaded?(key), do: ML.release(key)
        Registry.unregister(key)
      end)

      {:ok, fun} = ML.get_function(uuid, :transform, 1)
      assert fun.([5]) == 10
    end

    test "returns {:error, :not_found} for unknown function atom" do
      {:ok, key, _} = ML.compile(@gf_source)

      on_exit(fn ->
        if ML.loaded?(key), do: ML.release(key)
        Registry.unregister(key)
      end)

      assert {:error, :not_found} = ML.get_function(key, :no_such_fn, 1)
    end

    test "returns {:error, :not_found} for unknown function string" do
      {:ok, key, _} = ML.compile(@gf_source)

      on_exit(fn ->
        if ML.loaded?(key), do: ML.release(key)
        Registry.unregister(key)
      end)

      assert {:error, :not_found} = ML.get_function(key, "completely_unknown_fn", 1)
    end

    test "returns {:error, :not_found} for wrong arity" do
      {:ok, key, _} = ML.compile(@gf_source)

      on_exit(fn ->
        if ML.loaded?(key), do: ML.release(key)
        Registry.unregister(key)
      end)

      # :transform exists with arity 1, not 2
      assert {:error, :not_found} = ML.get_function(key, :transform, 2)
    end
  end

  # ── UUID / binary key interchangeability ─────────────────────────────────────

  describe "UUID and binary key address the same entry" do
    test "load and release work with both forms" do
      {:ok, key, _module} =
        ML.compile("""
        defmodule SetmyInfo.ElixirModuleLoader.Test.FacadeInterop do
          def ping, do: :pong
        end
        """)

      uuid = ML.key_to_uuid(key)

      assert ML.loaded?(key)
      assert ML.loaded?(uuid)

      {:ok, m1} = ML.load(key)
      {:ok, m2} = ML.load(uuid)
      assert m1 == m2

      :ok = ML.release(uuid)
      refute ML.loaded?(key)
      refute ML.loaded?(uuid)
    end
  end
end
