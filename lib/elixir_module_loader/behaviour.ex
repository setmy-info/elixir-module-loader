defmodule SetmyInfo.ElixirModuleLoader.Behaviour do
  @moduledoc """
  Callback interface that all dynamically-loadable modules should implement.

  Implementing this behaviour allows a module to be dispatched through the
  Worker process after registration and loading.

  ## Example

      defmodule MyPlugin do
        @behaviour SetmyInfo.ElixirModuleLoader.Behaviour

        @impl true
        def name, do: :my_plugin

        @impl true
        def execute(:greet, [name]), do: {:ok, "Hello, \#{name}!"}
        def execute(f, _), do: {:error, {:undefined_function, f}}
      end
  """

  @doc "A unique atom identifying this module implementation."
  @callback name() :: atom()

  @doc "Execute a named function with the given positional arguments."
  @callback execute(function :: atom(), args :: [term()]) ::
              {:ok, term()} | {:error, term()}
end
