defmodule SetmyInfo.ElixirModuleLoader.UUIDTest do
  use ExUnit.Case, async: true

  alias SetmyInfo.ElixirModuleLoader.UUID

  describe "generate/0" do
    test "produces a canonical 36-char UUID string" do
      uuid = UUID.generate()
      assert is_binary(uuid)
      assert String.length(uuid) == 36
      assert uuid =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    end

    test "is version 4 / RFC 4122 variant" do
      <<_::48, version::4, _::12, variant::2, _::62>> = UUID.to_key!(UUID.generate())
      assert version == 4
      assert variant == 2
    end

    test "successive UUIDs are unique" do
      uuids = for _ <- 1..1_000, do: UUID.generate()
      assert length(Enum.uniq(uuids)) == 1_000
    end
  end

  describe "to_key!/1 and from_key/1 round-trip" do
    test "string → key → string is identity" do
      uuid = UUID.generate()
      assert UUID.from_key(UUID.to_key!(uuid)) == uuid
    end

    test "key → string → key is identity" do
      key = :crypto.strong_rand_bytes(16)
      assert UUID.to_key!(UUID.from_key(key)) == key
    end

    test "to_key! yields a 16-byte binary" do
      key = UUID.to_key!("550e8400-e29b-41d4-a716-446655440000")
      assert byte_size(key) == 16
    end

    test "accepts upper-case input" do
      lower = "550e8400-e29b-41d4-a716-446655440000"
      upper = String.upcase(lower)
      assert UUID.to_key!(upper) == UUID.to_key!(lower)
    end
  end

  describe "to_key/1" do
    test "returns {:ok, key} for valid input" do
      assert {:ok, <<_::128>>} = UUID.to_key("550e8400-e29b-41d4-a716-446655440000")
    end

    test "returns :error for malformed input" do
      assert :error = UUID.to_key("not-a-uuid")
      assert :error = UUID.to_key("550e8400e29b41d4a716446655440000")
      assert :error = UUID.to_key("")
    end
  end

  describe "to_key!/1 errors" do
    test "raises ArgumentError on malformed input" do
      assert_raise ArgumentError, fn -> UUID.to_key!("nope") end
    end
  end

  describe "uuid_string?/1" do
    test "true for a valid UUID string" do
      assert UUID.uuid_string?(UUID.generate())
    end

    test "false for non-UUID strings and non-strings" do
      refute UUID.uuid_string?("nope")
      refute UUID.uuid_string?(:crypto.strong_rand_bytes(16))
      refute UUID.uuid_string?(123)
    end
  end
end
