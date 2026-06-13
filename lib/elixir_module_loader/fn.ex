defmodule SetmyInfo.ElixirModuleLoader.Fn do
  @moduledoc """
  Functional-programming helpers over loaded modules and functions.

  Everything here builds plain Elixir closures around key-based dispatch, so
  loaded code becomes first-class function values usable with `Enum`,
  `Stream`, `Task`, and as arguments to other loaded functions. Closures are
  **late-bound**: they capture the key, not the code, so they survive hot
  swaps, releases and reloads of the underlying module.

  The library never wraps results: a captured function returns exactly what
  the underlying function returns. The only convention is in `pipe/1` and
  composite `{:pipe, _}` nodes, where a stage returning `{:error, _}`
  short-circuits the pipeline (railway style).
  """

  alias SetmyInfo.ElixirModuleLoader, as: EML
  alias SetmyInfo.ElixirModuleLoader.{Composite, Registry, UUID}

  @max_arity 8

  @doc """
  Invoke whatever is registered under the key — a function target (memoised
  when `pure: true`) or a composite — with the given argument list.

  Module-target keys have no single callable: capture a concrete function
  with `SetmyInfo.ElixirModuleLoader.fun/3` instead.
  """
  @spec invoke(EML.key_or_uuid(), [term()]) :: term()
  def invoke(key_or_uuid, args) when is_list(args) do
    key = norm(key_or_uuid)

    case Registry.lookup_entry(key) do
      {:ok, _m, %{target: {:function, mfa}, pure: pure}} -> call_target(key, mfa, args, pure)
      {:ok, _m, %{target: {:composite, ast}}} -> Composite.call(ast, args)
      {:ok, _m, _meta} -> {:error, {:module_key_requires_function, key}}
      {:error, :not_found} -> {:error, {:not_registered, key}}
    end
  end

  @doc """
  Apply `function` of the module loaded under the key — loading it on demand —
  with the given argument list. Returns the raw result; a key that cannot be
  loaded returns `{:error, {:load_failed, reason}}`.
  """
  @spec apply_module(EML.key_or_uuid(), atom(), [term()]) :: term()
  def apply_module(key_or_uuid, function, args) when is_atom(function) and is_list(args) do
    case EML.load(key_or_uuid) do
      {:ok, module} -> apply(module, function, args)
      {:error, reason} -> {:error, {:load_failed, reason}}
    end
  end

  @doc """
  Build a closure of the given arity around a dispatcher that takes the
  argument list. Supports arities 0–#{@max_arity}.
  """
  @spec make_closure(non_neg_integer(), ([term()] -> term())) :: function()
  def make_closure(0, d), do: fn -> d.([]) end
  def make_closure(1, d), do: fn a -> d.([a]) end
  def make_closure(2, d), do: fn a, b -> d.([a, b]) end
  def make_closure(3, d), do: fn a, b, c -> d.([a, b, c]) end
  def make_closure(4, d), do: fn a, b, c, e -> d.([a, b, c, e]) end
  def make_closure(5, d), do: fn a, b, c, e, f -> d.([a, b, c, e, f]) end
  def make_closure(6, d), do: fn a, b, c, e, f, g -> d.([a, b, c, e, f, g]) end
  def make_closure(7, d), do: fn a, b, c, e, f, g, h -> d.([a, b, c, e, f, g, h]) end
  def make_closure(8, d), do: fn a, b, c, e, f, g, h, i -> d.([a, b, c, e, f, g, h, i]) end

  def make_closure(arity, _d),
    do: raise(ArgumentError, "function arity #{arity} exceeds supported maximum #{@max_arity}")

  @doc """
  Partial application: bind leading arguments of a loaded module function,
  get back an arity-1 closure for the remaining argument.

      add5 = SetmyInfo.ElixirModuleLoader.Fn.partial(math_key, :add, [5])
      add5.(3)  #=> 8
  """
  @spec partial(EML.key_or_uuid(), atom(), [term()]) :: (term() -> term())
  def partial(key_or_uuid, function, bound_args) when is_list(bound_args) do
    fn arg -> apply_module(key_or_uuid, function, bound_args ++ [arg]) end
  end

  @doc """
  Compose `{key, function}` stages into one arity-1 function: the value flows
  through every stage; a stage returning `{:error, _}` short-circuits.

      pipeline = SetmyInfo.ElixirModuleLoader.Fn.pipe([{trim_key, :trim}, {up_key, :upcase}])
      pipeline.("  hello ")  #=> "HELLO"
  """
  @spec pipe([{EML.key_or_uuid(), atom()}]) :: (term() -> term())
  def pipe(steps) when is_list(steps) do
    fn input ->
      Enum.reduce_while(steps, input, fn {key, function}, acc ->
        case apply_module(key, function, [acc]) do
          {:error, _} = error -> {:halt, error}
          value -> {:cont, value}
        end
      end)
    end
  end

  @doc false
  # Apply a function target; memoised per {key, args} when declared pure.
  def call_target(key, {m, f, _a}, args, pure?) do
    if pure? do
      case Registry.memo_get(key, args) do
        {:hit, result} ->
          result

        :miss ->
          result = apply(m, f, args)
          Registry.memo_put(key, args, result)
          result
      end
    else
      apply(m, f, args)
    end
  end

  defp norm(<<_::128>> = key), do: key
  defp norm(uuid) when is_binary(uuid), do: UUID.to_key!(uuid)
end
