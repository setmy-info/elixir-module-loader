defmodule SetmyInfo.ElixirModuleLoader.CompilerTest do
  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader.Compiler

  @module_source """
  defmodule SetmyInfo.ElixirModuleLoader.Test.TempAdder do
    def add(a, b), do: a + b
  end
  """

  setup do
    :code.purge(SetmyInfo.ElixirModuleLoader.Test.TempAdder)
    :code.delete(SetmyInfo.ElixirModuleLoader.Test.TempAdder)
    :code.purge(SetmyInfo.ElixirModuleLoader.Test.TempAdder)

    on_exit(fn ->
      :code.purge(SetmyInfo.ElixirModuleLoader.Test.TempAdder)
      :code.delete(SetmyInfo.ElixirModuleLoader.Test.TempAdder)
      :code.purge(SetmyInfo.ElixirModuleLoader.Test.TempAdder)
    end)

    :ok
  end

  describe "from_source/1" do
    test "compiles source string and loads modules into VM" do
      assert {:ok, modules} = Compiler.from_source(@module_source)
      assert length(modules) == 1
      assert {SetmyInfo.ElixirModuleLoader.Test.TempAdder, _binary} = hd(modules)
      assert 10 == apply(SetmyInfo.ElixirModuleLoader.Test.TempAdder, :add, [3, 7])
    end

    @tag capture_log: true
    test "returns error tuple for invalid Elixir source" do
      assert {:error, _} = Compiler.from_source("this is not valid elixir {{{")
    end
  end

  describe "from_file/1" do
    test "compiles a .ex file and loads modules into VM" do
      fixture = Path.expand("../../fixtures/sample_module.ex", __DIR__)
      assert {:ok, modules} = Compiler.from_file(fixture)
      assert length(modules) >= 1
    end
  end

  describe "from_beam_binary/2" do
    test "loads a module from an in-memory BEAM binary" do
      {:ok, [{module, binary}]} = Compiler.from_source(@module_source)
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)

      assert :ok == Compiler.from_beam_binary(module, binary)
      assert 10 == apply(module, :add, [3, 7])
    end

    @tag capture_log: true
    test "returns error for invalid binary" do
      assert {:error, _} = Compiler.from_beam_binary(NonExistentMod, <<"not a beam">>)
    end
  end

  describe "from_beam_file/1" do
    test "loads a module from a .beam file on disk" do
      {:ok, [{module, binary}]} = Compiler.from_source(@module_source)
      beam_path = Path.join(System.tmp_dir!(), "#{module}.beam")
      File.write!(beam_path, binary)
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)

      on_exit(fn -> File.rm(beam_path) end)

      assert {:ok, ^module} = Compiler.from_beam_file(beam_path)
      assert 10 == apply(module, :add, [3, 7])
    end

    @tag capture_log: true
    test "returns error for non-existent beam file" do
      assert {:error, _} = Compiler.from_beam_file("/tmp/does_not_exist_ever.beam")
    end
  end

  describe "purge/1 and delete/1" do
    test "soft-purge returns a boolean" do
      Compiler.from_source(@module_source)
      assert is_boolean(Compiler.purge(SetmyInfo.ElixirModuleLoader.Test.TempAdder))
    end

    test "delete removes module from code server" do
      Compiler.from_source(@module_source)
      assert true == Compiler.delete(SetmyInfo.ElixirModuleLoader.Test.TempAdder)
    end
  end

  describe "module_md5/1" do
    test "returns hex string for loaded module" do
      Compiler.from_source(@module_source)
      md5 = Compiler.module_md5(SetmyInfo.ElixirModuleLoader.Test.TempAdder)
      assert is_binary(md5)
      assert String.length(md5) == 32
    end

    test "returns nil for non-existent module" do
      assert nil == Compiler.module_md5(DoesNotExistEver)
    end
  end
end
