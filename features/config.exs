defmodule WhiteBreadConfig do
  use WhiteBread.SuiteConfiguration

  suite(
    name: "Module Loader BDD",
    context: SetmyInfo.ElixirModuleLoader.E2E.ModuleLoaderContext,
    feature_paths: ["features/"]
  )
end
