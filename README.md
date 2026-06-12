# elixir-module-loader

Dynamic Elixir module compilation, loading, 128-bit-keyed registry, and
lifecycle management as a reusable OTP library.

Compile Elixir source strings or `.ex` / `.beam` files at runtime, register
the resulting modules under cryptographically-random 128-bit keys, load them
into supervised Worker processes, execute their functions, and release
them — all in a process-safe OTP supervision tree.

## Installation

Add `elixir_module_loader` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:elixir_module_loader, "~> 1.0"}
  ]
end
```

## Quick start

```elixir
alias SetmyInfo.ElixirModuleLoader

# 1. Compile a module (source string, .ex file, or .beam file)
{:ok, _} = ElixirModuleLoader.compile("""
  defmodule MyPlugin do
    @behaviour SetmyInfo.ElixirModuleLoader.Behaviour
    def name, do: :my_plugin
    def execute(:greet, [name]), do: {:ok, "Hello, \#{name}!"}
    def execute(f, _), do: {:error, {:undefined_function, f}}
  end
""")

# 2. Generate a 128-bit key and register the module
key = ElixirModuleLoader.generate_key()
:ok  = ElixirModuleLoader.register(key, MyPlugin)

# 3. Load (starts a supervised Worker process)
{:ok, _pid} = ElixirModuleLoader.load(key)

# 4. Execute a function
{:ok, "Hello, World!"} = ElixirModuleLoader.execute(key, :greet, ["World"])

# 5. Release (terminates the Worker, frees resources)
:ok = ElixirModuleLoader.release(key)
```

One-call shortcuts — no manual load/release needed:

```elixir
# Load (if not already loaded), execute, keep Worker running
{:ok, result} = ElixirModuleLoader.run(key, :greet, ["World"])

# Load, execute, release — atomically
{:ok, result} = ElixirModuleLoader.run_and_release(key, :greet, ["World"])
```

## Key type

All public functions accept a 16-byte binary (`<<_::128>>`).
Use `generate_key/0` to create a cryptographically-random key:

```elixir
key = SetmyInfo.ElixirModuleLoader.generate_key()  # :crypto.strong_rand_bytes(16)
```

## Implementing the Behaviour

```elixir
defmodule MyPlugin do
  @behaviour SetmyInfo.ElixirModuleLoader.Behaviour

  @impl SetmyInfo.ElixirModuleLoader.Behaviour
  def name, do: :my_plugin

  @impl SetmyInfo.ElixirModuleLoader.Behaviour
  def execute(:add, [a, b]) when is_number(a) and is_number(b), do: {:ok, a + b}
  def execute(f, _), do: {:error, {:undefined_function, f}}
end
```

The behaviour requires two callbacks:

| Callback          | Signature                                    | Description                          |
|-------------------|----------------------------------------------|--------------------------------------|
| `name/0`          | `() :: atom()`                               | Unique atom identifying this module  |
| `execute/2`       | `(atom(), [term()]) :: {:ok, term()} \| {:error, term()}` | Dispatch by function name |

## Built-in example modules

Two ready-to-use implementations ship with the library.

### `SetmyInfo.ElixirModuleLoader.Modules.Math`

| Function     | Arguments      | Returns                            |
|--------------|----------------|------------------------------------|
| `:add`       | `[a, b]`       | `{:ok, a + b}`                     |
| `:subtract`  | `[a, b]`       | `{:ok, a - b}`                     |
| `:multiply`  | `[a, b]`       | `{:ok, a * b}`                     |
| `:divide`    | `[a, b]`       | `{:ok, a / b}` or `{:error, :division_by_zero}` |

```elixir
alias SetmyInfo.ElixirModuleLoader
alias SetmyInfo.ElixirModuleLoader.Modules.Math

