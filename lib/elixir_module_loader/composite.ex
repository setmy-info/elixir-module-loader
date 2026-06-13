defmodule SetmyInfo.ElixirModuleLoader.Composite do
  @moduledoc """
  Interpreter for compositions of loaded functions, represented as data.

  A composition is a term (AST) registered under its own 128-bit key with
  `SetmyInfo.ElixirModuleLoader.register_composite/2`. Because it is plain
  data, the external system can store, inspect, diff and re-register it —
  a composed function is a first-class catalog entry, addressable, loadable
  and releasable like any module.

  ## Nodes

  * `{:ref, key}` — invoke the function or composite registered under `key`;
    arity follows the arguments.
  * `{:ref, key, function}` — call `function` on the module loaded under
    `key` (loading it on demand).
  * `{:partial, key, function, bound_args}` — partial application: call with
    `bound_args ++ args` (currying building block).
  * `{:pipe, [node, ...]}` — composition of arity-1 stages: the value flows
    left to right; a stage returning `{:error, _}` short-circuits.

  ## Example

      ast = {:pipe, [{:ref, trim_key, :trim}, {:ref, up_key, :upcase}]}
      :ok = SetmyInfo.ElixirModuleLoader.register_composite(key, ast)
      f = SetmyInfo.ElixirModuleLoader.fun(key)
      f.("  hello ")  #=> "HELLO"

  Results are raw — the library adds no wrapping. A composite that
  (transitively) references itself recurses until the stack gives out;
  validity checking is structural only.
  """

  alias SetmyInfo.ElixirModuleLoader.{Fn, UUID}

  @doc "True if the term is a well-formed composite AST."
  @spec valid?(term()) :: boolean()
  def valid?({:ref, key}), do: valid_key?(key)
  def valid?({:ref, key, function}), do: valid_key?(key) and is_atom(function)

  def valid?({:partial, key, function, bound}),
    do: valid_key?(key) and is_atom(function) and is_list(bound)

  def valid?({:pipe, stages}) when is_list(stages) and stages != [],
    do: Enum.all?(stages, &valid?/1)

  def valid?(_), do: false

  @doc """
  Evaluate a composite node with the given argument list.

  Referenced module keys are loaded on demand and stay loaded afterwards,
  for the external system to release. Returns the raw result of the final
  stage; a stage returning `{:error, _}` short-circuits a pipe.
  """
  @spec call(term(), [term()]) :: term()
  def call({:ref, key}, args), do: Fn.invoke(key, args)
  def call({:ref, key, function}, args), do: Fn.apply_module(key, function, args)

  def call({:partial, key, function, bound}, args),
    do: Fn.apply_module(key, function, bound ++ args)

  def call({:pipe, stages}, [input]) do
    Enum.reduce_while(stages, input, fn stage, acc ->
      case call(stage, [acc]) do
        {:error, _} = error -> {:halt, error}
        value -> {:cont, value}
      end
    end)
  end

  def call({:pipe, _stages}, args),
    do: {:error, {:bad_pipe_input, "pipe takes exactly one argument, got #{length(args)}"}}

  def call(other, _args), do: {:error, {:invalid_composite, other}}

  defp valid_key?(<<_::128>>), do: true
  defp valid_key?(key) when is_binary(key), do: UUID.uuid_string?(key)
  defp valid_key?(_), do: false
end
