defmodule SetmyInfo.ElixirModuleLoader.E2E.ModuleLoaderContext do
  @behaviour WhiteBread.ContextBehaviour

  import ExUnit.Assertions

  alias WhiteBread.Context.StepFunction

  @source """
  defmodule SetmyInfo.ElixirModuleLoader.BDD.AddPlugin do
    @behaviour SetmyInfo.ElixirModuleLoader.Behaviour
    def name, do: :bdd_add_plugin
    def execute(:add, [a, b]), do: {:ok, a + b}
    def execute(f, _), do: {:error, {:undefined_function, f}}
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
    {:ok, _} = SetmyInfo.ElixirModuleLoader.compile(@source)
    key = SetmyInfo.ElixirModuleLoader.generate_key()
    :ok = SetmyInfo.ElixirModuleLoader.register(key, SetmyInfo.ElixirModuleLoader.BDD.AddPlugin)
    {:ok, Map.merge(state, %{key: key, result: nil})}
  end

  def step_load_module(state, _extra) do
    {:ok, _pid} = SetmyInfo.ElixirModuleLoader.load(state.key)
    {:ok, state}
  end

  def step_execute_add(state, %{a: a, b: b}) do
    result =
      SetmyInfo.ElixirModuleLoader.execute(state.key, :add, [
        String.to_integer(a),
        String.to_integer(b)
      ])

    {:ok, Map.put(state, :result, result)}
  end

  def step_result_should_be(state, %{expected: expected}) do
    assert {:ok, String.to_integer(expected)} == state.result
    {:ok, state}
  end

  def step_module_should_be_loaded(state, _extra) do
    assert SetmyInfo.ElixirModuleLoader.loaded?(state.key)
    {:ok, state}
  end

  def step_release_module(state, _extra) do
    :ok = SetmyInfo.ElixirModuleLoader.release(state.key)
    {:ok, state}
  end

  def step_module_should_not_be_loaded(state, _extra) do
    refute SetmyInfo.ElixirModuleLoader.loaded?(state.key)
    {:ok, state}
  end
end
