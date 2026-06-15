defmodule SetmyInfo.ElixirModuleLoader.Modules.Math do
  @moduledoc """
  Example built-in math module — a plain module, no interface required.

  Register it and discover its functions at runtime:

      alias SetmyInfo.ElixirModuleLoader, as: EML
      {:ok, key, _m} = EML.load_by_name(SetmyInfo.ElixirModuleLoader.Modules.Math)
      {:ok, add_fn}  = EML.get_function(key, :add, 2)
      5              = add_fn.([2, 3])
  """

  def add(a, b) when is_number(a) and is_number(b), do: a + b
  def subtract(a, b) when is_number(a) and is_number(b), do: a - b
  def multiply(a, b) when is_number(a) and is_number(b), do: a * b

  def divide(_a, 0), do: {:error, :division_by_zero}
  def divide(a, b) when is_number(a) and is_number(b), do: a / b
end
