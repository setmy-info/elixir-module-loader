defmodule SetmyInfo.ElixirModuleLoader.Modules.StringOps do
  @moduledoc """
  Example built-in string operations module — a plain module, no interface
  required. Call the functions directly on the loaded module.
  """

  def upcase(s) when is_binary(s), do: String.upcase(s)
  def downcase(s) when is_binary(s), do: String.downcase(s)
  def reverse(s) when is_binary(s), do: String.reverse(s)
  def length(s) when is_binary(s), do: String.length(s)
  def trim(s) when is_binary(s), do: String.trim(s)
end
