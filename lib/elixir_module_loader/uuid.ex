defmodule SetmyInfo.ElixirModuleLoader.UUID do
  @moduledoc """
  Helpers for using UUID strings as module keys.

  Internally every key is a 128-bit binary (`<<_::128>>`). A UUID is exactly
  128 bits, so a UUID string such as `"550e8400-e29b-41d4-a716-446655440000"`
  maps one-to-one onto a key. These helpers convert between the two
  representations:

      uuid = SetmyInfo.ElixirModuleLoader.UUID.generate()
      #=> "8c7f2a3e-1b4d-4e6f-9a0b-3c5d7e9f1a2b"

      key = SetmyInfo.ElixirModuleLoader.UUID.to_key!(uuid)
      #=> <<140, 127, 42, 62, 27, 77, 78, 111, 154, 11, 60, 93, 126, 159, 26, 43>>

      SetmyInfo.ElixirModuleLoader.UUID.from_key(key) == uuid
      #=> true

  The facade functions in `SetmyInfo.ElixirModuleLoader` accept either form
  directly, so manual conversion is rarely needed.
  """

  @doc """
  Generate a random version-4 UUID string.

  The underlying 128 bits come from `:crypto.strong_rand_bytes/1`, with the
  version (4) and variant (RFC 4122) bits set, so the string is a valid UUIDv4.
  """
  @spec generate() :: String.t()
  def generate do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    encode(<<a::48, 4::4, b::12, 2::2, c::62>>)
  end

  @doc """
  Convert a UUID string to a 128-bit binary key.

  Accepts upper- or lower-case hex digits. Returns `{:ok, key}` or `:error`.
  """
  @spec to_key(String.t()) :: {:ok, <<_::128>>} | :error
  def to_key(string), do: decode(string)

  @doc "Like `to_key/1` but raises `ArgumentError` on malformed input."
  @spec to_key!(String.t()) :: <<_::128>>
  def to_key!(string) do
    case decode(string) do
      {:ok, key} -> key
      :error -> raise ArgumentError, "not a valid UUID string: #{inspect(string)}"
    end
  end

  @doc "Convert a 128-bit binary key to its canonical lower-case UUID string."
  @spec from_key(<<_::128>>) :: String.t()
  def from_key(<<_::128>> = key), do: encode(key)

  @doc "True if the term is a well-formed UUID string (8-4-4-4-12 hex groups)."
  @spec uuid_string?(term()) :: boolean()
  def uuid_string?(string) when is_binary(string), do: match?({:ok, _}, decode(string))
  def uuid_string?(_), do: false

  # ── Private ───────────────────────────────────────────────────────────────

  defp encode(<<_::128>> = key) do
    <<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2),
      e::binary-size(6)>> = key

    Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))
  end

  defp decode(
         <<a::binary-size(8), ?-, b::binary-size(4), ?-, c::binary-size(4), ?-, d::binary-size(4),
           ?-, e::binary-size(12)>>
       ) do
    Base.decode16(a <> b <> c <> d <> e, case: :mixed)
  end

  defp decode(_), do: :error
end
