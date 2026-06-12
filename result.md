# elixir-module-loader — Project Result

## What Was Done

Created a standalone Elixir library for publishing to hex.pm, named by the
current directory `elixir-module-loader`. Follows `elixir-start-project`
conventions with the web layer removed.

The library compiles Elixir source/files into BEAM, loads them into the
running VM, and manages their lifecycle through a 128-bit-keyed OTP-supervised
registry.

### Core library modules

| File                                             | Purpose                                            |
|--------------------------------------------------|----------------------------------------------------|
| `lib/elixir_module_loader.ex`                    | Public API facade — all public functions           |
| `lib/elixir_module_loader/application.ex`        | OTP Application entry point                        |
| `lib/elixir_module_loader/behaviour.ex`          | Callback interface for loadable modules            |
| `lib/elixir_module_loader/compiler.ex`           | Compile source/file/binary → BEAM; purge/delete    |
| `lib/elixir_module_loader/registry.ex`           | ETS-backed 128-bit key → module atom registry      |
| `lib/elixir_module_loader/loader.ex`             | GenServer: load/reload/release Worker lifecycle    |
| `lib/elixir_module_loader/worker.ex`             | Per-module GenServer process; dispatches execute/3 |
| `lib/elixir_module_loader/supervisor.ex`         | Root supervisor (rest_for_one)                     |
| `lib/elixir_module_loader/executor.ex`           | High-level run/3 and run_and_release/3             |
| `lib/elixir_module_loader/modules/math.ex`       | Built-in example: arithmetic operations            |
| `lib/elixir_module_loader/modules/string_ops.ex` | Built-in example: string operations                |

### Key design decisions

- **128-bit keys** — `<<_::128>>` 16-byte binaries; generate with
  `ElixirModuleLoader.generate_key/0` (calls `:crypto.strong_rand_bytes(16)`)
- **Process/thread safety** — Registry and Loader writes serialised through
  `GenServer.call`; ETS reads bypass the GenServer mailbox (O(1))
- **OTP supervision** — Workers run under `DynamicSupervisor`; Loader
  reconciles with `WorkerRegistry` after any crash
- **Hot reload** — `Compiler.from_source/1` swaps in new code while existing
  Worker processes stay alive

### Tests

| Suite              | Files                                                                        | What is covered                                   |
|--------------------|------------------------------------------------------------------------------|---------------------------------------------------|
| Unit               | `test/unit/**/*_test.exs`                                                    | Compiler, Registry (incl. bulk), Loader, Executor |
| Integration        | `test/integration/**/*_test.exs`                                             | Lifecycle, concurrency, hot swap                  |
| E2E                | `test/e2e/module_loader_e2e_test.exs`                                        | Full public API facade                            |
| Gherkin / Cucumber | `test/e2e/module_loader_gherkin_test.exs` + `features/module_loader.feature` | BDD scenarios                                     |

---

## Comparison with elixir-start-project template

### Structure: umbrella vs flat

elixir-start-project is an **umbrella project** (`apps_path: "apps"`) with six
child applications (core_logic, runtime_engine, graphql_api, cli, wasm,
lessons). This project is a **flat single-package library** — one `lib/`,
one `mix.exs`, one test tree — which is the correct structure for a hex.pm
library.

### File-by-file: what was taken over vs adapted vs omitted

