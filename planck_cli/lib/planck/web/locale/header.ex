defmodule Planck.Web.Locale.Header do
  @moduledoc """
  Accept-Language header parsing for locale detection.
  """

  @typedoc "A parsed locale with a language tag and optional subtags."
  @type locale :: %{
          required(:language) => binary(),
          required(:tags) => [binary()]
        }

  @doc "Returns the best matching locale from the conn, given a list of offered locales."
  @spec client_locale(Plug.Conn.t(), [locale()]) :: [locale()]
  def client_locale(%Plug.Conn{} = conn, offered) do
    conn
    |> get_accept_language()
    |> locale()
    |> set_default(offered)
  end

  @doc "Parses an Accept-Language header string into a weighted, sorted list of locales."
  @spec locale(binary()) :: [locale()]
  def locale(contents) do
    regex =
      ~r/(?<language>(\*|[a-z]{2,3}(-([a-z0-9]{2,})+)*))\s*(;\s*q\s*=\s*(?<weight>(1(\.0)?|0\.[0-9]+)))?/

    contents
    |> String.downcase()
    |> String.split(~r/,/)
    |> Stream.map(&Regex.named_captures(regex, &1))
    |> Stream.map(&weight_to_number/1)
    |> Stream.map(&language_to_locale/1)
    |> Enum.sort_by(& &1["weight"], :desc)
    |> Enum.map(& &1["language"])
  end

  @doc "Returns the best match from `requested` that appears in `offered`."
  @spec merge([locale()], [locale()]) :: binary()
  def merge(requested, offered) do
    requested
    |> Stream.map(&stronger_locale(&1, offered))
    |> Stream.filter(&(not is_nil(&1)))
    |> Stream.map(&[&1.language | &1.tags])
    |> Stream.map(&Enum.join(&1, "-"))
    |> Enum.at(0)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec get_accept_language(Plug.Conn.t()) :: binary()
  defp get_accept_language(%Plug.Conn{} = conn) do
    [parameters_locale(conn), header_locale(conn)]
    |> Stream.reject(&(&1 == ""))
    |> Enum.reject(&(&1 == "*"))
    |> case do
      [] -> "*"
      [_ | _] = locales -> Enum.join(locales, ", ")
    end
  end

  @spec parameters_locale(Plug.Conn.t()) :: binary()
  defp parameters_locale(%Plug.Conn{} = conn) do
    conn |> Map.get(:params, %{}) |> Map.get("locale", "")
  end

  @spec header_locale(Plug.Conn.t()) :: binary()
  defp header_locale(%Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "accept-language") do
      [header | _] when header != "" -> header
      _ -> "*"
    end
  end

  @spec set_default([locale()], [locale()]) :: [locale()]
  defp set_default(requested, [default | _rest]) do
    requested
    |> Kernel.++([default])
    |> Stream.map(&if &1.language == "*", do: default, else: &1)
    |> Enum.uniq()
  end

  @spec weight_to_number(map()) :: map()
  defp weight_to_number(%{"weight" => ""} = locale),
    do: weight_to_number(%{locale | "weight" => "1.0"})

  defp weight_to_number(%{"weight" => "1"} = locale),
    do: weight_to_number(%{locale | "weight" => "1.0"})

  defp weight_to_number(%{"weight" => weight} = locale) do
    weight = weight |> :erlang.binary_to_float() |> Kernel.*(100) |> trunc()
    %{locale | "weight" => weight}
  end

  defp weight_to_number(_), do: weight_to_number(%{"weight" => "1.0"})

  @spec language_to_locale(map()) :: map()
  defp language_to_locale(%{"language" => language} = locale) do
    [lang | tags] = String.split(language, ~r/-/)
    %{locale | "language" => %{language: lang, tags: tags}}
  end

  defp language_to_locale(other) do
    other |> Map.put("language", "*") |> language_to_locale()
  end

  @spec stronger_locale(locale(), [locale()]) :: locale() | nil
  defp stronger_locale(requested, offered) do
    offered |> Enum.filter(&locale_match?(requested, &1)) |> List.first()
  end

  @spec locale_match?(locale(), locale()) :: boolean()
  defp locale_match?(%{language: l, tags: t}, %{language: l, tags: t}), do: true
  defp locale_match?(%{language: l}, %{language: l}), do: true
  defp locale_match?(_, _), do: false
end
