defmodule Planck.Headless.SessionName do
  alias Planck.Agent.Session
  @moduledoc """
  Generates and sanitizes human-readable session names in `<adjective>-<noun>` format.

  Names are embedded in SQLite filenames alongside the session id:
  `<sessions_dir>/<id>_<name>.db`. Both components are URL-safe and contain
  only `[a-z0-9-]` characters, with `_` reserved as the separator.

  ## Generation

  `generate/1` picks a random adjective + noun pair and retries (up to a
  configurable limit) if the resulting name already exists on disk.

  ## Sanitization

  `sanitize/1` normalises a user-provided string to the same character class:
  lowercase, spaces and underscores become hyphens, and any other character
  outside `[a-z0-9-]` is stripped. The result is truncated to 64 characters.
  If sanitization produces an empty string, `{:error, :invalid}` is returned.
  """

  @adjectives ~w(
    amber ancient angular arctic bold brave bright calm careful classic
    clever cold cool cosmic crisp curious damp dark dawn deep deft
    dense dim distant dry dusty dynamic eager easy electric elegant
    epic exact faint fast fierce fine fresh frozen gentle glacial
    grand heavy hidden hollow humble icy idle inner jolly keen
    kind late lazy light liquid lost loud lucky lunar lush
    mellow mild misty modern narrow neat noble north novel odd
    old open pale patient plain polar prime proud quick quiet
    rapid rare ready rigid rough round royal rustic sharp sleek
    slim slow small smooth soft solar solid steady still stone
    strong swift tall tidy tiny tough vivid warm wide wild
    winding wise wooden young
  )

  @nouns ~w(
    apple apricot avocado banana berry blossom blueberry broccoli
    cantaloupe carrot celery cherry chestnut citrus clementine coconut
    cucumber currant dates durian elderberry fennel fig garlic ginger
    grape grapefruit guava honeydew huckleberry jackfruit kiwi kumquat
    leek lemon lettuce lime lychee mango mangosteen melon mulberry
    nectarine olive onion orange papaya parsley peach pear pepper
    persimmon pineapple plum pomelo potato pumpkin quince radish
    raspberry rhubarb spinach starfruit strawberry tamarind tangerine
    tomato turnip walnut watermelon
  )

  @max_retries 20

  @doc """
  Generate a unique `<adjective>-<noun>` name not already present in
  `sessions_dir`. Retries up to #{@max_retries} times on collision.

  Returns `{:ok, name}` or `{:error, :exhausted}` if all retries collide.
  """
  @spec generate(Path.t()) :: {:ok, String.t()} | {:error, :exhausted}
  def generate(sessions_dir, retries \\ @max_retries)
  def generate(_sessions_dir, 0), do: {:error, :exhausted}

  def generate(sessions_dir, retries) do
    name = random_name()

    case Session.find_by_name(sessions_dir, name) do
      {:error, :not_found} -> {:ok, name}
      {:ok, _, _} -> generate(sessions_dir, retries - 1)
    end
  end

  @doc """
  Sanitize a user-provided string to a valid session name.

  - Lowercased.
  - Spaces and underscores converted to hyphens.
  - Characters outside `[a-z0-9-]` stripped.
  - Consecutive hyphens collapsed to one.
  - Leading and trailing hyphens removed.
  - Truncated to 64 characters.

  Returns `{:ok, name}` or `{:error, :invalid}` if the result is empty.
  """
  @spec sanitize(String.t()) :: {:ok, String.t()} | {:error, :invalid}
  def sanitize(input) when is_binary(input) do
    result =
      input
      |> String.downcase()
      |> String.replace(~r/[\s_]+/, "-")
      |> String.replace(~r/[^a-z0-9-]/, "")
      |> String.replace(~r/-{2,}/, "-")
      |> String.trim("-")
      |> String.slice(0, 64)

    if result == "", do: {:error, :invalid}, else: {:ok, result}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec random_name() :: String.t()
  defp random_name do
    adjective = Enum.random(@adjectives)
    noun = Enum.random(@nouns)
    "#{adjective}-#{noun}"
  end
end