key = ElixirModuleLoader.generate_key()
ElixirModuleLoader.register(key, Math)
{:ok, _} = ElixirModuleLoader.load(key)
{:ok, 5} = ElixirModuleLoader.execute(key, :add, [2, 3])
{:ok, 2.5} = ElixirModuleLoader.execute(key, :divide, [5, 2])
{:error, :division_by_zero} = ElixirModuleLoader.execute(key, :divide, [1, 0])
```

### `SetmyInfo.ElixirModuleLoader.Modules.StringOps`

| Function     | Arguments | Returns                   |
|--------------|-----------|---------------------------|
| `:upcase`    | `[s]`     | `{:ok, String.upcase(s)}` |
| `:downcase`  | `[s]`     | `{:ok, String.downcase(s)}` |
| `:reverse`   | `[s]`     | `{:ok, String.reverse(s)}` |
| `:length`    | `[s]`     | `{:ok, String.length(s)}` |
| `:trim`      | `[s]`     | `{:ok, String.trim(s)}`   |

## API reference

All functions live on `SetmyInfo.ElixirModuleLoader`.

### Compilation

| Function                        | Description                                              |
|---------------------------------|----------------------------------------------------------|
| `compile(source)`               | Compile an Elixir source string, load modules into the VM |
| `compile_file(path)`            | Compile an Elixir `.ex` file, load modules into the VM   |
| `load_beam_file(path)`          | Load a pre-compiled `.beam` file from disk               |
| `load_beam_binary(name, binary)`| Load a BEAM binary already in memory                     |

### Registry

| Function                    | Description                                                   |
|-----------------------------|---------------------------------------------------------------|
| `generate_key()`            | Generate a cryptographically-random 128-bit key               |
| `register(key, module)`     | Register a module atom under a 128-bit key                    |
| `register_many(specs)`      | Register many `{key, module}` pairs at once                   |
| `lookup(key)`               | Look up which module is registered under a key                |
| `unregister(key)`           | Remove a key → module mapping (does not stop the Worker)      |
| `registered?(key)`          | Check if a key is currently registered                        |

### Lifecycle

| Function          | Description                                                          |
|-------------------|----------------------------------------------------------------------|
| `load(key)`       | Start a supervised Worker for the key; returns existing PID if already loaded |
| `reload(key)`     | Terminate any existing Worker and start a fresh one                  |
| `release(key)`    | Terminate the Worker and free resources                              |
| `loaded?(key)`    | Check if a Worker is currently running for the key                   |
| `pid_for(key)`    | Return the Worker PID for a key, or `{:error, :not_loaded}`          |

### Execution

| Function                          | Description                                                    |
|-----------------------------------|----------------------------------------------------------------|
| `execute(key, function, args)`    | Execute a function on the already-loaded Worker                |
| `run(key, function, args)`        | Load (if needed), execute, leave Worker running                |
| `run_and_release(key, function, args)` | Load, execute, release — full lifecycle in one call       |

## Bulk registration

```elixir
specs = [
  {key_a, PluginA},
  {key_b, PluginB}
]
:ok = SetmyInfo.ElixirModuleLoader.register_many(specs)
```

## Hot reload

After recompiling a module with `compile/1` or `compile_file/1`, existing
Worker processes automatically pick up the new code on their next call —
no restart required:

```elixir
{:ok, _} = SetmyInfo.ElixirModuleLoader.compile(new_source)
# Workers already running under key now use the new code automatically
{:ok, result} = SetmyInfo.ElixirModuleLoader.execute(key, :some_function, [])
```

To also reset Worker state (call count, etc.), use `reload/1`:

```elixir
{:ok, _new_pid} = SetmyInfo.ElixirModuleLoader.reload(key)
```

## Supervision tree

```
ApplicationSupervisor (one_for_one)
├── WorkerRegistry          — Elixir Registry for named Worker lookup
└── Supervisor (rest_for_one)
    ├── Registry            — ETS-backed 128-bit key → module atom mapping
    ├── DynamicSupervisor   — starts/stops Worker processes on demand
    └── Loader              — GenServer tracking loaded modules in ETS
        └── Worker(s)       — one GenServer per loaded module
