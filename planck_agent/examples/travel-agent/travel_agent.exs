secret_key_base = :crypto.strong_rand_bytes(48) |> Base.encode64()
signing_salt = :crypto.strong_rand_bytes(8) |> Base.encode64()

Application.put_env(:travel_agent, TravelAgent.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 8000],
  server: true,
  live_view: [signing_salt: signing_salt],
  secret_key_base: secret_key_base
)

Mix.install([
  {:planck_agent, "~> 0.2"},
  {:plug_cowboy, "~> 2.5"},
  {:phoenix, "~> 1.7.0"},
  {:phoenix_live_view, "~> 0.20"},
  {:req, "~> 0.7"},
  {:jason, "~> 1.4"},
  {:mdex, "~> 0.13"}
])

# A minimal travel-planning agent built directly on Planck.Agent — no
# planck_headless, no TEAM.json, no .planck/ config files, no session
# persistence. One Planck.Agent GenServer, four custom tools, streamed to
# the browser over a Phoenix LiveView socket (no hand-written JS beyond the
# two CDN <script> tags LiveView itself needs).
#
# Run with: elixir travel_agent.exs — then open http://localhost:8000
#
# ---------------------------------------------------------------------------
# Every module/function below is tagged by what it's doing here, so you can
# skip straight to what you came for:
#
#   [BOILERPLATE]   Phoenix/LiveView/CSS wiring to get a browser UI running.
#                   Not Planck-specific — skip it if you've seen Phoenix
#                   before.
#   [EXTERNAL API]  Real (Open-Meteo, REST Countries) and simulated
#                   (MockFlights) data sources the tools below call out to.
#   [PLANCK.AGENT]  The actual point of this example — building a Model,
#                   defining tools, starting an agent, and handling its
#                   events. This is what the article is about.
# ---------------------------------------------------------------------------

# [BOILERPLATE]
defmodule TravelAgent.Theme do
  @moduledoc "RetroUI neobrutalist styling, matching planck_cli's own theme."

  @css """
  <style>
    :root {
      --radius: 0;
      --background: #f5f5f5;
      --foreground: #1a1a1a;
      --card: #ffffff;
      --card-foreground: #1a1a1a;
      --primary: #5F4FE6;
      --primary-hover: #4938C2;
      --primary-foreground: #fff;
      --secondary: #3a3a3a;
      --secondary-foreground: #f5f5f5;
      --muted: #CFCCEA;
      --muted-foreground: #5B5686;
      --accent: #FED13B;
      --accent-foreground: #000000;
      --destructive: #EF4444;
      --destructive-foreground: #fff;
      --border: #3a3a3a;
    }

    body {
      background: var(--background);
      color: var(--foreground);
      font-family: ui-sans-serif, system-ui, sans-serif;
    }

    .retro-card {
      background: var(--card);
      color: var(--card-foreground);
      border: 3px solid var(--border);
      box-shadow: 4px 4px 0 var(--border);
      border-radius: 0;
    }

    .retro-btn {
      background: var(--primary);
      color: var(--primary-foreground);
      border: 3px solid var(--border);
      box-shadow: 4px 4px 0 var(--border);
      border-radius: 0;
      padding: 0.5rem 1rem;
      font-weight: 700;
      cursor: pointer;
    }
    .retro-btn:hover { background: var(--primary-hover); }
    .retro-btn:active { transform: translate(2px, 2px); box-shadow: 2px 2px 0 var(--border); }
    .retro-btn:disabled, .retro-input:disabled { opacity: 0.5; cursor: not-allowed; }

    .retro-input {
      background: var(--card);
      color: var(--card-foreground);
      border: 3px solid var(--border);
      border-radius: 0;
      padding: 0.5rem;
      width: 100%;
    }

    .retro-pill {
      display: inline-block;
      background: var(--accent);
      color: var(--accent-foreground);
      border: 2px solid var(--border);
      border-radius: 0;
      padding: 0.15rem 0.5rem;
      font-size: 0.75rem;
      font-weight: 700;
      animation: pill-in 0.3s ease-out;
    }
    @keyframes pill-in {
      from { opacity: 0; transform: translateY(4px); }
      to { opacity: 1; transform: translateY(0); }
    }

    .thinking-text {
      font-style: italic;
      color: var(--muted-foreground);
      padding: 0.5rem 0.75rem;
      font-size: 0.85rem;
    }

    .retro-destructive {
      background: var(--destructive);
      color: var(--destructive-foreground);
      border: 3px solid var(--border);
      padding: 0.75rem 1rem;
    }

    .bubble-user { background: var(--muted); color: var(--muted-foreground); margin-left: 2rem; }
    .bubble-assistant { background: var(--card); color: var(--card-foreground); margin-right: 2rem; }

    .tool-row { display: flex; flex-wrap: wrap; gap: 0.35rem; margin-right: 2rem; }

    .waiting-dots { display: inline-flex; gap: 0.25rem; padding: 0.5rem 0.75rem; }
    .waiting-dots span {
      width: 0.4rem; height: 0.4rem; background: var(--muted-foreground);
      border-radius: 999px; animation: waiting-bounce 1s infinite ease-in-out;
    }
    .waiting-dots span:nth-child(2) { animation-delay: 0.15s; }
    .waiting-dots span:nth-child(3) { animation-delay: 0.3s; }
    @keyframes waiting-bounce {
      0%, 80%, 100% { transform: scale(0.6); opacity: 0.5; }
      40% { transform: scale(1); opacity: 1; }
    }

    /* Markdown rendering for assistant messages, matching planck_cli's chat-prose */
    .chat-prose { font-size: 0.925rem; line-height: 1.6; }
    .chat-prose > *:first-child { margin-top: 0; }
    .chat-prose > *:last-child { margin-bottom: 0; }
    .chat-prose p { margin: 0.35rem 0; }
    .chat-prose h1, .chat-prose h2, .chat-prose h3 {
      font-weight: 700; line-height: 1.25; margin: 0.75rem 0 0.25rem;
    }
    .chat-prose h1 { font-size: 1.2em; }
    .chat-prose h2 { font-size: 1.1em; }
    .chat-prose ul, .chat-prose ol { margin: 0.35rem 0; padding-left: 1.5rem; }
    .chat-prose ul { list-style-type: disc; }
    .chat-prose ol { list-style-type: decimal; }
    .chat-prose li { margin: 0.1rem 0; }
    .chat-prose a { color: var(--primary); text-decoration: underline; text-underline-offset: 2px; }
    .chat-prose strong { font-weight: 700; }
    .chat-prose blockquote {
      border-left: 3px solid var(--primary); padding: 0.1rem 0.75rem;
      margin: 0.5rem 0; color: var(--muted-foreground);
    }
    .chat-prose hr { border: none; border-top: 2px solid var(--border); margin: 0.75rem 0; }
    .chat-prose table { border-collapse: collapse; width: 100%; margin: 0.5rem 0; }
    .chat-prose th, .chat-prose td {
      border: 1px solid var(--border); padding: 0.25rem 0.5rem; text-align: left;
    }
    .chat-prose th { background: var(--muted); font-weight: 700; }
    .chat-prose :not(pre) > code {
      background: var(--muted); color: var(--primary); padding: 0.1em 0.35em;
      font-size: 0.88em; border: 1px solid var(--border);
    }
    .chat-prose pre {
      background: #1e2024; color: #abb2bf; border: 2px solid var(--border);
      padding: 0.75rem 1rem; overflow-x: auto; margin: 0.5rem 0;
      font-size: 0.82rem; line-height: 1.55;
    }
    .chat-prose pre code { background: transparent; color: inherit; padding: 0; border: none; font-size: inherit; }
  </style>
  """

  def css, do: Phoenix.HTML.raw(@css)
