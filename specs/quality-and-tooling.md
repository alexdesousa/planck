# Quality & Tooling

## Standards enforced across all packages

Every package in the monorepo follows the same quality bar. No exceptions.

## Formatting

`mix format` is the formatter. CI fails on any unformatted file:

```sh
mix format --dry-run --check-formatted
```

Each package has its own `.formatter.exs`. Run `mix format` before every commit.

## Compilation

```sh
mix compile --warnings-as-errors
```

Zero warnings tolerated. CI fails on any warning.

## Credo

Strict mode. Each package has its own `.credo.exs` based on the strict defaults.
Run as part of the `test` CI job:

```sh
mix credo
```

## Dialyzer

Via `dialyxir`. PLT stored at `priv/plts/<app>.plt` (gitignored). Run in its own CI
job with the PLT cached by `mix.lock` hash:

```elixir
# In mix.exs:
defp dialyzer do
  [plt_file: {:no_warn, "priv/plts/#{@app}.plt"}]
end
```

```sh
mix dialyzer
```

All public functions must have `@spec`. No Dialyzer warnings tolerated.

## Test coverage

ExCoveralls. Reports posted to GitHub via `mix coveralls.github` in CI:

```elixir
{:excoveralls, "~> 0.18", only: :test, runtime: false}
```

## Mocking external calls

Mox is the mocking library. Used for any test that would otherwise make a real HTTP
call (e.g. `req_llm` in `planck_ai`). Define a behaviour wrapping the external call,
then mock it in tests:

```elixir
{:mox, "~> 1.2", only: :test}
```

Pattern:
1. Define `MyApp.SomeBehaviour` with the callbacks to mock
2. Inject the module (default: real impl, test: mock) via application config
3. `Mox.defmock(MyApp.MockSome, for: MyApp.SomeBehaviour)` in `test/support/`

## Documentation

ExDoc is the documentation tool. Every package publishes docs to HexDocs on release.

Rules:
- Every public module has a `@moduledoc` explaining its purpose and usage
- Every public function has a `@doc` with at least one example in `## Examples`
- No `@moduledoc false` on public modules
- `@spec` on every public function (also enforced by Dialyzer)
- Private functions and internal modules do not require `@doc`

ExDoc dependency in each package:

```elixir
{:ex_doc, "~> 0.34", only: :dev, runtime: false}
```

Run locally with `mix docs`. Output goes to `doc/` (gitignored).

## Dev dependencies (every package)

```elixir
{:credo, "~> 1.7", only: [:dev, :test], runtime: false},
{:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
{:excoveralls, "~> 0.18", only: :test, runtime: false},
{:mox, "~> 1.2", only: :test}
```

## CI job structure (mirrors Skogsra checks.yml)

Two jobs per package:

**`test` job** (`MIX_ENV=test`):
1. Checkout
2. Setup BEAM (OTP + Elixir)
3. `mix do local.rebar --force, local.hex --force, deps.get`
4. `mix deps.compile`
5. `mix compile --warnings-as-errors`
6. `mix format --dry-run --check-formatted`
7. `mix coveralls.github`
8. `mix credo`

**`dialyzer` job** (`MIX_ENV=dev`):
1. Checkout
2. Setup BEAM
3. Cache PLT (`priv/plts/`) keyed on `mix.lock` hash
4. `mix do local.rebar --force, local.hex --force, deps.get`
5. `mix deps.compile`
6. `mix dialyzer`