```

The `:rest_for_one` strategy means:
- Registry crash → DynamicSupervisor + Loader restart (ETS rebuilt, Workers terminated)
- DynamicSupervisor crash → Loader restarts and reconciles with surviving Workers
- Loader crash → only Loader restarts; Workers survive, Loader reconciles from WorkerRegistry

## Development commands

```bash
mix build              # deps.get + compile
mix deps.get           # install dependencies
mix compile            # compile all source files
mix format             # format source files
mix validate           # compile --warnings-as-errors + format check
mix test.unit          # unit tests
mix test.integration   # integration tests
mix test.e2e           # e2e + Gherkin BDD tests
mix test.gherkin       # Gherkin/Cucumber only
mix test.all           # all tests
mix test.coverage      # ExCoveralls HTML report → _build/cover/
mix test.mutation      # Muzak mutation testing
mix audit              # dependency vulnerability scan (mix_audit)
mix security           # static security analysis (sobelow)
mix docs               # ExDoc HTML → _build/doc/
mix report             # docs + test.coverage + deps.audit
```

---

## Publishing to hex.pm

### Prerequisites

- Elixir 1.17+ and Mix installed
- A hex.pm account (free) at https://hex.pm/signup
- `hex` Mix task: `mix local.hex --force`

### 1 — Create account and authenticate

```bash
# Register a new account (one-time)
mix hex.user register

# Or authenticate an existing account on a new machine
mix hex.user auth
```

Mix stores an encrypted local key; you do not need to log in again on the same machine.

### 2 — Verify package metadata in mix.exs

The `package/0` section controls what hex.pm displays and what files are shipped:

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

Also confirm the top-level `project/0` fields:

| Field         | Purpose                        |
|---------------|--------------------------------|
| `version`     | SemVer string, e.g. `"0.1.0"`  |
| `description` | Short one-sentence description |
| `source_url`  | GitHub URL (shown on hex.pm)   |

### 3 — Generate API documentation

```bash
mix deps.get
mix docs
```

Docs are written to `_build/doc/`. Hex.pm serves them automatically at
`hexdocs.pm/elixir_module_loader` after publish.

### 4 — Dry-run (preview only)

```bash
mix hex.publish --dry-run
```

Verify: correct version, correct file list (only `lib/`, `mix.exs`,
`README.md`, `LICENSE`), no sensitive files included.

### 5 — Publish locally

**Option A — interactive (Mix prompts for your hex.pm password):**

```bash
mix hex.publish
```

**Option B — using an API key (same key as CI, no password prompt):**

```bash
HEX_API_KEY=<your-key> mix hex.publish --organization setmy_info --yes
```

Replace `<your-key>` with the key from hex.pm → Account settings → API Keys
(must be an organization key with write access to `setmy_info`).
The `--yes` flag skips the confirmation prompt, matching CI behaviour.
Using the API key is recommended when you want to test the exact same
authentication path that GitHub Actions uses before pushing to master.

Mix will build a tarball, upload docs to hexdocs.pm, and push to hex.pm.
After confirmation, the package is live at:

```
https://hex.pm/packages/elixir_module_loader
https://hexdocs.pm/elixir_module_loader
```

### 6 — Publish a new version

1. Bump `version` in `mix.exs` following SemVer.
2. Update this README if the public API changed.
3. Run `mix hex.publish`.

Hex.pm does **not** allow overwriting a published version. Use a new version
number for every release.

### 7 — Retire a version

```bash
mix hex.retire elixir_module_loader 0.1.0 security --message "Use 0.1.1 instead"
```

Retiring warns users without removing the version (existing users are not broken).

### 8 — Adding as a dependency

```elixir
{:elixir_module_loader, "~> 1.0"}
```

### CI auto-publish (GitHub Actions)

Add a `HEX_API_KEY` secret to your repository (Settings → Secrets).
Generate a CI-specific key (separate from your personal key):

```bash
mix hex.user key generate --key-name github-ci
```

Add a publish job to `.github/workflows/ci.yml`:

```yaml
  publish:
      needs: test
      runs-on: ubuntu-latest
      if: github.ref == 'refs/heads/master' && github.event_name == 'push'
      steps:
          -   uses: actions/checkout@v4
          -   uses: erlef/setup-beam@v1
              with:
                  otp-version: "29.x"
                  elixir-version: "1.19.x"
          -   run: mix deps.get
          -   run: mix hex.publish --yes
              env:
                  HEX_API_KEY: ${{ secrets.HEX_API_KEY }}
```

---

## License

MIT — see [LICENSE](LICENSE).