end

# [EXTERNAL API] (the mock flight-inventory side of it — see MockFlights below)
defmodule TravelAgent.FlightStore do
  @moduledoc """
  In-memory flight search results and reservations — the one piece of shared
  state that must live outside the LiveView process, since it's read and
  written from inside a tool's execute_fn, which runs in the Planck.Agent
  process, not the LiveView process.

  `flights` is keyed by flight_id and shared across visitors (harmless —
  flight_ids are content-addressed, and shared inventory is realistic).
  `reservations` is keyed by visitor_id (here, the LiveView's own socket.id).
  """
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{flights: %{}, reservations: %{}} end, name: __MODULE__)
  end

  def put_flights(flights) do
    Agent.update(__MODULE__, fn state ->
      new_flights = Map.new(flights, &{&1.flight_id, &1})
      %{state | flights: Map.merge(state.flights, new_flights)}
    end)
  end

  def reserve(visitor_id, flight_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.flights, flight_id) do
        nil ->
          {{:error, "reserve flight: #{flight_id} not found — search again"}, state}

        flight ->
          taken_by_other? =
            Enum.any?(state.reservations, fn {vid, r} ->
              vid != visitor_id and r.flight_id == flight_id
            end)

          if taken_by_other? do
            {{:error,
              "reserve flight: this flight was just booked by another traveler — search again for alternatives"},
             state}
          else
            code =
              :crypto.strong_rand_bytes(4) |> Base.encode32(padding: false) |> binary_part(0, 6)

            reservation = %{
              flight_id: flight_id,
              confirmation_code: code,
              reserved_at: DateTime.utc_now()
            }

            new_state = put_in(state.reservations[visitor_id], reservation)

            day_suffix =
              if flight.arrival_day_offset > 0, do: " (+#{flight.arrival_day_offset}d)", else: ""

            message =
              "Reserved! #{flight.airline} #{flight.origin} to #{flight.destination} on " <>
                "#{flight.departure_date}, departs #{flight.departure_time}, " <>
                "arrives #{flight.arrival_time}#{day_suffix}, #{flight.price} #{flight.currency}. " <>
                "Confirmation code: #{code}."

            {{:ok, message}, new_state}
          end
      end
    end)
  end
end

