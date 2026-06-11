defmodule SetmyInfo.ElixirModuleLoader.Modules.StringOps do
  @moduledoc """
  Example built-in string operations module implementing `SetmyInfo.ElixirModuleLoader.Behaviour`.
  """

  @behaviour SetmyInfo.ElixirModuleLoader.Behaviour

  @impl SetmyInfo.ElixirModuleLoader.Behaviour
  def name, do: :string_ops

  @impl SetmyInfo.ElixirModuleLoader.Behaviour
  def execute(:upcase, [s]) when is_binary(s), do: {:ok, String.upcase(s)}
  def execute(:downcase, [s]) when is_binary(s), do: {:ok, String.downcase(s)}
  def execute(:reverse, [s]) when is_binary(s), do: {:ok, String.reverse(s)}
  def execute(:length, [s]) when is_binary(s), do: {:ok, String.length(s)}
  def execute(:trim, [s]) when is_binary(s), do: {:ok, String.trim(s)}
  def execute(function, _args), do: {:error, {:undefined_function, function}}
end
