defmodule SetmyInfo.ElixirModuleLoader.Modules.Math do
  @moduledoc """
  Example built-in math module implementing `SetmyInfo.ElixirModuleLoader.Behaviour`.

  Register it with any 128-bit key before use:

      key = SetmyInfo.ElixirModuleLoader.generate_key()
      SetmyInfo.ElixirModuleLoader.register(key, SetmyInfo.ElixirModuleLoader.Modules.Math)
      {:ok, _pid} = SetmyInfo.ElixirModuleLoader.load(key)
      {:ok, 5} = SetmyInfo.ElixirModuleLoader.execute(key, :add, [2, 3])
  """

  @behaviour SetmyInfo.ElixirModuleLoader.Behaviour

  @impl SetmyInfo.ElixirModuleLoader.Behaviour
  def name, do: :math

  @impl SetmyInfo.ElixirModuleLoader.Behaviour
  def execute(:add, [a, b]) when is_number(a) and is_number(b), do: {:ok, a + b}
  def execute(:multiply, [a, b]) when is_number(a) and is_number(b), do: {:ok, a * b}
  def execute(:subtract, [a, b]) when is_number(a) and is_number(b), do: {:ok, a - b}
  def execute(:divide, [_a, 0]), do: {:error, :division_by_zero}
  def execute(:divide, [a, b]) when is_number(a) and is_number(b), do: {:ok, a / b}
  def execute(function, _args), do: {:error, {:undefined_function, function}}
end