| Template item                                 | This project                                  | Status          |
|-----------------------------------------------|-----------------------------------------------|-----------------|
| `config/config.exs` + env files               | `config/config.exs` + same env files          | Taken over      |
| `coveralls.json`                              | `coveralls.json`                              | Taken over      |
| `.editorconfig`                               | `.editorconfig`                               | Taken over      |
| `.formatter.exs`                              | `.formatter.exs`                              | Taken over      |
| `.gitignore`                                  | `.gitignore`                                  | Taken over      |
| `features/config.exs`                         | `features/config.exs`                         | Taken over      |
| `LICENSE`                                     | `LICENSE`                                     | Taken over      |
| `README.md`                                   | `README.md` (library-focused, hex guide merged)| Adapted        |
| `mix.exs` aliases (validate, test.*, audit…)  | Same aliases, adapted for flat structure      | Adapted         |
| `mix.exs` deps (ex_doc, excoveralls, muzak…)  | Same deps, added white_bread, gherkin         | Adapted         |
| `.muzak.exs`                                  | Fixed format (see below)                      | Fixed           |
| `apps/runtime_engine/`                        | `lib/elixir_module_loader/` (full port)       | Ported & expanded|
| `apps/integration_tests/`                     | `test/` (unit/, integration/, e2e/, support/) | Adapted         |
| `features/*.feature`                          | `features/module_loader.feature`              | New             |
| `BEAM_HEX_PUBLISH.md`                         | Merged into `README.md`                       | Merged          |
| `.sobelow-conf`                               | Not created                                   | Omitted (note 1)|
| `scripts/hello.exs`                           | Not created                                   | Omitted (note 2)|
| `apps/graphql_api/`                           | Not created                                   | Omitted — no web|
| `apps/cli/`                                   | Not created                                   | Omitted — scope |
| `apps/wasm/`                                  | Not created                                   | Omitted — scope |
| `apps/core_logic/` (Ecto / DB)                | Not created                                   | Omitted — no DB |
| `apps/lessons/`                               | Not created                                   | Omitted — scope |
| GitHub Actions CI                             | `.github/workflows/ci.yml` (4-job)            | Added (new)     |
| Bitbucket Pipelines                           | Not included                                  | Not used        |
| `mix.exs package/0`                           | Added for hex.pm publishing                   | Added (new)     |

**Note 1 — `.sobelow-conf`**: The template configures sobelow with a specific
`router:` path pointing to the graphql_api router. This project has no router,
so `mix sobelow --config` is run without a config file; sobelow auto-detects
what to scan. No `.sobelow-conf` is needed.

**Note 2 — `scripts/`**: The template has `scripts/hello.exs` as a standalone
script example. Out of scope for a library; not copied.

---

### Differences and fixes applied

#### 1. `.muzak.exs` format (bug fix)

The template uses `%Muzak.Config{...}` struct syntax:
```elixir
%Muzak.Config{
  files: ["apps/.../**/*.ex"],
  formatters: [Muzak.Formatters.Simple]
}
```

muzak 1.1.1 does **not** define `Muzak.Config` as a struct — `Muzak.Config` is
a plain module with functions. Using the struct syntax raises a compile error:
```
error: Muzak.Config.__struct__/1 is undefined
```

muzak 1.1.1 also does not read a `files:` option from the config; it reads
files from `Mix.Project.config()[:elixirc_paths]` directly.

**Fix** — `.muzak.exs` now returns the map format muzak 1.1.1 expects:
```elixir
%{
  default: [
    mutations: 1_000
  ]
}
```

#### 2. ExDoc `extras` — LICENSE link warning (bug fix)

The template's `docs:` config only lists `"README.md"` in `extras`. `README.md`
has a `[LICENSE](LICENSE)` link. ExDoc validates links in extras and warns that
`LICENSE` is not in the extras list:
```
warning: documentation references file "LICENSE" but it does not exist
```

The file exists on disk; ExDoc just needs it declared in `extras`.

**Fix** — `mix.exs` docs now includes:
```elixir
extras: ["README.md", "LICENSE"]
```

#### 3. `test.coverage` alias (bug fix)

The template defines `"test.coverage": ["test.coverage"]` which is self-referential
and causes `Mix.Tasks.Test.Coverage` to conflict with Mix's own task namespace.

**Fix** — alias points directly to the coveralls task:
```elixir
"test.coverage": ["coveralls.html"]
```

#### 4. White_bread typing violations (library limitation, not a bug)

Elixir 1.19 introduced a type checker. white_bread 4.4.0's step macros generate
a function that dispatches by runtime arity:
```elixir
case :erlang.fun_info(func)[:arity] do
  2 -> func.(state, extra)
  1 -> func.(state)
end
```

The type checker sees both branches and emits a typing violation on the unused
branch, regardless of whether the step function is 1-arity or 2-arity. This is
a false positive from the library's implementation — it cannot be eliminated
from our code. Tests pass correctly at runtime.

Convention followed: 1-arity lambdas for steps **without** regex captures,
2-arity for steps **with** captures (matching the intended white_bread usage).

#### 5. `mix format` is not a custom alias

The question arose whether the formatting command was removed. `mix format` is
a built-in Mix task and is always available. It is also included in the
`validate` alias:
```elixir
validate: ["compile --warnings-as-errors", "format --check-formatted"]
```

