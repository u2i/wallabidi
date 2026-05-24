defmodule Wallabidi.Remote.Cookies do
  @moduledoc false

  # Shared helpers for cookie-attribute normalization across CDP and BiDi.
  #
  # The two protocols accept identical conceptual cookies but disagree on
  # wire casing — CDP's `Network.setCookie` wants `sameSite: "Strict" | "Lax"
  # | "None"` (PascalCase), W3C WebDriver-BiDi's `storage.setCookie` wants
  # `sameSite: "strict" | "lax" | "none"` (lowercase). Callers shouldn't
  # have to know which client they're talking to.
  #
  # `attr/2,3` reads an attribute by either atom or string key (and
  # additionally `:same_site` snake_case for sameSite), letting callers
  # use whichever form is natural.

  @doc """
  Look up an attribute under either an atom key or its string equivalent.
  Returns `default` (or nil) when neither key is present.
  """
  @spec attr(map, atom, term) :: term
  def attr(attrs, key, default \\ nil) when is_atom(key) do
    case Map.get(attrs, key) do
      nil -> Map.get(attrs, Atom.to_string(key), default)
      v -> v
    end
  end

  @doc """
  Extract the `sameSite` value from a cookie attributes map, normalized to
  the requested wire style. Returns `nil` when no sameSite attribute is set.

  Accepts the attribute under any of `:sameSite`, `"sameSite"`,
  `:same_site`, or `"same_site"`. Accepts the value as atom or string in
  any casing.
  """
  @spec same_site(map, :pascal | :lower) :: String.t() | nil
  def same_site(attrs, style) do
    case Map.get(attrs, :sameSite) || Map.get(attrs, "sameSite") ||
           Map.get(attrs, :same_site) || Map.get(attrs, "same_site") do
      nil -> nil
      v -> coerce_same_site(v, style)
    end
  end

  defp coerce_same_site(v, style) when is_atom(v),
    do: coerce_same_site(Atom.to_string(v), style)

  defp coerce_same_site(v, style) when is_binary(v) do
    case {String.downcase(v), style} do
      {"strict", :pascal} -> "Strict"
      {"strict", :lower} -> "strict"
      {"lax", :pascal} -> "Lax"
      {"lax", :lower} -> "lax"
      {"none", :pascal} -> "None"
      {"none", :lower} -> "none"
      _ -> v
    end
  end

  defp coerce_same_site(v, _style), do: v

  @doc """
  Normalize a wire-shape cookie to wallabidi's canonical shape.

  Both clients return cookies as user-facing maps with string keys
  (`"name"`, `"value"`, `"path"`, etc.). This:
    * unwraps BiDi's `value: %{"type" => "string", "value" => v}` shape
      to a flat string when present, leaves CDP's flat value alone
    * translates `expires` (CDP, Unix seconds, -1 for session cookies)
      to `expiry` (WebDriver, Unix seconds, omitted for session cookies)

  Passes other keys through unchanged so caller-visible attributes
  like `sameSite` survive the round-trip.
  """
  @spec normalize_returned_cookie(map) :: map
  def normalize_returned_cookie(cookie) when is_map(cookie) do
    cookie
    |> unwrap_value()
    |> expires_to_expiry()
  end

  defp unwrap_value(%{"value" => %{"value" => v}} = cookie),
    do: Map.put(cookie, "value", v)

  defp unwrap_value(cookie), do: cookie

  defp expires_to_expiry(cookie) do
    case Map.pop(cookie, "expires") do
      {nil, c} -> c
      {-1, c} -> c
      {expires, c} when is_number(expires) -> Map.put(c, "expiry", trunc(expires))
      {_, c} -> c
    end
  end
end
