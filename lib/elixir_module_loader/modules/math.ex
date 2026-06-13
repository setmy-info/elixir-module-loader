defmodule SetmyInfo.ElixirModuleLoader.Modules.Math do
  @moduledoc """
  Example built-in math module — a plain module, no interface required.

  Register it under any key and call it directly:

      key = SetmyInfo.ElixirModuleLoader.generate_key()
      SetmyInfo.ElixirModuleLoader.register(key, SetmyInfo.ElixirModuleLoader.Modules.Math)
      {:ok, math} = SetmyInfo.ElixirModuleLoader.load(key)
      5 = math.add(2, 3)
  """

  def add(a, b) when is_number(a) and is_number(b), do: a + b
  def subtract(a, b) when is_number(a) and is_number(b), do: a - b
  def multiply(a, b) when is_number(a) and is_number(b), do: a * b

  def divide(_a, 0), do: {:error, :division_by_zero}
  def divide(a, b) when is_number(a) and is_number(b), do: a / b
end
