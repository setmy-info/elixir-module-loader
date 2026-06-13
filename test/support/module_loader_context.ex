defmodule SetmyInfo.ElixirModuleLoader.E2E.ModuleLoaderContext do
  @behaviour WhiteBread.ContextBehaviour

  import ExUnit.Assertions

  alias SetmyInfo.ElixirModuleLoader, as: EML
  alias WhiteBread.Context.StepFunction

  # A plain module — the library imposes no interface on loadable code.
  @source """
  defmodule SetmyInfo.ElixirModuleLoader.BDD.AddPlugin do
    def add(a, b), do: a + b
  end
  """

  @impl WhiteBread.ContextBehaviour
  def get_steps do
    [
      StepFunction.new(~r/^the module loader is running$/, &step_module_loader_running/2),
      StepFunction.new(~r/^I load the module$/, &step_load_module/2),
      StepFunction.new(
        ~r/^I execute add with a=(?<a>-?\d+) and b=(?<b>-?\d+)$/,
        &step_execute_add/2
      ),
      StepFunction.new(~r/^the result should be (?<expected>-?\d+)$/, &step_result_should_be/2),
      StepFunction.new(~r/^the module should be loaded$/, &step_module_should_be_loaded/2),
      StepFunction.new(~r/^I release the module$/, &step_release_module/2),
      StepFunction.new(
        ~r/^the module should not be loaded$/,
        &step_module_should_not_be_loaded/2
      )
    ]
  end

  @impl WhiteBread.ContextBehaviour
  def feature_starting_state, do: %{}

  @impl WhiteBread.ContextBehaviour
  def scenario_starting_state(state), do: state

  @impl WhiteBread.ContextBehaviour
  def scenario_finalize(_status, _state), do: nil

  @impl WhiteBread.ContextBehaviour
  def feature_finalize(_status, _state), do: nil

  @impl WhiteBread.ContextBehaviour
  def get_scenario_timeout(_feature, _scenario), do: 30_000

  def step_module_loader_running(state, _extra) do
    key = EML.generate_key()
    {:ok, _module} = EML.register_source(key, @source)
    {:ok, Map.merge(state, %{key: key, module: nil, result: nil})}
  end

  def step_load_module(state, _extra) do
    # Loading hands back the module itself — the caller owns the calls.
    {:ok, module} = EML.load(state.key)
    {:ok, %{state | module: module}}
  end

  def step_execute_add(state, %{a: a, b: b}) do
    # Direct, dynamic invocation: the function name is data at runtime.
    result = apply(state.module, :add, [String.to_integer(a), String.to_integer(b)])
    {:ok, Map.put(state, :result, result)}
  end

  def step_result_should_be(state, %{expected: expected}) do
    assert String.to_integer(expected) == state.result
    {:ok, state}
  end

  def step_module_should_be_loaded(state, _extra) do
    assert EML.loaded?(state.key)
    {:ok, state}
  end

  def step_release_module(state, _extra) do
    :ok = EML.release(state.key)
    {:ok, state}
  end

  def step_module_should_not_be_loaded(state, _extra) do
    refute EML.loaded?(state.key)
    {:ok, state}
  end
end
