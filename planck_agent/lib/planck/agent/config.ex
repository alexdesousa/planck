defmodule Planck.Agent.Config do
  @moduledoc """
  Application configuration for `planck_agent`.

  Variables can be set via the OS environment or application config.

  | Key | OS env var | Default |
  |---|---|---|
  | `:sessions_dir` | `PLANCK_AGENT_SESSIONS_DIR` | `.planck/sessions` under `File.cwd!()` |
  """

  use Skogsra

  @envdoc """
  Path to the sessions.
  """
  app_env(:sessions_dir, :planck_agent, :sessions_dir, default: ".planck/sessions")
end