Running `mix format` auto-formats; `mix validate` checks formatting in CI mode.

#### 6. Added: hex.pm `package/0` metadata

The template is not a hex.pm library and has no `package/0` function.
This project adds the required metadata for hex publishing:
```elixir
defp package do
  [
    name: "elixir_module_loader",
    licenses: ["MIT"],
    links: %{"GitHub" => "https://github.com/setmy-info/elixir-module-loader"},
    maintainers: ["Imre Tabur"],
    files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
  ]
end
```

#### 7. Added: CI pipelines (not in template)

The template has no CI configuration. This project adds:

- `.github/workflows/ci.yml` — 4-job GitHub Actions pipeline:
  test (OTP×Elixir matrix) → security → coverage → publish (master only)

---

## runtime_engine Analysis — Principles Taken Over

`elixir-start-project/apps/runtime_engine` is the reference implementation
that this library is based on. The following analysis captures what was
taken over, what was adapted, and what differs intentionally.

### Structural mapping

| runtime_engine (elixir-start-project)              | elixir-module-loader                                 | Notes                                                                                                    |
|----------------------------------------------------|------------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| `RuntimeEngine.Module` (behaviour)                 | `ElixirModuleLoader.Behaviour`                       | Identical callbacks: `name/0`, `execute/2`                                                               |
| `RuntimeEngine.ModuleRegistry` (atom key → module) | `ElixirModuleLoader.Registry` (128-bit key → module) | Same ETS + GenServer pattern; key type differs                                                           |
| `RuntimeEngine.Loader`                             | `ElixirModuleLoader.Loader`                          | Identical lifecycle: load/reload/release + ETS tracking                                                  |
| `RuntimeEngine.Worker`                             | `ElixirModuleLoader.Worker`                          | Identical: GenServer per module, via-registry name                                                       |
| `RuntimeEngine.Supervisor`                         | `ElixirModuleLoader.Supervisor`                      | Identical: `:rest_for_one`, same child order                                                             |
| `RuntimeEngine.Executor`                           | `ElixirModuleLoader.Executor`                        | Identical: `run/3` and `run_and_release/3`                                                               |
| `RuntimeEngine.HotCode`                            | `ElixirModuleLoader.Compiler`                        | Same `from_source/load_from_source`, `from_beam/load_from_beam`; renamed to reflect broader compile role |
| `RuntimeEngine.Application`                        | `ElixirModuleLoader.Application`                     | Identical: WorkerRegistry + Supervisor                                                                   |
| `RuntimeEngine.Modules.Math`                       | `ElixirModuleLoader.Modules.Math`                    | Taken over; added `:divide` with zero guard                                                              |
| `RuntimeEngine.Modules.StringOps`                  | `ElixirModuleLoader.Modules.StringOps`               | Identical                                                                                                |

### Principles confirmed and followed

1. **ETS + GenServer split** — reads bypass the GenServer (O(1), safe for
   many concurrent readers); all writes go through `GenServer.call` to
   serialise concurrent mutations.

2. **`rest_for_one` supervision** — child order is Registry → DynamicSupervisor
   → Loader. A Registry crash restarts everything (clean ETS rebuild); a Loader
   crash only restarts the Loader, which reconciles with the live
   `WorkerRegistry`.

3. **Worker registration via `Registry`** — each Worker uses `{:via, Registry, ...}`
   for process naming, allowing lookup by logical name without going through the
   Loader.

4. **Crash recovery / reconciliation** — on Loader restart, `reconcile_with_registry/0`
   re-populates the ETS table from surviving Worker processes in the Registry.

5. **Hot reload without Worker restart** — `Compiler.from_source/1` compiles
   and loads new BEAM code; existing Worker processes pick up the new code on
   their next `handle_call`.

6. **Triple-purge cleanup in tests** — same cleanup sequence as runtime_engine's
   `HotCodeTest`:
   ```elixir
   :code.purge(@module)   # remove old code
   :code.delete(@module)  # current → old
   :code.purge(@module)   # remove the newly-old code
   ```

7. **`ignore_module_conflict: true` around compile** — wraps `Code.compile_string`
   to suppress the "redefining module" warning on hot swaps.

8. **`@impl ModuleName`** and guard clauses in built-in modules — taken from
   `runtime_engine/modules/`.

### Differences (intentional)

