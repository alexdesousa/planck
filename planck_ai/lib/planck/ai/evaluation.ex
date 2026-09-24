defmodule Planck.AI.Evaluation do
  @moduledoc """
  Result type for `Planck.AI.evaluate/4`.

  A thin, name-only alias over `ReqLLM.Response.t()` — not a reshaped
  struct. `response.object` (the answers map, keyed by question name) and
  `response.usage` come through completely unchanged; `evaluate/4`
  deliberately doesn't rebuild this value the way `Planck.AI.Stream.from_req_llm/1`
  does for `stream/3`.

  Exists purely so callers (in particular `planck_agent`, which never
  depends on `req_llm` directly) reference a `Planck.AI`-owned type name
  instead of reaching into `req_llm`'s own `ReqLLM.Response` directly — the
  same abstraction boundary `Planck.AI.Stream.t()` already maintains for
  `stream/3`, at zero runtime cost since this is a pure type alias.
  """

  @typedoc """
  A RLCD evaluation result.
  """
  @type t :: ReqLLM.Response.t()
end
