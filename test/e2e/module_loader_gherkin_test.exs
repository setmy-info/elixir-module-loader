defmodule SetmyInfo.ElixirModuleLoader.E2E.GherkinTest do
  use ExUnit.Case, async: false

  require Logger

  test "Gherkin BDD scenarios pass for module loader" do
    feature_path = Path.expand(Path.join(__DIR__, "../../features")) <> "/"

    %{failures: failures} =
      WhiteBread.run(SetmyInfo.ElixirModuleLoader.E2E.ModuleLoaderContext, feature_path, [])

    failure_names = Enum.map(failures, fn {feature, _result} -> feature.name end)

    assert failures == [],
           "Gherkin feature(s) failed: #{Enum.join(failure_names, ", ")}"
  end
end
