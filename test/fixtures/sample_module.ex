defmodule SetmyInfo.ElixirModuleLoader.Support.SampleModule do
  @moduledoc false
  # Plain loadable module — no interface required by the library.

  def add(a, b) when is_number(a) and is_number(b), do: a + b
  def multiply(a, b) when is_number(a) and is_number(b), do: a * b
  def echo(value), do: value
end
