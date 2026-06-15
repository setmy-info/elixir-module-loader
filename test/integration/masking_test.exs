defmodule SetmyInfo.ElixirModuleLoader.Integration.MaskingTest do
  @moduledoc """
  Integration test for the deferred-load masking use case.

  Pattern demonstrated:

    1. Caller generates a UUID for each masking module.
    2. Compile masker sources WITHOUT loading (build phase).
    3. On demand: `load_source/2` or `load_file/2` → caller gets module
       immediately and can invoke it directly.
    4. Caller builds a `full_masking_function` lambda that combines the
       loaded modules — only the caller knows what functions are present.
    5. After use: `release/1` frees the working-set slot and purges code
       from the VM.

  This pattern scales to millions/billions of UUID-keyed modules on disk that
  are lazily loaded per request and released after use.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader, as: EML
  alias SetmyInfo.ElixirModuleLoader.{Registry, UUID}

  # ── Data structures ──────────────────────────────────────────────────────────

  # Input: person data received from a caller (e.g. a REST request)
  defmodule Person do
    defstruct [:first_name, :last_name]
  end

  # Output: DTO with masked fields, safe to return to the caller
  defmodule PersonDTO do
    defstruct [:first_name, :last_name]
  end

  # ── Masker module sources ────────────────────────────────────────────────────
  # In production these would live on disk under UUID-named folders.

  @default_masker_source """
  defmodule SetmyInfo.Masking.DefaultMasker do
    def mask(nil), do: nil
    def mask(value) when is_binary(value), do: String.duplicate("*", String.length(value))
  end
  """

  @first_name_masker_source """
  defmodule SetmyInfo.Masking.FirstNameMasker do
    def mask_first_name(nil), do: nil
    def mask_first_name(""), do: ""
    def mask_first_name(<<first::binary-size(1), rest::binary>>) do
      first <> String.duplicate("*", String.length(rest))
    end
  end
  """

  @last_name_masker_source """
  defmodule SetmyInfo.Masking.LastNameMasker do
    def mask_last_name(nil), do: nil
    def mask_last_name(value) when is_binary(value), do: String.duplicate("*", String.length(value))
  end
  """

  # ── compile without loading ──────────────────────────────────────────────────

  describe "compile-without-loading (build phase)" do
    test "compile/2 with load: false returns module-binary pairs" do
      {:ok, mods} = EML.compile(@default_masker_source, load: false)

      assert [{module, binary}] = mods
      assert is_atom(module)
      assert is_binary(binary)
    end

    test "compile_file/2 with load: false compiles a .ex file without registering" do
      tmp = write_tmp("default_masker", @default_masker_source)
      on_exit(fn -> File.rm(tmp) end)

      {:ok, mods} = EML.compile_file(tmp, load: false)

      assert [{module, binary}] = mods
      assert is_atom(module)
      assert is_binary(binary)
    end

    test "compile only, then load_source under UUID later" do
      # Build phase — compile without loading
      {:ok, [{_module, binary}]} = EML.compile(@default_masker_source, load: false)
      assert is_binary(binary)

      # Request phase — caller decides when to load
      uuid = EML.generate_uuid()
      key = UUID.to_key!(uuid)

      on_exit(fn ->
        if EML.loaded?(uuid), do: EML.release(uuid)
        Registry.unregister(key)
      end)

      {:ok, module} = EML.load_source(uuid, @default_masker_source)
      assert EML.loaded?(uuid)
      assert "***" == module.mask("abc")
    end

    test "compile only from file, then load_file under UUID later" do
      tmp = write_tmp("last_name_masker", @last_name_masker_source)
      on_exit(fn -> File.rm(tmp) end)

      # Build phase — compile file without loading into library
      {:ok, _mods} = EML.compile_file(tmp, load: false)

      # Request phase — caller loads on demand
      uuid = EML.generate_uuid()
      key = UUID.to_key!(uuid)

      on_exit(fn ->
        if EML.loaded?(uuid), do: EML.release(uuid)
        Registry.unregister(key)
      end)

      {:ok, module} = EML.load_file(uuid, tmp)
      assert EML.loaded?(uuid)
      assert "***" == module.mask_last_name("Doe")
    end
  end

  # ── load_binary/3 — single compilation, single loading ──────────────────────

  describe "load_binary/3 (compile once, load from binary)" do
    test "compile once, load binary under UUID without recompiling" do
      # Build phase — single compilation
      {:ok, [{module, binary}]} = EML.compile(@default_masker_source, load: false)

      # Request phase — load binary directly, no recompilation
      uuid = EML.generate_uuid()
      key = UUID.to_key!(uuid)

      on_exit(fn ->
        if EML.loaded?(uuid), do: EML.release(uuid)
        Registry.unregister(key)
      end)

      {:ok, ^module} = EML.load_binary(uuid, module, binary)
      assert EML.loaded?(uuid)

      {:ok, fun} = EML.get_function(uuid, :mask, 1)
      assert fun.(["abc"]) == "***"
    end

    test "same binary can be loaded under multiple UUIDs independently" do
      {:ok, [{module, binary}]} = EML.compile(@first_name_masker_source, load: false)

      uuid_a = EML.generate_uuid()
      uuid_b = EML.generate_uuid()
      key_a = UUID.to_key!(uuid_a)
      key_b = UUID.to_key!(uuid_b)

      on_exit(fn ->
        if EML.loaded?(uuid_a), do: EML.release(uuid_a)
        if EML.loaded?(uuid_b), do: EML.release(uuid_b)
        Registry.unregister(key_a)
        Registry.unregister(key_b)
      end)

      {:ok, ^module} = EML.load_binary(uuid_a, module, binary)
      {:ok, ^module} = EML.load_binary(uuid_b, module, binary)

      {:ok, fun_a} = EML.get_function(uuid_a, :mask_first_name, 1)
      {:ok, fun_b} = EML.get_function(uuid_b, :mask_first_name, 1)

      assert fun_a.(["Alice"]) == "A****"
      assert fun_b.(["Bob"]) == "B**"

      # Independent lifecycle — releasing A does not affect B
      :ok = EML.release(uuid_a)
      refute EML.loaded?(uuid_a)
      assert EML.loaded?(uuid_b)
    end

    test "efficient masking: compile three maskers once, load each as needed" do
      # Build phase — compile all maskers once
      {:ok, [{default_mod, default_bin}]} = EML.compile(@default_masker_source, load: false)
      {:ok, [{fn_mod, fn_bin}]} = EML.compile(@first_name_masker_source, load: false)
      {:ok, [{ln_mod, ln_bin}]} = EML.compile(@last_name_masker_source, load: false)

      default_uuid = EML.generate_uuid()
      fn_uuid = EML.generate_uuid()
      ln_uuid = EML.generate_uuid()

      uuids = [default_uuid, fn_uuid, ln_uuid]
      keys = [UUID.to_key!(default_uuid), UUID.to_key!(fn_uuid), UUID.to_key!(ln_uuid)]

      on_exit(fn ->
        Enum.each(uuids, &if(EML.loaded?(&1), do: EML.release(&1)))
        Enum.each(keys, &Registry.unregister/1)
      end)

      # Request phase — load from binaries, no recompilation
      {:ok, ^default_mod} = EML.load_binary(default_uuid, default_mod, default_bin)
      {:ok, ^fn_mod} = EML.load_binary(fn_uuid, fn_mod, fn_bin)
      {:ok, ^ln_mod} = EML.load_binary(ln_uuid, ln_mod, ln_bin)

      {:ok, mask_default} = EML.get_function(default_uuid, :mask, 1)
      {:ok, mask_fn} = EML.get_function(fn_uuid, :mask_first_name, 1)
      {:ok, mask_ln} = EML.get_function(ln_uuid, :mask_last_name, 1)

      person = %Person{first_name: "John", last_name: "Doe"}

      dto = %PersonDTO{
        first_name: mask_fn.([person.first_name]),
        last_name: mask_ln.([person.last_name])
      }

      assert dto.first_name == "J***"
      assert dto.last_name == "***"
      assert mask_default.(["secret"]) == "******"

      # Release all
      Enum.each(uuids, &EML.release/1)
      assert Enum.all?(uuids, &(not EML.loaded?(&1)))
    end
  end

  # ── load_source/2 ───────────────────────────────────────────────────────────

  describe "load_source/2" do
    test "loads masker under caller UUID and returns module immediately" do
      uuid = EML.generate_uuid()
      key = UUID.to_key!(uuid)

      on_exit(fn ->
        if EML.loaded?(uuid), do: EML.release(uuid)
        Registry.unregister(key)
      end)

      {:ok, module} = EML.load_source(uuid, @default_masker_source)

      assert EML.loaded?(uuid)
      assert "***" == module.mask("abc")
      assert nil == module.mask(nil)
    end

    test "release frees memory, reload restores code transparently" do
      uuid = EML.generate_uuid()
      key = UUID.to_key!(uuid)

      on_exit(fn ->
        if EML.loaded?(uuid), do: EML.release(uuid)
        Registry.unregister(key)
      end)

      {:ok, module} = EML.load_source(uuid, @default_masker_source)
      assert EML.loaded?(uuid)

      :ok = EML.release(uuid)
      refute EML.loaded?(uuid)

      # Library restores code automatically from stored BEAM binary
      {:ok, ^module} = EML.load(uuid)
      assert EML.loaded?(uuid)
      assert "***" == module.mask("xyz")
    end
  end

  # ── load_file/2 ─────────────────────────────────────────────────────────────

  describe "load_file/2" do
    test "loads masker from .ex file under caller UUID" do
      tmp = write_tmp("first_name_masker", @first_name_masker_source)
      on_exit(fn -> File.rm(tmp) end)

      uuid = EML.generate_uuid()
      key = UUID.to_key!(uuid)

      on_exit(fn ->
        if EML.loaded?(uuid), do: EML.release(uuid)
        Registry.unregister(key)
      end)

      {:ok, module} = EML.load_file(uuid, tmp)

      assert EML.loaded?(uuid)
      assert "J***" == module.mask_first_name("John")
      assert "" == module.mask_first_name("")
      assert nil == module.mask_first_name(nil)
    end

    test "release and reload from original file path" do
      tmp = write_tmp("last_name_masker", @last_name_masker_source)
      on_exit(fn -> File.rm(tmp) end)

      uuid = EML.generate_uuid()
      key = UUID.to_key!(uuid)

      on_exit(fn ->
        if EML.loaded?(uuid), do: EML.release(uuid)
        Registry.unregister(key)
      end)

      {:ok, module} = EML.load_file(uuid, tmp)
      assert "***" == module.mask_last_name("Doe")

      :ok = EML.release(uuid)
      refute EML.loaded?(uuid)

      # Library recompiles from the .ex path stored at registration time
      {:ok, ^module} = EML.load(uuid)
      assert "*****" == module.mask_last_name("Smith")
    end
  end

  # ── Full person masking use case ─────────────────────────────────────────────

  describe "full person masking use case" do
    test "load → discover functions → build masking lambda → mask → release" do
      fn_uuid = EML.generate_uuid()
      ln_uuid = EML.generate_uuid()
      fn_key = UUID.to_key!(fn_uuid)
      ln_key = UUID.to_key!(ln_uuid)

      on_exit(fn ->
        if EML.loaded?(fn_uuid), do: EML.release(fn_uuid)
        if EML.loaded?(ln_uuid), do: EML.release(ln_uuid)
        Registry.unregister(fn_key)
        Registry.unregister(ln_key)
      end)

      # --- Build phase: compile without loading ---
      {:ok, _} = EML.compile(@first_name_masker_source, load: false)
      {:ok, _} = EML.compile(@last_name_masker_source, load: false)

      # --- Request phase: load each masker under its caller-assigned UUID ---
      {:ok, fn_masker} = EML.load_source(fn_uuid, @first_name_masker_source)
      {:ok, ln_masker} = EML.load_source(ln_uuid, @last_name_masker_source)

      # Caller discovers functions at runtime — does not know them in advance
      {:ok, fn_exports} = EML.functions(fn_uuid)
      {:ok, ln_exports} = EML.functions(ln_uuid)

      assert {:mask_first_name, 1} in fn_exports
      assert {:mask_last_name, 1} in ln_exports

      # --- Caller builds a full masking lambda that combines both modules ---
      person = %Person{first_name: "John", last_name: "Doe"}

      full_masking_function = fn p ->
        %PersonDTO{
          first_name: fn_masker.mask_first_name(p.first_name),
          last_name: ln_masker.mask_last_name(p.last_name)
        }
      end

      dto = full_masking_function.(person)

      assert dto.first_name == "J***"
      assert dto.last_name == "***"

      # --- Release phase: free memory after the request is done ---
      :ok = EML.release(fn_uuid)
      :ok = EML.release(ln_uuid)

      refute EML.loaded?(fn_uuid)
      refute EML.loaded?(ln_uuid)
    end

    test "default + first-name + last-name maskers loaded independently" do
      default_uuid = EML.generate_uuid()
      fn_uuid = EML.generate_uuid()
      ln_uuid = EML.generate_uuid()

      uuids = [default_uuid, fn_uuid, ln_uuid]
      keys = Enum.map(uuids, &UUID.to_key!/1)

      on_exit(fn ->
        Enum.each(uuids, &if(EML.loaded?(&1), do: EML.release(&1)))
        Enum.each(keys, &Registry.unregister/1)
      end)

      {:ok, default_masker} = EML.load_source(default_uuid, @default_masker_source)
      {:ok, fn_masker} = EML.load_source(fn_uuid, @first_name_masker_source)
      {:ok, ln_masker} = EML.load_source(ln_uuid, @last_name_masker_source)

      person = %Person{first_name: "Alice", last_name: "Smith"}

      # Default masker handles any value
      assert "***" == default_masker.mask("abc")
      assert "****" == default_masker.mask("test")
      assert nil == default_masker.mask(nil)

      # Specific maskers through caller-built lambda
      full_masking_function = fn p ->
        %PersonDTO{
          first_name: fn_masker.mask_first_name(p.first_name),
          last_name: ln_masker.mask_last_name(p.last_name)
        }
      end

      dto = full_masking_function.(person)
      assert dto.first_name == "A****"
      assert dto.last_name == "*****"

      # Release all — memory freed
      Enum.each(uuids, &EML.release/1)
      assert Enum.all?(uuids, &(not EML.loaded?(&1)))
    end

    test "dynamic function discovery via apply/3 — caller does not hardcode function names" do
      uuid = EML.generate_uuid()
      key = UUID.to_key!(uuid)

      on_exit(fn ->
        if EML.loaded?(uuid), do: EML.release(uuid)
        Registry.unregister(key)
      end)

      {:ok, module} = EML.load_source(uuid, @first_name_masker_source)
      {:ok, exports} = EML.functions(uuid)

      # Caller finds the one-arity masking function without hardcoding its name
      [{fun_name, 1}] = Enum.filter(exports, fn {_f, arity} -> arity == 1 end)

      result = apply(module, fun_name, ["Maria"])
      assert result == "M****"
    end

    test "simulate per-request load → use → release cycle" do
      handle_request = fn source, fn_name ->
        uuid = EML.generate_uuid()
        key = UUID.to_key!(uuid)

        {:ok, _module} = EML.load_source(uuid, source)
        {:ok, fun} = EML.get_function(uuid, fn_name, 1)
        result = fun.(["sensitive-data"])
        :ok = EML.release(uuid)
        Registry.unregister(key)

        result
      end

      assert handle_request.(@default_masker_source, "mask") == "**************"
    end
  end

  # ── get_function/3 ──────────────────────────────────────────────────────────

  describe "get_function/3 — capture functions by name from external systems" do
    test "returns a closure for a function name supplied as atom" do
      uuid = EML.generate_uuid()
      key = UUID.to_key!(uuid)

      on_exit(fn ->
        if EML.loaded?(uuid), do: EML.release(uuid)
        Registry.unregister(key)
      end)

      {:ok, _module} = EML.load_source(uuid, @first_name_masker_source)

      {:ok, fun} = EML.get_function(uuid, :mask_first_name, 1)
      assert fun.(["John"]) == "J***"
      assert fun.(["Alice"]) == "A****"
    end

    test "returns a closure for a function name supplied as string" do
      uuid = EML.generate_uuid()
      key = UUID.to_key!(uuid)

      on_exit(fn ->
        if EML.loaded?(uuid), do: EML.release(uuid)
        Registry.unregister(key)
      end)

      {:ok, _module} = EML.load_source(uuid, @last_name_masker_source)

      # Function name arrives as a string from an external system
      fn_name_from_config = "mask_last_name"
      {:ok, fun} = EML.get_function(uuid, fn_name_from_config, 1)
      assert fun.(["Doe"]) == "***"
      assert fun.(["Smith"]) == "*****"
    end

    test "returns {:error, :not_found} for a function name not exported" do
      uuid = EML.generate_uuid()
      key = UUID.to_key!(uuid)

      on_exit(fn ->
        if EML.loaded?(uuid), do: EML.release(uuid)
        Registry.unregister(key)
      end)

      {:ok, _module} = EML.load_source(uuid, @default_masker_source)

      assert {:error, :not_found} = EML.get_function(uuid, :nonexistent_fn, 1)
      assert {:error, :not_found} = EML.get_function(uuid, "also_not_there", 1)
    end

    test "returned closures compose naturally at runtime" do
      fn_uuid = EML.generate_uuid()
      ln_uuid = EML.generate_uuid()
      fn_key = UUID.to_key!(fn_uuid)
      ln_key = UUID.to_key!(ln_uuid)

      on_exit(fn ->
        if EML.loaded?(fn_uuid), do: EML.release(fn_uuid)
        if EML.loaded?(ln_uuid), do: EML.release(ln_uuid)
        Registry.unregister(fn_key)
        Registry.unregister(ln_key)
      end)

      {:ok, _} = EML.load_source(fn_uuid, @first_name_masker_source)
      {:ok, _} = EML.load_source(ln_uuid, @last_name_masker_source)

      # Caller receives function names from external systems (config / DB)
      {:ok, mask_fn} = EML.get_function(fn_uuid, "mask_first_name", 1)
      {:ok, mask_ln} = EML.get_function(ln_uuid, "mask_last_name", 1)

      person = %Person{first_name: "John", last_name: "Doe"}

      # Full masking lambda assembled entirely at runtime by the caller
      full_mask = fn p ->
        %PersonDTO{
          first_name: mask_fn.([p.first_name]),
          last_name: mask_ln.([p.last_name])
        }
      end

      dto = full_mask.(person)
      assert dto.first_name == "J***"
      assert dto.last_name == "***"
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp write_tmp(name, source) do
    path = Path.join(System.tmp_dir!(), "#{name}_#{:erlang.unique_integer([:positive])}.ex")
    File.write!(path, source)
    path
  end
end