# [EXTERNAL API] Simulated — no free public flight-pricing API exists.
defmodule TravelAgent.MockFlights do
  @moduledoc """
  Deterministic simulated flight pricing — no free public flight-price API
  exists, so results are generated from a seed derived from the search
  arguments. The same (origin, destination, dates, budget) always returns
  the same flights, including stable flight_ids, so a flight_id quoted in
  one turn still resolves if the model re-searches later.
  """

  @airlines [
    "Meridian Air",
    "Aurora Skyways",
    "Northbound",
    "Pacific Gate",
    "Continental Loop",
    "Skyline Wings",
    "Westward",
    "Halcyon Air"
  ]

  @spec search(String.t(), String.t(), String.t(), String.t(), integer(), String.t()) :: [map()]
  def search(origin, destination, start_date, end_date, budget, currency) do
    key = {String.downcase(origin), String.downcase(destination), start_date, end_date, budget}
    a = :erlang.phash2(key, 4_294_967_296)
    b = :erlang.phash2({key, :b}, 4_294_967_296)
    c = :erlang.phash2({key, :c}, 4_294_967_296)

    # Functional seeding (seed_s/uniform_s), not seed/uniform — a tool's
    # execute_fn runs inside the agent process, and mutating that process's
    # global rand state as a side effect would be a surprising footgun.
    state = :rand.seed_s(:exsss, {a, b, c})

    base_duration = 2 + rem(a, 6)
    # Center prices around the caller's budget (70%-130%) so results are a
    # genuine trade-off instead of "everything fits" or "nothing fits".
    base_price = budget * (70 + rem(b, 61)) / 100
    span = date_span(start_date, end_date)

    {flights, _state} =
      Enum.map_reduce(0..3, state, fn index, acc ->
        {stop_roll, acc} = :rand.uniform_s(100, acc)
        stops = if stop_roll <= 60, do: 0, else: 1

        {duration_jitter, acc} = :rand.uniform_s(4, acc)
        duration_hours = base_duration + duration_jitter

        {price_roll, acc} = :rand.uniform_s(31, acc)
        jitter = (price_roll - 16) / 100
        price = round(base_price * (1 + jitter))

        {day_roll, acc} = :rand.uniform_s(span, acc)
        departure_date = shift_date(start_date, day_roll - 1)

        {minute_roll, acc} = :rand.uniform_s(24 * 60, acc)
        departure_minutes = minute_roll - 1
        arrival_minutes = departure_minutes + duration_hours * 60

        {airline_roll, acc} = :rand.uniform_s(length(@airlines), acc)
        airline = Enum.at(@airlines, airline_roll - 1)

        flight_id =
          "FL-" <>
            (:erlang.phash2({key, index}, 4_294_967_295)
             |> Integer.to_string(16)
             |> String.downcase())

        flight = %{
          flight_id: flight_id,
          airline: airline,
          origin: origin,
          destination: destination,
          departure_date: departure_date,
          departure_time: format_time(departure_minutes),
          arrival_time: format_time(rem(arrival_minutes, 24 * 60)),
          arrival_day_offset: div(arrival_minutes, 24 * 60),
          duration_hours: duration_hours,
          stops: stops,
          price: price,
          currency: currency
        }

        {flight, acc}
      end)

    flights
  end

  defp date_span(start_date, end_date) do
    s = Date.from_iso8601!(start_date)
    e = Date.from_iso8601!(end_date)
    max(Date.diff(e, s), 0) + 1
  end

  defp shift_date(start_date, offset) do
    start_date
    |> Date.from_iso8601!()
    |> Date.add(offset)
    |> Date.to_iso8601()
  end

  defp format_time(minutes_since_midnight) do
    h = div(minutes_since_midnight, 60) |> Integer.to_string() |> String.pad_leading(2, "0")
    m = rem(minutes_since_midnight, 60) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{h}:#{m}"
  end
end

# [EXTERNAL API] Real, keyless.
defmodule TravelAgent.OpenMeteo do
  @moduledoc "Open-Meteo's free, keyless geocoding + forecast APIs."

  @spec geocode(String.t()) :: {:ok, map()} | {:error, String.t()}
  def geocode(location) do
    case Req.get("https://geocoding-api.open-meteo.com/v1/search",
           params: [name: location, count: 1]
         ) do
      {:ok, %{status: 200, body: %{"results" => [result | _]}}} ->
        {:ok,
         %{
           lat: result["latitude"],
           lon: result["longitude"],
           name: result["name"],
           country: result["country"]
         }}

      {:ok, %{status: 200}} ->
        {:error, "get_weather: no location found matching #{inspect(location)}"}

      {:ok, %{status: status}} ->
        {:error, "get_weather: geocoding service returned status #{status}"}

      {:error, reason} ->
        {:error, "get_weather: geocoding request failed: #{inspect(reason)}"}
    end
  end

  @spec forecast(number(), number()) :: {:ok, String.t()} | {:error, String.t()}
  def forecast(lat, lon) do
    case Req.get("https://api.open-meteo.com/v1/forecast",
           params: [
             latitude: lat,
             longitude: lon,
             current: "temperature_2m,precipitation",
             timezone: "auto"
           ]
         ) do
      {:ok, %{status: 200, body: %{"current" => current}}} ->
        {:ok,
         "current temperature #{current["temperature_2m"]}°C, precipitation #{current["precipitation"]}mm"}

      {:ok, %{status: status}} ->
        {:error, "get_weather: forecast service returned status #{status}"}

      {:error, reason} ->
        {:error, "get_weather: forecast request failed: #{inspect(reason)}"}
    end
  end
end

