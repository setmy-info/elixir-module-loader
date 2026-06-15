defmodule SetmyInfo.ModulesIntegrationTest do
  use ExUnit.Case, async: false

  alias SetmyInfo.Modules
  alias SetmyInfo.Modules.Request
  alias SetmyInfo.ElixirModuleLoader, as: EML

  @moduletag :integration

  @transform_source """
  defmodule SetmyInfo.TestModules.SimpleTransform do
    def upcase(s) when is_binary(s), do: String.upcase(s)
    def reverse(s) when is_binary(s), do: String.reverse(s)
  end
  """

  @masker_source """
  defmodule SetmyInfo.TestModules.Masker do
    def mask(nil), do: nil
    def mask(value) when is_binary(value), do: String.duplicate("*", String.length(value))
  end
  """

  setup_all do
    tmp_root = Path.join(System.tmp_dir!(), "eml_modules_integration_#{:os.getpid()}")
    File.mkdir_p!(tmp_root)
    on_exit(fn -> File.rm_rf!(tmp_root) end)
    {:ok, tmp_root: tmp_root}
  end

  setup %{tmp_root: tmp_root} do
    original_root = Application.get_env(:elixir_module_loader, :modules_root_path)
    :ok = Modules.set_root_path(tmp_root)

    on_exit(fn ->
      if original_root do
        Application.put_env(:elixir_module_loader, :modules_root_path, original_root)
      else
        Application.delete_env(:elixir_module_loader, :modules_root_path)
      end
    end)

    :ok
  end

  describe "compile/1 — build phase" do
    test "writes .beam file to the UUID folder", %{tmp_root: root} do
      uuid = EML.generate_uuid()
      dir = Path.join(root, uuid)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "Transform.ex"), @transform_source)

      request = %Request{uuid: uuid, file_name: "Transform.ex"}
      {:ok, beam_paths} = Modules.compile(request)

      assert length(beam_paths) == 1
      assert Enum.all?(beam_paths, &String.ends_with?(&1, ".beam"))
      assert Enum.all?(beam_paths, &File.exists?/1)
    end

    test "does not register the module in EML", %{tmp_root: root} do
      uuid = EML.generate_uuid()
      dir = Path.join(root, uuid)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "Transform.ex"), @transform_source)

      request = %Request{uuid: uuid, file_name: "Transform.ex"}
      {:ok, _beam_paths} = Modules.compile(request)

      assert {:error, _} = EML.load(uuid)
    end
  end

  describe "load/1 — loading from .beam on disk" do
    test "loads the .beam file and registers under UUID", %{tmp_root: root} do
      uuid = EML.generate_uuid()
      dir = Path.join(root, uuid)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "Transform.ex"), @transform_source)

      request = %Request{uuid: uuid, file_name: "Transform.ex"}
      {:ok, _} = Modules.compile(request)

      {:ok, module} = Modules.load(request)
      assert module == SetmyInfo.TestModules.SimpleTransform
      assert EML.loaded?(uuid)

      :ok = EML.release(uuid)
    end

    test "loaded module functions work via get_function/3", %{tmp_root: root} do
      uuid = EML.generate_uuid()
      dir = Path.join(root, uuid)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "Transform.ex"), @transform_source)

      request = %Request{uuid: uuid, file_name: "Transform.ex"}
      {:ok, _} = Modules.compile(request)
      {:ok, _module} = Modules.load(request)

      {:ok, upcase_fn} = EML.get_function(uuid, "upcase", 1)
      {:ok, reverse_fn} = EML.get_function(uuid, "reverse", 1)

      assert "HELLO" = upcase_fn.(["hello"])
      assert "olleh" = reverse_fn.(["hello"])

      :ok = EML.release(uuid)
    end

    test "returns error when no .beam file exists in the UUID folder", %{tmp_root: root} do
      uuid = EML.generate_uuid()
      dir = Path.join(root, uuid)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "Transform.ex"), @transform_source)

      request = %Request{uuid: uuid, file_name: "Transform.ex"}

      assert {:error, :no_beam_file} = Modules.load(request)
    end

    test "loads externally placed .beam without calling compile/1", %{tmp_root: root} do
      uuid_src = EML.generate_uuid()
      uuid_dst = EML.generate_uuid()

      dir_src = Path.join(root, uuid_src)
      dir_dst = Path.join(root, uuid_dst)
      File.mkdir_p!(dir_src)
      File.mkdir_p!(dir_dst)
      File.write!(Path.join(dir_src, "Masker.ex"), @masker_source)

      # Compile in one UUID folder, copy .beam to another — simulates external compile
      {:ok, [beam_src]} = Modules.compile(%Request{uuid: uuid_src, file_name: "Masker.ex"})
      File.cp!(beam_src, Path.join(dir_dst, Path.basename(beam_src)))

      {:ok, module} = Modules.load(%Request{uuid: uuid_dst, file_name: "Masker.ex"})
      assert module == SetmyInfo.TestModules.Masker

      :ok = EML.release(uuid_dst)
    end
  end

  describe "two-phase workflow: compile then load" do
    test "different UUIDs compile and load different modules independently", %{tmp_root: root} do
      uuid_a = EML.generate_uuid()
      uuid_b = EML.generate_uuid()

      for {uuid, src, name} <- [
            {uuid_a, @transform_source, "Transform.ex"},
            {uuid_b, @masker_source, "Masker.ex"}
          ] do
        dir = Path.join(root, uuid)
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, name), src)
        {:ok, _} = Modules.compile(%Request{uuid: uuid, file_name: name})
      end

      {:ok, _} = Modules.load(%Request{uuid: uuid_a, file_name: "Transform.ex"})
      {:ok, _} = Modules.load(%Request{uuid: uuid_b, file_name: "Masker.ex"})

      {:ok, upcase_fn} = EML.get_function(uuid_a, "upcase", 1)
      {:ok, mask_fn} = EML.get_function(uuid_b, "mask", 1)

      assert "HELLO" = upcase_fn.(["hello"])
      assert "***" = mask_fn.(["abc"])

      :ok = EML.release(uuid_a)
      :ok = EML.release(uuid_b)
    end
  end

  describe "release and reload cycle" do
    test "module can be released and reloaded from .beam on disk", %{tmp_root: root} do
      uuid = EML.generate_uuid()
      dir = Path.join(root, uuid)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "Masker.ex"), @masker_source)

      request = %Request{uuid: uuid, file_name: "Masker.ex"}
      {:ok, _} = Modules.compile(request)

      {:ok, _mod} = Modules.load(request)
      {:ok, fun1} = EML.get_function(uuid, "mask", 1)
      assert "***" = fun1.(["abc"])

      :ok = EML.release(uuid)
      refute EML.loaded?(uuid)

      # EML reloads from the .beam path stored at registration time
      {:ok, _mod} = EML.load(uuid)
      {:ok, fun2} = EML.get_function(uuid, "mask", 1)
      assert "***" = fun2.(["abc"])

      :ok = EML.release(uuid)
    end
  end
end