| Aspect                             | runtime_engine                               | elixir-module-loader                | Reason                                                         |
|------------------------------------|----------------------------------------------|-------------------------------------|----------------------------------------------------------------|
| Registry key type                  | atom (`:math_module`)                        | `<<_::128>>` binary                 | Library requirement: collision-free 128-bit identity           |
| Built-in modules pre-seeded        | Yes — `@builtins` in `ModuleRegistry.init/1` | No                                  | Library provides the mechanism; callers seed their own modules |
| `register_many/1`                  | Takes `[{atom, module}]`                     | Takes `[{<<_::128>>, module}]`      | Same concept, adapted key type                                 |
| Error atom on Registry miss        | `:not_registered`                            | `:not_found`                        | Minor; both convey the same intent                             |
| `Loader.list_loaded()` return type | `[atom()]`                                   | `[<<_::128>>]`                      | Follows key type                                               |
| `HotCode` vs `Compiler`            | Focused on hot reload                        | Broader: source, file, binary, BEAM | Library needs compile-from-file for the integration tests      |

### What runtime_engine has that was NOT replicated

| Feature                                                       | Status                                                |
|---------------------------------------------------------------|-------------------------------------------------------|
| `register_many/1` — initially missing                         | Added after analysis                                  |
| Executor unit test — initially missing                        | Added after analysis                                  |
| Built-in Math / StringOps modules — initially missing         | Added after analysis                                  |
| Guard clauses in fixtures and built-ins                       | Added after analysis                                  |
| `ModuleRegistry` bulk `register_many` stress test (500 items) | Added to `RegistryTest`                               |
| HotCode `module_md5/1` test — v1 ≠ v2 assertion               | `CompilerTest` covers md5; v1≠v2 not in our tests yet |
| `LoaderTest` bulk cleanup via `list_loaded()`                 | Our tests use per-key cleanup; equivalent coverage    |

---

## Tooling taken over from elixir-start-project

| Tool                  | Config file                | Purpose                       |
|-----------------------|----------------------------|-------------------------------|
| ExCoveralls           | `coveralls.json`           | HTML coverage report          |
| Muzak                 | `.muzak.exs`               | Mutation testing              |
| ExDoc                 | `mix.exs → docs:`          | API documentation             |
| mix_audit             | `mix.exs → deps`           | Dependency vulnerability scan |
| sobelow               | `mix.exs → deps`           | Static security analysis      |
| white_bread + gherkin | `mix.exs → deps`           | Cucumber BDD testing          |
| EditorConfig          | `.editorconfig`            | 2-space indent for .ex/.exs   |
| mix formatter         | `.formatter.exs`           | Code formatting               |

### CI pipelines (added, not in template)

| File                       | Platform | Jobs/stages                                   |
|----------------------------|----------|-----------------------------------------------|
| `.github/workflows/ci.yml` | GitHub   | test → security → coverage → publish (master) |

### Environments (same as elixir-start-project)

| `MIX_ENV` | Config file           | Usage                        |
|-----------|-----------------------|------------------------------|
| `:dev`    | → maps to `local.exs` | Local machine, debug logging |
| `:local`  | `config/local.exs`    | Explicit local dev           |
| `:test`   | `config/test.exs`     | Test runs, warnings only     |
| `:ci`     | `config/ci.exs`       | CI pipeline                  |
| `:live`   | `config/live.exs`     | Production                   |

## What Was NOT Taken Over from elixir-start-project

| Omitted item                        | Reason                              |
|-------------------------------------|-------------------------------------|
| Umbrella / `apps/` structure        | Library projects are single-package |
| `apps/graphql_api`                  | No web layer                        |
| `apps/cli`                          | Not a CLI application               |
| `apps/wasm`                         | Out of scope                        |
| `apps/core_logic` (Ecto / database) | No persistence layer                |
| `apps/lessons`                      | Learning sandbox, not library code  |
| Ecto migrations                     | No database                         |
| Absinthe / Plug / Cowboy            | No web layer                        |
| `.sobelow-conf`                     | No router; sobelow runs without it  |
| `scripts/hello.exs`                 | Out of scope for a library          |

## Quick Start

```bash
cd elixir-module-loader
mix deps.get
mix test.all          # all tests
mix validate          # format + compile checks
mix docs              # ExDoc HTML → _build/doc/
```

Hex.pm publish guide is in `README.md`.