# [EXTERNAL API] Real, keyless.
defmodule TravelAgent.RestCountries do
  @moduledoc "REST Countries' free, keyless country-facts API."

  @spec facts(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def facts(country_name) do
    url = "https://restcountries.com/v3.1/name/#{URI.encode(country_name)}"

    case Req.get(url, params: [fields: "name,currencies,languages,region"]) do
      {:ok, %{status: 200, body: [country | _]}} ->
        {:ok, format_country(country)}

      {:ok, %{status: 404}} ->
        {:error, "get_country_facts: no country found matching #{inspect(country_name)}"}

      {:ok, %{status: status}} ->
        {:error, "get_country_facts: service returned status #{status}"}

      {:error, reason} ->
        {:error, "get_country_facts: request failed: #{inspect(reason)}"}
    end
  end

  defp format_country(country) do
    name = country["name"]["common"]
    region = country["region"]

    currencies =
      (country["currencies"] || %{})
      |> Map.values()
      |> Enum.map_join(", ", & &1["name"])

    languages =
      (country["languages"] || %{})
      |> Map.values()
      |> Enum.join(", ")

    "#{name} (#{region}) — currency: #{currencies}; languages: #{languages}"
  end
end

# [PLANCK.AGENT] What this article is actually about: a Planck.Agent.Tool is
# just a name, a JSON-Schema parameter map, and a 3-arg execute_fn — nothing
# more. There's no registration step; you just put these in the `tools:`
# list you pass to Planck.Agent, below.
defmodule TravelAgent.Tools do
  @moduledoc "The four tools this demo's agent gets — nothing else. No delegation tools, no coding builtins, because we never asked Planck.Agent for any."

  alias Planck.Agent.Tool

  @spec build(String.t()) :: [Tool.t()]
  def build(visitor_id) do
    [get_weather(), get_country_facts(), search_flights(), reserve_flight(visitor_id)]
  end

  @spec get_weather() :: Tool.t()
  def get_weather do
    Tool.new(
      name: "get_weather",
      description:
        "Get current weather conditions for a city, to check whether it matches the " <>
          "traveler's desired climate right now.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "location" => %{"type" => "string", "description" => "City name, e.g. \"Lisbon\""}
        },
        "required" => ["location"]
      },
      execute_fn: fn _agent_id, _id, %{"location" => location} ->
        with {:ok, geo} <- TravelAgent.OpenMeteo.geocode(location),
             {:ok, summary} <- TravelAgent.OpenMeteo.forecast(geo.lat, geo.lon) do
          {:ok, "#{geo.name}, #{geo.country}: #{summary}"}
        end
      end
    )
  end

  @spec get_country_facts() :: Tool.t()
  def get_country_facts do
    Tool.new(
      name: "get_country_facts",
      description:
        "Get currency, languages, and region for a COUNTRY (not a city) — use this to " <>
          "caveat a destination recommendation.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "location" => %{"type" => "string", "description" => "Country name, e.g. \"Portugal\""}
        },
        "required" => ["location"]
      },
      execute_fn: fn _agent_id, _id, %{"location" => location} ->
        TravelAgent.RestCountries.facts(location)
      end
    )
  end

  @spec search_flights() :: Tool.t()
  def search_flights do
    Tool.new(
      name: "search_flights",
      description:
        "Search simulated flights between two cities within a date range and budget. " <>
          "Returns a handful of priced options.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "origin" => %{"type" => "string", "description" => "Departure city"},
          "destination" => %{"type" => "string", "description" => "Arrival city"},
          "start_date" => %{
            "type" => "string",
            "description" => "Earliest acceptable departure date, YYYY-MM-DD"
          },
          "end_date" => %{
            "type" => "string",
            "description" => "Latest acceptable departure date, YYYY-MM-DD"
          },
          "budget" => %{
            "type" => "integer",
            "description" => "Traveler's budget, as a number in the given currency"
          },
          "currency" => %{
            "type" => "string",
            "enum" => ["USD", "EUR", "GBP", "PLN"],
            "description" => "Currency the budget (and returned prices) are in"
          }
        },
        "required" => ["origin", "destination", "start_date", "end_date", "budget", "currency"]
      },
      execute_fn: fn _agent_id, _id, args ->
        %{
          "origin" => origin,
          "destination" => destination,
          "start_date" => start_date,
          "end_date" => end_date,
          "budget" => budget,
          "currency" => currency
        } = args

        flights =
          TravelAgent.MockFlights.search(
            origin,
            destination,
            start_date,
            end_date,
            budget,
            currency
          )

        TravelAgent.FlightStore.put_flights(flights)

        table =
          Enum.map_join(flights, "\n", fn f ->
            "- #{f.flight_id}: #{f.airline}, #{f.origin} to #{f.destination} on #{f.departure_date}, " <>
              "departs #{f.departure_time}, arrives #{f.arrival_time}#{arrival_day_suffix(f.arrival_day_offset)}, " <>
              "#{f.duration_hours}h, #{f.stops} stop(s), #{f.price} #{f.currency}"
          end)

        {:ok, table}
      end
    )
  end

  @spec reserve_flight(String.t()) :: Tool.t()
  def reserve_flight(visitor_id) do
    Tool.new(
      name: "reserve_flight",
      description: "Reserve a flight by its flight_id from a previous search_flights result.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "flight_id" => %{
            "type" => "string",
            "description" => "The flight_id from search_flights results, e.g. \"FL-a1b2c3\""
          }
        },
        "required" => ["flight_id"]
      },
      execute_fn: fn _agent_id, _id, %{"flight_id" => flight_id} ->
        TravelAgent.FlightStore.reserve(visitor_id, flight_id)
      end
    )
  end

  defp arrival_day_suffix(0), do: ""
  defp arrival_day_suffix(n), do: " (+#{n}d)"
