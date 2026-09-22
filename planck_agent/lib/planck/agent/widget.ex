defmodule Planck.Agent.Widget do
  @moduledoc """
  Behaviour for a sidecar-rendered widget streamed into the WebUI.

  Paired with a `Planck.Agent.Tool` via that tool's `:widget` field — there is
  no separate, independent widget declaration list. `Planck.Agent.Sidecar.list_widgets/0`
  derives the sidecar's full widget list from `tools/0` by filtering for tools
  that set `:widget`.

  ## Return values are opaque to planck_agent

  `render/1`'s return value is never inspected or interpreted here — only
  RPC'd through to whichever caller asked for it. `planck_agent` has no
  Phoenix dependency and no opinion about markup; a widget module is free to
  `use Phoenix.Component` and build real HEEx, flattened to a plain string
  before it crosses the RPC boundary (never send a `%Phoenix.LiveView.Rendered{}`
  or any closure across nodes). The one place that assumes the return value is
  an HTML string is the WebUI's own widget-rendering component, which is also
  the only place that needs to know.

  ## Dispatch is separate from `execute_tool/4`

  A widget's `render/1`/`handle_action/2` calls never go through the LLM
  tool-execution path. Two reasons: `Planck.Agent.Sidecar.execute_tool/4`'s
  result flows into the agent's actual message history sent back to the LLM,
  and a human clicking a widget button has no corresponding assistant-issued
  tool call to attach that to; and `execute_fn`'s `{:ok, string} | {:error,
  string}` contract is meant for the model's context, while a widget's output
  is meant for a UI surface to render — a different kind of value entirely.

  ## Minimal example

      defmodule MySidecar.Widgets.Counter do
        use Planck.Agent.Widget

        def id, do: "counter"
        def render(_myself), do: "<div>count: \#{count()}</div>"
        def handle_action("increment", _args), do: increment()
      end

  Paired with a tool via `widget: MySidecar.Widgets.Counter` in
  `Planck.Agent.Tool.new/1`.

  ## Container type

  `use Planck.Agent.Widget` injects `@behaviour Planck.Agent.Widget` and a
  default `container/0` returning `:modal`, overridable like any
  `defoverridable` function — `Counter.container()` above returns `:modal`
  without `Counter` writing anything. This is a real function on the module,
  not resolved through a lookup on the caller's side: calling `container/0`
  directly on a widget that skipped `use` (implementing the behaviour by hand
  with a bare `@behaviour Planck.Agent.Widget` instead) raises
  `UndefinedFunctionError` if it didn't also define its own `container/0` —
  `use` is what makes the default real, not something dispatch code papers
  over afterwards.
  """

  @doc "A stable identifier for this widget, unique within the sidecar."
  @callback id() :: String.t()

  @doc """
  Render the widget's current state.

  `myself` is passed through opaquely from the caller (in practice, a
  LiveComponent's CID) so the widget can bake it into any action controls it
  renders — the widget has no socket/component context of its own to resolve
  one from. The return value is never inspected by `planck_agent`; see the
  moduledoc.
  """
  @callback render(myself :: term()) :: term()

  @doc """
  Handle an action dispatched from the UI (e.g. a button click).

  Not gated by the LLM's tool-calling permissions — this is a human-facing
  path, invoked directly, never through `Planck.Agent.Sidecar.execute_tool/4`.
  """
  @callback handle_action(action :: String.t(), args :: map()) :: :ok | {:error, term()}

  @typedoc """
  How the WebUI should present this widget. Only `:modal` is actually
  rendered as of this version — `:drawer` and `:fullscreen` are reserved for
  future container chrome, not yet built.
  """
  @type container :: :modal | :drawer | :fullscreen

  @doc """
  Optional. Declares which container chrome the WebUI should wrap this
  widget's `render/1` output in. `use Planck.Agent.Widget` injects a default
  implementation returning `:modal` — override it to opt into a different
  container once one actually exists.
  """
  @callback container() :: container()

  @optional_callbacks container: 0

  @doc """
  Injects `@behaviour Planck.Agent.Widget` and a default `container/0`
  returning `:modal`, overridable via `defoverridable`. `id/0`, `render/1`,
  and `handle_action/2` have no sensible generic default and still need to be
  implemented directly — this only covers `container/0`.
  """
  defmacro __using__(_options) do
    quote do
      @behaviour Planck.Agent.Widget

      @impl Planck.Agent.Widget
      def container, do: :modal

      defoverridable container: 0
    end
  end
end
