defmodule SetmyInfo.ElixirModuleLoader.Support.SampleModule do
  @behaviour SetmyInfo.ElixirModuleLoader.Behaviour

  @impl SetmyInfo.ElixirModuleLoader.Behaviour
  def name, do: :sample_module

  @impl SetmyInfo.ElixirModuleLoader.Behaviour
  def execute(:add, [a, b]) when is_number(a) and is_number(b), do: {:ok, a + b}
  def execute(:multiply, [a, b]) when is_number(a) and is_number(b), do: {:ok, a * b}
  def execute(:echo, [value]), do: {:ok, value}
  def execute(f, _), do: {:error, {:undefined_function, f}}
end