end

# [PLANCK.AGENT] Just a string passed as `system_prompt:` — no template
# engine, no special format. Worth reading anyway: it's what tells the model
# which two things it still needs to ask for, since the booking form already
# covers the rest.
defmodule TravelAgent.SystemPrompt do
  @moduledoc "The agent's persona and interview flow."

  @spec text() :: String.t()
  def text do
    """
    You are a solo travel-planning agent. You work completely alone: there is
    no team, and none of your tools exist to talk to other agents.

    The traveler's first message already states their budget, currency,
    travel date range, and party size (adults and children) — it comes from
    a booking form they filled in before this conversation started. Do not
    ask them for any of that again. Acknowledge it briefly, then interview
    them conversationally for the two things the form didn't collect:
    - their desired climate or weather for the trip
    - their home city (the departure point for flights)

    Once you have both, propose two to four candidate destinations from your
    own knowledge that plausibly match their desired climate for those
    dates. For each serious candidate, call get_weather to confirm current
    conditions actually match, and get_country_facts — passing the COUNTRY
    name, not the city — to learn currency and language so you can caveat
    the recommendation.

    Once the traveler narrows it down to a destination, call search_flights
    with their origin, that destination, their date range, their budget, and
    their currency (exactly as given — do not convert it). Present the
    results plainly, noting which are within budget for the whole party.

    When the traveler chooses a flight, call reserve_flight with its
    flight_id and relay the confirmation code back to them.

    Be concise and conversational. Never invent flight prices or weather —
    always use the tools for those.
    """
  end
end

# [PLANCK.AGENT] The other half of "no planck_headless": a %Planck.AI.Model{}
# is a plain struct you build yourself from whatever config UI you want —
# there's no config.json format to match, no provider registry to update.
defmodule TravelAgent.ModelConfig do
  @moduledoc """
  Builds a %Planck.AI.Model{} directly from the config form — no
  planck_headless, no config.json. Planck.AI reads provider API keys from
  plain OS env vars at request time (see Planck.AI.Adapter.resolve_api_key/1
  — a fresh System.get_env/1 call, never cached), so setting them here is
  enough; no reload step exists or is needed.
  """

  alias Planck.AI.Model

  # Generic fallback context/output limits — we don't have per-model metadata
  # for an arbitrary model id the visitor typed, so these just need to be
  # large enough not to trip the agent's own context-compaction threshold.
  @context_window 128_000
  @max_tokens 8_192

  @spec build(map()) :: {:ok, Model.t()} | {:error, String.t()}
  def build(params) do
    case params["provider"] do
      p when p in ["anthropic", "openai", "google"] ->
        set_api_key_env(p, blank_to_nil(params["api_key"]))

        {:ok,
         %Model{
           id: params["model"],
           model: params["model"],
           name: params["model"],
           provider: String.to_existing_atom(p),
           context_window: @context_window,
           max_tokens: @max_tokens
         }}

      "local" ->
        {:ok,
         %Model{
           id: params["model"],
           model: params["model"],
           name: params["model"],
           provider: :openai,
           base_url: blank_to_nil(params["base_url"]),
           identifier: blank_to_nil(params["identifier"]),
           has_api_key: false,
           context_window: @context_window,
           max_tokens: @max_tokens
         }}

      _ ->
        {:error, "unknown provider selection"}
    end
  end

  defp set_api_key_env(_provider, nil), do: :ok
  defp set_api_key_env("anthropic", key), do: System.put_env("ANTHROPIC_API_KEY", key)
  defp set_api_key_env("openai", key), do: System.put_env("OPENAI_API_KEY", key)
  defp set_api_key_env("google", key), do: System.put_env("GOOGLE_API_KEY", key)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end

# [BOILERPLATE] Display concern, not Planck-specific.
defmodule TravelAgent.Markdown do
  @moduledoc "Server-side markdown rendering, matching planck_cli's own chat_component.ex."

  @spec render_message(Planck.Agent.Message.t()) :: Phoenix.HTML.safe()
  def render_message(message) do
    text =
      message.content
      |> Enum.flat_map(fn
        {:text, t} -> [t]
        _ -> []
      end)
      |> Enum.join("")

    # MDEx's default sanitization escapes raw HTML in the source rather than
    # passing it through — tool/API output can never inject a live <script>
    # tag into the page this way.
    case MDEx.to_html(text, extension: [table: true, autolink: true], render: [hardbreaks: true]) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      {:error, _} -> Phoenix.HTML.html_escape(text)
    end
  end
end

