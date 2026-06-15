defmodule SetmyInfo.ModulesTest do
  use ExUnit.Case, async: false

  alias SetmyInfo.Modules
  alias SetmyInfo.Modules.Request

  @moduletag :unit

  setup do
    original = Application.get_env(:elixir_module_loader, :modules_root_path)

    on_exit(fn ->
      if original do
        Application.put_env(:elixir_module_loader, :modules_root_path, original)
      else
        Application.delete_env(:elixir_module_loader, :modules_root_path)
      end
    end)

    :ok
  end

  describe "set_root_path/1 and root_path/0" do
    test "set and get root path" do
      :ok = Modules.set_root_path("/tmp/test_modules")
      {:ok, path} = Modules.root_path()
      assert String.ends_with?(path, "tmp/test_modules")
    end

    test "set_root_path expands relative paths" do
      :ok = Modules.set_root_path("./relative/path")
      {:ok, path} = Modules.root_path()
      assert Path.type(path) == :absolute
      refute String.starts_with?(path, ".")
    end

    test "root_path returns error when not set" do
      Application.delete_env(:elixir_module_loader, :modules_root_path)
      assert {:error, :root_path_not_set} = Modules.root_path()
    end
  end

  describe "uuid_path/1" do
    test "joins root path with UUID" do
      :ok = Modules.set_root_path("/tmp/modules")
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      {:ok, path} = Modules.uuid_path(uuid)
      assert path == "/tmp/modules/#{uuid}"
    end

    test "returns error when root path not set" do
      Application.delete_env(:elixir_module_loader, :modules_root_path)
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      assert {:error, :root_path_not_set} = Modules.uuid_path(uuid)
    end

    test "rejects a value that is not a well-formed UUID" do
      :ok = Modules.set_root_path("/tmp/modules")
      assert {:error, :invalid_uuid} = Modules.uuid_path("not-a-uuid")
    end

    test "rejects a traversal value so it cannot escape the root path" do
      :ok = Modules.set_root_path("/tmp/modules")
      assert {:error, :invalid_uuid} = Modules.uuid_path("../../../etc")
      assert {:error, :invalid_uuid} = Modules.uuid_path("../secrets")
      assert {:error, :invalid_uuid} = Modules.uuid_path("a/b/c")
    end
  end

  describe "module_path/1" do
    test "appends file_name from Request to uuid_path" do
      :ok = Modules.set_root_path("/tmp/modules")
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      request = %Request{uuid: uuid, file_name: "Masker.ex"}
      {:ok, path} = Modules.module_path(request)
      assert path == "/tmp/modules/#{uuid}/Masker.ex"
    end

    test "file_name is used as-is from the Request" do
      :ok = Modules.set_root_path("/tmp/modules")
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      request = %Request{uuid: uuid, file_name: "CustomPlugin.ex"}
      {:ok, path} = Modules.module_path(request)
      assert String.ends_with?(path, "/CustomPlugin.ex")
    end

    test "returns error when root path not set" do
      Application.delete_env(:elixir_module_loader, :modules_root_path)
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      request = %Request{uuid: uuid, file_name: "Module.ex"}
      assert {:error, :root_path_not_set} = Modules.module_path(request)
    end
  end

  # ── Path-traversal safety ─────────────────────────────────────────────────
  #
  # `uuid` is supplied by external systems (DB / HTTP / config). It must never
  # be trusted as a folder name: a value containing `..` or `/` would let a
  # caller escape the configured root path and read or write arbitrary files.
  # `uuid_path/1` validates the UUID up front, so every function built on it
  # (`module_path/1`, `compile/1`, `load/1`) is protected at a single choke
  # point. These tests pin that guarantee.

  describe "path-traversal rejection" do
    @traversal_values [
      "../../../etc/passwd",
      "../../secrets",
      "../sibling",
      "..",
      ".",
      "a/b/c",
      "/etc/cron.d",
      "/absolute/escape",
      "550e8400-e29b-41d4-a716-446655440000/../../escape",
      "550e8400-e29b-41d4-a716-446655440000/..",
      "..\\..\\windows",
      "foo\0bar",
      "",
      "   ",
      "not-a-uuid",
      "550e8400e29b41d4a716446655440000",
      "zzzzzzzz-e29b-41d4-a716-446655440000"
    ]

    test "uuid_path/1 rejects every traversal / malformed value" do
      :ok = Modules.set_root_path("/tmp/modules")

      for value <- @traversal_values do
        assert {:error, :invalid_uuid} = Modules.uuid_path(value),
               "expected #{inspect(value)} to be rejected as an invalid UUID"
      end
    end

    test "module_path/1 rejects traversal values before building any path" do
      :ok = Modules.set_root_path("/tmp/modules")

      for value <- @traversal_values do
        request = %Request{uuid: value, file_name: "Module.ex"}

        assert {:error, :invalid_uuid} = Modules.module_path(request),
               "expected #{inspect(value)} to be rejected as an invalid UUID"
      end
    end

    test "module_path/1 rejects a traversal file_name even with a valid UUID" do
      :ok = Modules.set_root_path("/tmp/modules")
      uuid = "550e8400-e29b-41d4-a716-446655440000"

      bad_names = [
        "../../../etc/passwd",
        "../sibling.ex",
        "sub/dir/Module.ex",
        "a\\b.ex",
        "..",
        ".",
        "",
        "Module.ex\0.png"
      ]

      for name <- bad_names do
        request = %Request{uuid: uuid, file_name: name}

        assert {:error, :invalid_file_name} = Modules.module_path(request),
               "expected file_name #{inspect(name)} to be rejected"
      end
    end

    test "module_path/1 accepts a plain file name" do
      :ok = Modules.set_root_path("/tmp/modules")
      uuid = "550e8400-e29b-41d4-a716-446655440000"

      for name <- ["Module.ex", "Masker.ex", "my_plugin.ex", "Elixir.Foo.beam"] do
        request = %Request{uuid: uuid, file_name: name}
        assert {:ok, "/tmp/modules/#{uuid}/#{name}"} == Modules.module_path(request)
      end
    end

    test "a resolved valid path always stays inside the root" do
      root = "/tmp/modules"
      :ok = Modules.set_root_path(root)
      uuid = "550e8400-e29b-41d4-a716-446655440000"

      {:ok, path} = Modules.uuid_path(uuid)
      assert Path.expand(path) == "#{root}/#{uuid}"
      assert String.starts_with?(Path.expand(path), root <> "/")
    end

    test "compile/1 writes nothing outside the root for a traversal uuid", %{} do
      root = Path.join(System.tmp_dir!(), "eml_escape_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      :ok = Modules.set_root_path(root)

      # Sentinel outside the root that a successful traversal could clobber.
      escape_target =
        Path.join(System.tmp_dir!(), "eml_escape_sentinel_#{System.unique_integer([:positive])}")

      File.write!(escape_target, "original")
      on_exit(fn -> File.rm_rf!(escape_target) end)

      request = %Request{uuid: "../#{Path.basename(escape_target)}", file_name: "Module.ex"}

      assert {:error, :invalid_uuid} = Modules.compile(request)
      assert File.read!(escape_target) == "original"
    end

    test "load/1 refuses to read a .beam from outside the root", %{} do
      root = Path.join(System.tmp_dir!(), "eml_escape_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      :ok = Modules.set_root_path(root)

      request = %Request{uuid: "../../../etc", file_name: "Module.ex"}
      assert {:error, :invalid_uuid} = Modules.load(request)
    end
  end
end
