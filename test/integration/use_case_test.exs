defmodule SetmyInfo.ElixirModuleLoader.Integration.UseCaseTest do
  @moduledoc """
  Integration examples validating the use cases from PROMPT.md and
  requirements.md (see VALIDATION.md for the full validation results):

  * compile-on-demand for UUID-identified `.ex` source files (user logic)
  * direct dynamic calls on loaded modules — no interface, names as data
  * function composition across separately loaded modules — `result = f(g(data))`
  * currying / partial application over loaded module functions
  * map-shaped data flowing through dynamically loaded transformations

  All assertions run against the live OTP supervision tree — no mocks.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader

  # ── UC: UUID-identified source file, compiled on demand ─────────────────────
  #
  # PROMPT.md: "If compiled file does not exist, need to check is source code
  # existing, if exists need to compile and load it into memory. That part is
  # library user software logic."

  describe "compile-on-demand for UUID-identified files" do
    setup do
      dir = Path.join(System.tmp_dir!(), "eml_use_case_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "user code picks .beam when present, otherwise compiles the .ex source", %{dir: dir} do
      uuid = ElixirModuleLoader.generate_uuid()
      module_name = "UC1Plugin_" <> String.replace(uuid, "-", "_")

      # The UUID identifies the module; the file name can be human readable.
      File.write!(Path.join(dir, "double_plugin.ex"), """
      defmodule #{module_name} do
        def double(x), do: x * 2
      end
      """)

      # Library user logic: prefer the compiled artifact, fall back to source.
      beam_path = Path.join(dir, "double_plugin.beam")
      source_path = Path.join(dir, "double_plugin.ex")
      path = if File.exists?(beam_path), do: beam_path, else: source_path

      {:ok, module} = ElixirModuleLoader.register_file(uuid, path)
      assert {:ok, ^module} = ElixirModuleLoader.lookup(uuid)

      # The register call already returned the module — usable immediately.
      assert 42 == module.double(21)

      ElixirModuleLoader.release(uuid)
      ElixirModuleLoader.unregister(uuid)
    end
  end

  # ── UC: dynamic, abstract access — functions are not known in advance ───────

  describe "dynamic access to unknown modules" do
    test "discover exports at runtime and call them as data" do
      uuid = ElixirModuleLoader.generate_uuid()

      {:ok, _module} =
        ElixirModuleLoader.register_source(uuid, """
        defmodule UC2Mystery do
          def shout(s), do: String.upcase(s)
          def whisper(s), do: String.downcase(s)
        end
        """)

      # The caller does not know the module: ask what it exports.
      {:ok, exports} = ElixirModuleLoader.functions(uuid)
      assert {:shout, 1} in exports
      assert {:whisper, 1} in exports

      # Call every discovered arity-1 function dynamically.
      {:ok, module} = ElixirModuleLoader.load(uuid)

      results =
        for {f, 1} <- exports, into: %{} do
          {f, apply(module, f, ["Hey"])}
        end

      assert results == %{shout: "HEY", whisper: "hey"}

      ElixirModuleLoader.release(uuid)
      ElixirModuleLoader.unregister(uuid)
    end
  end

  # ── UC: composition, chaining, currying across loaded modules ──────────────
  #
  # PROMPT.md: trimming comes from one module, "Bad" word removal from another,
  # upcasing from a third — all compiled at runtime, composed as `f(g(data))`.

  describe "function composition across dynamically loaded modules" do
    setup do
      specs =
        for {suffix, body} <- [
              {"Trimmer", "def trim(s), do: String.trim(s)"},
              {"Cleaner", ~S|def remove_bad(s), do: String.replace(s, "Bad ", "")|},
              {"Upcaser", "def upcase(s), do: String.upcase(s)"}
            ] do
          uuid = ElixirModuleLoader.generate_uuid()

          {:ok, _} =
            ElixirModuleLoader.register_source(uuid, """
            defmodule UC3#{suffix} do
              #{body}
            end
            """)

          uuid
        end

      [trim, clean, up] = specs

      on_exit(fn ->
        for uuid <- specs do
          if ElixirModuleLoader.loaded?(uuid), do: ElixirModuleLoader.release(uuid)
          ElixirModuleLoader.unregister(uuid)
        end
      end)

      {:ok, trim: trim, clean: clean, up: up}
    end

    test "result = f(g(data)) — composition of captured first-class funs", ctx do
      g = ElixirModuleLoader.fun(ctx.trim, :trim, 1)
      f = ElixirModuleLoader.fun(ctx.up, :upcase, 1)

      assert "HELLO" == f.(g.("   hello   "))
    end

    test "three-stage pipeline: trim |> remove Bad |> upcase", ctx do
      pipeline =
        SetmyInfo.ElixirModuleLoader.Fn.pipe([
          {ctx.trim, :trim},
          {ctx.clean, :remove_bad},
          {ctx.up, :upcase}
        ])

      assert "HELLO WORLD !!!" == pipeline.("   Hello Bad World !!!   ")
    end

    test "map-shaped data flows through a dynamically compiled transformation" do
      uuid = ElixirModuleLoader.generate_uuid()

      {:ok, module} =
        ElixirModuleLoader.register_source(uuid, """
        defmodule UC3MapTransform do
          def full_name(%{first: f, last: l} = person),
            do: Map.put(person, :full_name, f <> " " <> l)
        end
        """)

      assert %{full_name: "Ada Lovelace"} =
               module.full_name(%{first: "Ada", last: "Lovelace"})

      ElixirModuleLoader.unregister(uuid)
    end
  end
end
