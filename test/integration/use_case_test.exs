defmodule SetmyInfo.ElixirModuleLoader.Integration.UseCaseTest do
  @moduledoc """
  Integration examples: the library compiles and loads modules, the caller
  is fully responsible for discovering and invoking functions. No helpers,
  no dispatch layer — direct `apply/3` or `module.fun/arity` calls.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader
  alias SetmyInfo.ElixirModuleLoader.Registry

  # ── UC: Compile on demand from file ─────────────────────────────────────────

  describe "compile-on-demand from a .ex file" do
    setup do
      dir = Path.join(System.tmp_dir!(), "eml_use_case_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "prefer .beam when present, otherwise compile the .ex source", %{dir: dir} do
      source_path = Path.join(dir, "plugin.ex")
      beam_path = Path.join(dir, "plugin.beam")

      File.write!(source_path, """
      defmodule UC1Plugin do
        def double(x), do: x * 2
      end
      """)

      path = if File.exists?(beam_path), do: beam_path, else: source_path
      {:ok, key, module} = ElixirModuleLoader.compile_file(path)

      assert 42 == module.double(21)

      ElixirModuleLoader.release(key)
      Registry.unregister(key)
    end
  end

  # ── UC: Dynamic access — functions not known in advance ─────────────────────

  describe "dynamic access to modules with unknown functions" do
    test "discover exports at runtime and call them as data" do
      {:ok, key, _module} =
        ElixirModuleLoader.compile("""
        defmodule UC2Mystery do
          def shout(s), do: String.upcase(s)
          def whisper(s), do: String.downcase(s)
        end
        """)

      on_exit(fn ->
        if ElixirModuleLoader.loaded?(key), do: ElixirModuleLoader.release(key)
        Registry.unregister(key)
      end)

      {:ok, exports} = ElixirModuleLoader.functions(key)
      assert {:shout, 1} in exports
      assert {:whisper, 1} in exports

      {:ok, module} = ElixirModuleLoader.load(key)

      results =
        for {f, 1} <- exports, into: %{} do
          {f, apply(module, f, ["Hey"])}
        end

      assert results == %{shout: "HEY", whisper: "hey"}

      ElixirModuleLoader.release(key)
    end
  end

  # ── UC: Manual composition across separately loaded modules ─────────────────

  describe "caller composes functions across dynamically loaded modules" do
    setup do
      specs =
        for {suffix, body} <- [
              {"Trimmer", "def trim(s), do: String.trim(s)"},
              {"Cleaner", ~S|def remove_bad(s), do: String.replace(s, "Bad ", "")|},
              {"Upcaser", "def upcase(s), do: String.upcase(s)"}
            ] do
          {:ok, key, _module} =
            ElixirModuleLoader.compile("""
            defmodule UC3#{suffix} do
              #{body}
            end
            """)

          key
        end

      [trim_key, clean_key, up_key] = specs

      on_exit(fn ->
        for key <- specs do
          if ElixirModuleLoader.loaded?(key), do: ElixirModuleLoader.release(key)
          Registry.unregister(key)
        end
      end)

      {:ok, trim_key: trim_key, clean_key: clean_key, up_key: up_key}
    end

    test "caller manually chains f(g(x)) across two loaded modules", ctx do
      {:ok, trim_mod} = ElixirModuleLoader.load(ctx.trim_key)
      {:ok, up_mod} = ElixirModuleLoader.load(ctx.up_key)

      result = up_mod.upcase(trim_mod.trim("   hello   "))
      assert "HELLO" == result
    end

    test "caller pipes value through three loaded modules", ctx do
      {:ok, trim_mod} = ElixirModuleLoader.load(ctx.trim_key)
      {:ok, clean_mod} = ElixirModuleLoader.load(ctx.clean_key)
      {:ok, up_mod} = ElixirModuleLoader.load(ctx.up_key)

      result =
        "   Hello Bad World !!!   "
        |> then(&trim_mod.trim/1)
        |> then(&clean_mod.remove_bad/1)
        |> then(&up_mod.upcase/1)

      assert "HELLO WORLD !!!" == result
    end

    test "map-shaped data flows through a dynamically compiled transformation" do
      {:ok, key, module} =
        ElixirModuleLoader.compile("""
        defmodule UC3MapTransform do
          def full_name(%{first: f, last: l} = person),
            do: Map.put(person, :full_name, f <> " " <> l)
        end
        """)

      on_exit(fn ->
        if ElixirModuleLoader.loaded?(key), do: ElixirModuleLoader.release(key)
        Registry.unregister(key)
      end)

      assert %{full_name: "Ada Lovelace"} =
               module.full_name(%{first: "Ada", last: "Lovelace"})
    end
  end

  # ── UC: load_by_name for statically compiled modules ─────────────────────────

  describe "load_by_name for known modules" do
    test "load the built-in Math module and use it directly" do
      {:ok, key, module} =
        ElixirModuleLoader.load_by_name(SetmyInfo.ElixirModuleLoader.Modules.Math)

      on_exit(fn ->
        if ElixirModuleLoader.loaded?(key), do: ElixirModuleLoader.release(key)
        Registry.unregister(key)
      end)

      assert 5 == module.add(2, 3)
      assert 6 == module.multiply(2, 3)
      assert {:error, :division_by_zero} == module.divide(1, 0)
    end
  end
end
