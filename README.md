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
    {:elixir_module_loader, "~> 0.1"}
  ]
end
```

## Quick start

```elixir
# 1. Compile a module (source string, .ex file, or .beam file)
{:ok, _} = ElixirModuleLoader.compile("""
  defmodule MyPlugin do
    @behaviour ElixirModuleLoader.Behaviour
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

One-call shorthand — load, execute, release atomically:

```elixir
{:ok, result} = ElixirModuleLoader.run_and_release(key, :greet, ["World"])
```

## Key type

All public functions accept a 16-byte binary (`<<_::128>>`).
Use `ElixirModuleLoader.generate_key/0` to create a cryptographically-random key:

```elixir
key = ElixirModuleLoader.generate_key()  # :crypto.strong_rand_bytes(16)
```

## Implementing the Behaviour

```elixir
defmodule MyPlugin do
  @behaviour ElixirModuleLoader.Behaviour

  @impl ElixirModuleLoader.Behaviour
  def name, do: :my_plugin

  @impl ElixirModuleLoader.Behaviour
  def execute(:add, [a, b]) when is_number(a) and is_number(b), do: {:ok, a + b}
  def execute(f, _), do: {:error, {:undefined_function, f}}
end
```

Built-in examples are provided in `ElixirModuleLoader.Modules.Math` and
`ElixirModuleLoader.Modules.StringOps`.

## Bulk registration

```elixir
specs = [
  {key_a, PluginA},
  {key_b, PluginB}
]
:ok = ElixirModuleLoader.register_many(specs)
```

## Hot reload

After recompiling a module with `compile/1` or `compile_file/1`, existing
Worker processes automatically pick up the new code on their next call —
no restart required:

```elixir
{:ok, _} = ElixirModuleLoader.compile(new_source)
# Worker(s) already running under `key` now use the new code
{:ok, result} = ElixirModuleLoader.execute(key, :some_function, [])
```

To also reset Worker state (call count, etc.), use `reload/1`:

```elixir
{:ok, _new_pid} = ElixirModuleLoader.reload(key)
```

## Development commands

```bash
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

### 5 — Publish

```bash
mix hex.publish
```

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
{:elixir_module_loader, "~> 0.1"}
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

### CI auto-publish (Bitbucket Pipelines)

Bitbucket Pipelines is configured by `bitbucket-pipelines.yml` at the
repository root. The file is already included in this project.

#### 1 — Generate a hex.pm CI key

```bash
mix hex.user key generate --key-name bitbucket-ci
```

Copy the printed key — it is shown only once.

#### 2 — Store the key as a repository variable

1. Open your Bitbucket repository.
2. Go to **Repository settings → Repository variables**.
3. Add a variable:
    - **Name:** `HEX_API_KEY`
    - **Value:** the key from step 1
    - **Secured:** ✓ (hides it from logs)

For workspace-level reuse across multiple repositories add it instead under
**Workspace settings → Workspace variables**.

For environment-scoped control (e.g. staging vs production):

1. Go to **Repository settings → Deployments**.
2. Create an environment named `production`.
3. Add `HEX_API_KEY` as a deployment variable there.
4. Reference it in the pipeline step with `deployment: production`.

#### 3 — Enable Pipelines

1. Go to **Repository settings → Pipelines → Settings**.
2. Toggle **Enable Pipelines** on.

#### 4 — Pipeline structure

The included `bitbucket-pipelines.yml` runs four stages:

| Stage    | Branch               | Purpose                                        |
|----------|----------------------|------------------------------------------------|
| Test     | all branches and PRs | compile, format, unit/integration/e2e/gherkin  |
| Security | all branches and PRs | `mix deps.audit` + `mix sobelow`               |
| Coverage | all branches and PRs | `mix coveralls.html`; report saved as artifact |
| Publish  | `master` push only   | `mix hex.publish --yes` with `HEX_API_KEY`     |

#### 5 — What to commit

- `bitbucket-pipelines.yml` — commit this file; it is already present.
- Never commit `HEX_API_KEY` or any secret; use repository / workspace variables only.

---

## License

MIT — see [LICENSE](LICENSE).