# [PLANCK.AGENT + BOILERPLATE] This module is genuinely mixed — a LiveView
# needs mount/render/event-handling regardless of what it talks to
# underneath, so each function below is tagged individually. The three that
# matter most for this article are start_agent/1, the handle_info clauses,
# and the "submit_trip"/"send" handle_event clauses — that's the entire
# Planck.Agent integration in one file.
defmodule TravelAgent.ChatLive do
  @moduledoc """
  The whole app is one LiveView: a three-phase wizard (:configure -> :trip ->
  :chat) held entirely in socket assigns, no separate pages, no cookies, no
  visitor-store. Each browser tab gets its own LiveView process, and that
  process starts exactly one Planck.Agent GenServer for its own conversation
  once the trip form is submitted — no session persistence, no config files.
  """
  use Phoenix.LiveView, layout: {__MODULE__, :live}

  alias Planck.Agent

  # [BOILERPLATE] Wizard state lives in plain assigns — no separate pages,
  # cookies, or process dictionary needed.
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:phase, :configure)
     |> assign(:provider, "anthropic")
     |> assign(:model, nil)
     |> assign(:agent_pid, nil)
     |> assign(:messages, [])
     |> assign(:thinking, false)
     |> assign(:streaming_text, nil)
     |> assign(:current_tools, [])
     |> assign(:generating, false)
     |> assign(:input_key, 0)
     |> assign(:config_error, nil)
     |> assign(:trip_error, nil)}
  end

  # [BOILERPLATE] Pure UI state — which fields the config form currently shows.
  @impl true
  def handle_event("provider_changed", params, socket) do
    {:noreply, assign(socket, :provider, params["provider"] || socket.assigns.provider)}
  end

  # [PLANCK.AGENT] Builds the %Planck.AI.Model{} the agent will use — see
  # TravelAgent.ModelConfig above.
  def handle_event("configure", params, socket) do
    case TravelAgent.ModelConfig.build(params) do
      {:ok, model} ->
        {:noreply, assign(socket, model: model, phase: :trip, config_error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :config_error, reason)}
    end
  end

  # [PLANCK.AGENT] Starts the agent (start_agent/1, below) and sends its
  # first prompt — the trip-form fields become the agent's opening context
  # instead of the first thing it has to ask the traveler for.
  def handle_event("submit_trip", params, socket) do
    travelers =
      case String.to_integer(params["children"] || "0") do
        0 -> "#{params["adults"]} adult(s)"
        n -> "#{params["adults"]} adult(s), #{n} child(ren)"
      end

    message =
      "Trip details from the booking form: budget #{params["budget"]} #{params["currency"]}; " <>
        "travelers: #{travelers}; travel dates: #{params["start_date"]} to #{params["end_date"]}."

    case start_agent(socket) do
      {:ok, pid} ->
        Agent.prompt(pid, message)

        {:noreply,
         assign(socket, agent_pid: pid, phase: :chat, generating: true, trip_error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :trip_error, inspect(reason))}
    end
  end

  # [PLANCK.AGENT] Agent.prompt/2 is the entire "send a message" call.
  # Guarded by `disabled={@generating}` on the input/button in the template,
  # so this only fires once the previous turn has actually finished — the
  # traveler can't queue a second message mid-generation.
  def handle_event("send", %{"text" => text}, socket) when text != "" do
    Agent.prompt(socket.assigns.agent_pid, text)

    {:noreply,
     socket
     |> assign(:messages, socket.assigns.messages ++ [%{role: :user, text: text}])
     |> assign(generating: true, input_key: socket.assigns.input_key + 1)}
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  # [BOILERPLATE] UI reset, plus stop_agent/1 (below) to avoid leaking the
  # old agent process.
  def handle_event("reset", _params, socket) do
    stop_agent(socket.assigns.agent_pid)

    {:noreply,
     assign(socket,
       phase: :configure,
       agent_pid: nil,
       messages: [],
       thinking: false,
       streaming_text: nil,
       current_tools: [],
       generating: false,
       config_error: nil,
       trip_error: nil
     )}
  end

  # [PLANCK.AGENT] This block — reacting to {:agent_event, type, payload}
  # messages — is the other half of the integration, alongside
  # start_agent/1. `generating` is set once, in "send"/"submit_trip" above,
  # and cleared once, in :turn_end/:error below — it stays true for the
  # agent's whole turn (tool calls included), not just until the first
  # token arrives, so the input stays disabled for the full duration of
  # "the agent is working." Tool calls the model makes together run
  # concurrently in Planck.Agent (see its moduledoc), so their :tool_start
  # events can arrive within the same instant — the fade-in animation on
  # .retro-pill (see Theme) is what makes each one still read as a distinct
  # step rather than a single row popping in all at once.
  @impl true
  def handle_info({:agent_event, :turn_start, _payload}, socket) do
    {:noreply, assign(socket, thinking: false, current_tools: [])}
  end

  # We don't show the actual reasoning text — just that reasoning is
  # happening right now. Cleared as soon as a tool call or visible text
  # starts (below), and set again if the model interleaves more thinking
  # after that.
  def handle_info({:agent_event, :thinking_delta, _payload}, socket) do
    {:noreply, assign(socket, :thinking, true)}
  end

  def handle_info({:agent_event, :text_delta, %{text: text}}, socket) do
    current = socket.assigns.streaming_text || ""
    {:noreply, assign(socket, thinking: false, streaming_text: current <> text)}
  end

  def handle_info({:agent_event, :tool_start, %{name: name}}, socket) do
    {:noreply,
     assign(socket, thinking: false, current_tools: socket.assigns.current_tools ++ [name])}
  end

  def handle_info({:agent_event, :turn_end, payload}, socket) do
    entry = %{
      role: :assistant,
      html: TravelAgent.Markdown.render_message(payload.message),
      tools: socket.assigns.current_tools
    }

    {:noreply,
     socket
     |> assign(:messages, socket.assigns.messages ++ [entry])
     |> assign(thinking: false, streaming_text: nil, current_tools: [], generating: false)}
  end

  def handle_info({:agent_event, :error, %{reason: reason}}, socket) do
    entry = %{role: :error, text: inspect(reason)}

    {:noreply,
     socket
     |> assign(:messages, socket.assigns.messages ++ [entry])
     |> assign(thinking: false, streaming_text: nil, generating: false)}
  end

  def handle_info({:agent_event, _type, _payload}, socket), do: {:noreply, socket}

  # [PLANCK.AGENT] Each LiveView process owns exactly one agent — clean it
  # up when the socket disconnects (tab closed, page reloaded) so agents
  # don't pile up as visitors come and go.
  @impl true
  def terminate(_reason, socket) do
    stop_agent(socket.assigns[:agent_pid])
    :ok
  end

  # [PLANCK.AGENT] The actual embedding, in three lines: subscribe to this
  # agent's events by the id we're about to give it, then start it under
  # Planck.Agent.AgentSupervisor with our tools/system_prompt/model. No
  # team, no session_id, no cwd — just an agent.
  defp start_agent(socket) do
    Agent.subscribe(socket.id)

    DynamicSupervisor.start_child(
      Agent.AgentSupervisor,
      {Agent,
       id: socket.id,
       model: socket.assigns.model,
       system_prompt: TravelAgent.SystemPrompt.text(),
       tools: TravelAgent.Tools.build(socket.id)}
    )
  end

  defp stop_agent(nil), do: :ok

  defp stop_agent(pid) do
    if Process.alive?(pid) do
      DynamicSupervisor.terminate_child(Agent.AgentSupervisor, pid)
    end

    :ok
  end

  # [BOILERPLATE] Cosmetic — just a placeholder hint in the model field.
  defp model_placeholder("anthropic"), do: "claude-sonnet-4-5"
  defp model_placeholder("openai"), do: "gpt-5.1"
  defp model_placeholder("google"), do: "gemini-3-pro"
  defp model_placeholder(_), do: "llama3.2"

  # [BOILERPLATE] Pin the CDN script URLs to whatever version Mix.install
  # actually resolved, so they never drift out of sync with each other.
  defp phx_vsn, do: Application.spec(:phoenix, :vsn)
  defp lv_vsn, do: Application.spec(:phoenix_live_view, :vsn)

  # [BOILERPLATE] Layout — loads Phoenix/LiveView from CDN (no asset
  # pipeline exists in a script) and Tailwind's CDN JIT compiler for layout
  # utilities; RetroUI's color tokens are plain CSS, so Tailwind never needs
  # to know about them.
  def render("live.html", assigns) do
    ~H"""
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>Travel Agent Demo</title>
      <script src="https://cdn.tailwindcss.com"></script>
      <script src={"https://cdn.jsdelivr.net/npm/phoenix@#{phx_vsn()}/priv/static/phoenix.min.js"}>
      </script>
      <script src={"https://cdn.jsdelivr.net/npm/phoenix_live_view@#{lv_vsn()}/priv/static/phoenix_live_view.min.js"}>
      </script>
      <script>
        let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket)
        liveSocket.connect()
      </script>
      <%= TravelAgent.Theme.css() %>
    </head>
    <body class="min-h-screen flex flex-col">
      <header class="max-w-2xl mx-auto mt-4 p-4 retro-card w-full">
        <div class="font-bold text-lg">Travel Agent Demo</div>
        <div class="text-sm" style="color: var(--muted-foreground)">
          Your AI travel companion — one tool call at a time.
        </div>
      </header>
      <main class="max-w-2xl mx-auto p-4 flex-1 w-full">
        <%= @inner_content %>
      </main>
      <footer class="max-w-2xl mx-auto p-4 w-full text-center text-sm" style="color: var(--muted-foreground)">
        Travel Agent Demo — a planck_agent example, part of the Building Planck series.
      </footer>
    </body>
    </html>
    """
  end

  # [BOILERPLATE] Markup for the three wizard phases. It reads
  # Planck.Agent-sourced data (@messages, @current_tools, @streaming_text)
  # but the markup itself has nothing to do with Planck — it's the same
  # HEEx you'd write for any LiveView chat UI.
  @impl true
  def render(assigns) do
    ~H"""
    <div class="retro-card p-6">
      <%= if @phase == :configure do %>
        <h1 class="text-xl font-bold mb-4">Set up your travel agent</h1>
        <div :if={@config_error} class="retro-destructive mb-4"><%= @config_error %></div>

        <form phx-change="provider_changed" phx-submit="configure" class="flex flex-col gap-4">
          <fieldset class="flex flex-col gap-2">
            <legend class="font-bold mb-1">Provider</legend>
            <label class="flex items-center gap-2">
              <input type="radio" name="provider" value="anthropic" checked={@provider == "anthropic"} /> Anthropic
            </label>
            <label class="flex items-center gap-2">
              <input type="radio" name="provider" value="openai" checked={@provider == "openai"} /> OpenAI
            </label>
            <label class="flex items-center gap-2">
              <input type="radio" name="provider" value="google" checked={@provider == "google"} /> Gemini
            </label>
            <label class="flex items-center gap-2">
              <input type="radio" name="provider" value="local" checked={@provider == "local"} /> Local (no API key)
            </label>
          </fieldset>

          <label :if={@provider in ["anthropic", "openai", "google"]} class="flex flex-col gap-1">
            API key
            <input type="password" name="api_key" class="retro-input" />
          </label>

          <label :if={@provider == "local"} class="flex flex-col gap-1">
            Base URL
            <input type="text" name="base_url" class="retro-input" placeholder="http://localhost:11434/v1" />
          </label>

          <label :if={@provider == "local"} class="flex flex-col gap-1">
            Identifier (optional)
            <input type="text" name="identifier" class="retro-input" placeholder="local" />
          </label>

          <label class="flex flex-col gap-1">
            Model
            <input type="text" name="model" class="retro-input" required placeholder={model_placeholder(@provider)} />
          </label>

          <button type="submit" class="retro-btn">Next</button>
        </form>
      <% end %>

      <%= if @phase == :trip do %>
        <h1 class="text-xl font-bold mb-4">Tell us about your trip</h1>
        <div :if={@trip_error} class="retro-destructive mb-4"><%= @trip_error %></div>

        <form phx-submit="submit_trip" class="flex flex-col gap-4">
          <div class="flex gap-2">
            <label class="flex flex-col gap-1 flex-1">
              Budget
              <input type="number" name="budget" class="retro-input" min="1" required value="1500" />
            </label>
            <label class="flex flex-col gap-1" style="width: 6rem">
              Currency
              <select name="currency" class="retro-input">
                <option value="USD">USD</option>
                <option value="EUR">EUR</option>
                <option value="GBP">GBP</option>
                <option value="PLN">PLN</option>
              </select>
            </label>
          </div>

          <div class="flex gap-2">
            <label class="flex flex-col gap-1 flex-1">
              Adults
              <input type="number" name="adults" class="retro-input" min="1" required value="1" />
            </label>
            <label class="flex flex-col gap-1 flex-1">
              Children
              <input type="number" name="children" class="retro-input" min="0" required value="0" />
            </label>
          </div>

          <div class="flex gap-2">
            <label class="flex flex-col gap-1 flex-1">
              From
              <input type="date" name="start_date" class="retro-input" required />
            </label>
            <label class="flex flex-col gap-1 flex-1">
              To
              <input type="date" name="end_date" class="retro-input" required />
            </label>
          </div>

          <button type="submit" class="retro-btn">Next</button>
        </form>
      <% end %>

      <%= if @phase == :chat do %>
        <div class="flex flex-col gap-4">
          <div class="flex flex-col gap-2" style="min-height: 300px; max-height: 60vh; overflow-y: auto;">
            <%= for msg <- @messages do %>
              <%= case msg.role do %>
                <% :user -> %>
                  <div class="retro-card p-2 bubble-user"><%= msg.text %></div>
                <% :assistant -> %>
                  <div :if={msg.tools != []} class="tool-row">
                    <%= for tool <- msg.tools do %>
                      <span class="retro-pill">using tool: <%= tool %></span>
                    <% end %>
                  </div>
                  <div class="retro-card p-2 bubble-assistant chat-prose"><%= msg.html %></div>
                <% :error -> %>
                  <div class="retro-destructive"><%= msg.text %></div>
              <% end %>
            <% end %>

            <div :if={@current_tools != []} class="tool-row">
              <%= for tool <- @current_tools do %>
                <span class="retro-pill">using tool: <%= tool %></span>
              <% end %>
            </div>

            <div :if={@streaming_text} class="retro-card p-2 bubble-assistant"><%= @streaming_text %></div>

            <div :if={@thinking} class="thinking-text">Thinking...</div>

            <div
              :if={@generating && !@thinking && @streaming_text == nil && @current_tools == []}
              class="waiting-dots"
            >
              <span></span><span></span><span></span>
            </div>
          </div>

          <form phx-submit="send" class="flex gap-2">
            <input
              type="text"
              name="text"
              id={"chat-input-#{@input_key}"}
              class="retro-input flex-1"
              placeholder={if @generating, do: "Waiting for a reply...", else: "Type a message..."}
              autocomplete="off"
              disabled={@generating}
            />
            <button type="submit" class="retro-btn" disabled={@generating}>Send</button>
          </form>

          <button phx-click="reset" class="text-sm underline" style="background:none;border:none;padding:0;cursor:pointer;">
            Start over
          </button>
        </div>
      <% end %>
    </div>
    """
  end
end

# [BOILERPLATE] Standard Phoenix router — one LiveView route, nothing else.
defmodule TravelAgent.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
  end

  scope "/", TravelAgent do
    pipe_through(:browser)

    live("/", ChatLive, :index)
  end
end

# [BOILERPLATE] Standard Phoenix endpoint.
defmodule TravelAgent.Endpoint do
  use Phoenix.Endpoint, otp_app: :travel_agent

  socket("/live", Phoenix.LiveView.Socket)

  plug(TravelAgent.Router)
end

# [BOILERPLATE] Boot. Planck.Agent's own supervision tree (AgentSupervisor,
# Registry, PubSub) is already running by this point — Mix.install started
# it along with every other resolved OTP application.
{:ok, _} = TravelAgent.FlightStore.start_link([])
{:ok, _} = Supervisor.start_link([TravelAgent.Endpoint], strategy: :one_for_one)

IO.puts("Travel agent demo running at http://localhost:8000")
Process.sleep(:infinity)
