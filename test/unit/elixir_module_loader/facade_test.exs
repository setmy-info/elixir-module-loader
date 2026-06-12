defmodule SetmyInfo.ElixirModuleLoader.FacadeTest do
  @moduledoc """
  Facade-level tests for the dual key/UUID surface: register_many with UUIDs,
  register_file from a .beam file, and execute/4 timeout.
  """

  use ExUnit.Case, async: false

  alias SetmyInfo.ElixirModuleLoader, as: ML
  alias SetmyInfo.ElixirModuleLoader.UUID

  describe "register_many/1 with UUID keys" do
    test "accepts a batch of UUID-keyed specs" do
      uuids = for _ <- 1..3, do: ML.generate_uuid()
      specs = Enum.map(uuids, &{&1, SomeModule})

      on_exit(fn -> Enum.each(uuids, &ML.unregister/1) end)

      assert :ok == ML.register_many(specs)
      assert Enum.all?(uuids, &ML.registered?/1)
    end

    test "rejects a malformed key without raising and inserts nothing" do
      good = ML.generate_uuid()

      assert {:error, :invalid_spec} ==
               ML.register_many([{good, SomeModule}, {"not-a-uuid", SomeModule}])

      refute ML.registered?(good)
    end

    test "rejects a malformed spec tuple without raising" do
      good = ML.generate_uuid()

      assert {:error, :invalid_spec} ==
               ML.register_many([{good, SomeModule}, :garbage])

      refute ML.registered?(good)
    end

    test "mixed UUID and binary keys in one batch" do
      uuid = ML.generate_uuid()
      key = ML.generate_key()

      on_exit(fn ->
        ML.unregister(uuid)
        ML.unregister(key)
      end)

      assert :ok == ML.register_many([{uuid, SomeModule}, {key, SomeModule}])
      assert ML.registered?(uuid)
      assert ML.registered?(key)
    end
  end

  describe "register_file/2 from a .beam file" do
    @source """
    defmodule SetmyInfo.ElixirModuleLoader.Test.BeamFixture do
      @behaviour SetmyInfo.ElixirModuleLoader.Behaviour
      def name, do: :beam_fixture
      def execute(:ping, []), do: {:ok, :pong}
      def execute(f, _), do: {:error, {:undefined_function, f}}
    end
    """

    test "compiles to a .beam on disk, then registers and runs it by UUID" do
      {:ok, [{module, binary}]} = ML.compile(@source)
      beam_path = Path.join(System.tmp_dir!(), "#{module}.beam")
      File.write!(beam_path, binary)
      :code.purge(module)
      :code.delete(module)

      uuid = ML.generate_uuid()

      on_exit(fn ->
        if ML.loaded?(uuid), do: ML.release(uuid)
        ML.unregister(uuid)
        File.rm(beam_path)
      end)

      assert {:ok, ^module} = ML.register_file(uuid, beam_path)
      assert {:ok, :pong} == ML.run_and_release(uuid, :ping, [])
    end
  end

  describe "execute/4 timeout via the facade" do
    test "a slow plugin returns {:error, :timeout} without crashing the caller" do
      source = """
      defmodule SetmyInfo.ElixirModuleLoader.Test.FacadeSlowPlugin do
        @behaviour SetmyInfo.ElixirModuleLoader.Behaviour
        def name, do: :facade_slow
        def execute(:hang, []), do: (Process.sleep(500); {:ok, :late})
        def execute(f, _), do: {:error, {:undefined_function, f}}
      end
      """

      uuid = ML.generate_uuid()
      {:ok, _module} = ML.compile(source)
      :ok = ML.register(uuid, SetmyInfo.ElixirModuleLoader.Test.FacadeSlowPlugin)
      {:ok, _pid} = ML.load(uuid)

      on_exit(fn ->
        if ML.loaded?(uuid), do: ML.release(uuid)
        ML.unregister(uuid)
      end)

      assert {:error, :timeout} = ML.execute(uuid, :hang, [], 100)
    end
  end

  describe "invalid keys raise on single-key functions" do
    test "load/1 raises ArgumentError on a malformed key string" do
      assert_raise ArgumentError, fn -> ML.load("not-a-uuid") end
    end

    test "registered?/1 raises ArgumentError on a malformed key string" do
      assert_raise ArgumentError, fn -> ML.registered?("nope") end
    end
  end

  describe "UUID round-trip through the facade helpers" do
    test "generate_uuid produces something UUID.to_key! accepts" do
      uuid = ML.generate_uuid()
      assert byte_size(UUID.to_key!(uuid)) == 16
    end
  end
end
