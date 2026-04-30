defmodule Planck.AI.Message do
  @moduledoc """
  A single conversation turn with a role and a list of typed content parts.

  Content is always a list of tagged tuples, mirroring the Anthropic API's
  multi-part message format. An assistant message may contain both text and
  tool calls interleaved.

  ## Content part types

  - `{:text, text}` — plain text
  - `{:image, data, mime_type}` — binary image data with MIME type
  - `{:image_url, url}` — image referenced by URL
  - `{:file, data, mime_type}` — binary file/document (PDF, etc.)
  - `{:video_url, url}` — video referenced by URL (Google Gemini only)
  - `{:tool_call, id, name, args}` — a tool call emitted by the model
  - `{:tool_result, id, result}` — the result of executing a tool call
  - `{:thinking, text}` — extended thinking / reasoning block

  ## Examples

      iex> %Planck.AI.Message{
      ...>   role: :user,
      ...>   content: [{:text, "What is the weather in Lisbon?"}]
      ...> }

  """

  @type role :: :user | :assistant | :tool_result

  @type content_part ::
          {:text, String.t()}
          | {:image, binary(), String.t()}
          | {:image_url, String.t()}
          | {:file, binary(), String.t()}
          | {:video_url, String.t()}
          | {:tool_call, String.t(), String.t(), map()}
          | {:tool_result, String.t(), term()}
          | {:thinking, String.t()}

  @type t :: %__MODULE__{
          role: role(),
          content: [content_part()]
        }

  defstruct [:role, content: []]
end
