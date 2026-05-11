#!/usr/bin/env elixir

# Reads a perf-matrix TSV and writes priv/perf-matrix.svg.
#
# Plots per-test wall time (wall_seconds / tests) at each mc level,
# one line per driver. Same shape as the previous hand-built SVG so
# the README image embed keeps working.
#
# Usage:
#
#     elixir bench/render_perf_matrix.exs                       # default: bench/perf_bench_matrix.tsv
#     elixir bench/render_perf_matrix.exs bench/perf_matrix.tsv # explicit input

defmodule RenderPerfMatrix do
  @default_tsv "bench/perf_bench_matrix.tsv"
  @svg_path "priv/perf-matrix.svg"

  # Chart geometry — kept identical to the previous SVG so the README
  # embed (which sets a fixed viewBox/width/height) stays aligned.
  @width 720
  @height 420
  @plot_left 70
  @plot_right 540
  @plot_top 30
  @plot_bottom 370
  @mc_levels [1, 2, 4, 8, 16]

  # Order matters: legend rendering and color assignment match this.
  # Add new drivers at the end so existing colors stay stable.
  @driver_colors [
    {"Wallaby", "#ef4444"},
    {"Chrome BiDi", "#7c3aed"},
    {"Chrome CDP", "#2563eb"},
    {"Lightpanda", "#10b981"},
    {"LiveView", "#f59e0b"}
  ]

  def run(tsv_path \\ @default_tsv) do
    rows = parse_tsv(tsv_path)
    by_driver = group_rows(rows)
    max_per_test = max_per_test_seconds(rows)
    svg = render(by_driver, max_per_test)
    File.write!(@svg_path, svg)
    IO.puts("Wrote #{@svg_path} (#{byte_size(svg)} bytes) from #{tsv_path}")
  end

  defp parse_tsv(tsv_path) do
    tsv_path
    |> File.stream!()
    |> Stream.drop(1)
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      [driver, mc, wall, tests, _failures] = String.split(line, "\t")
      mc = String.to_integer(mc)
      wall = String.to_integer(wall)
      tests = String.to_integer(tests)
      {driver, mc, wall, tests}
    end)
  end

  defp group_rows(rows) do
    rows
    |> Enum.group_by(fn {d, _, _, _} -> d end, fn {_, mc, wall, tests} ->
      {mc, wall / max(tests, 1)}
    end)
  end

  defp max_per_test_seconds(rows) do
    rows
    |> Enum.map(fn {_, _, wall, tests} -> wall / max(tests, 1) end)
    |> Enum.max(fn -> 1.0 end)
  end

  defp render(by_driver, max_per_test) do
    # Round max up to a friendly tick. e.g. 3.39s → 4.0s, 0.85s → 1.0s.
    y_max = ceil_to_friendly(max_per_test)
    y_ticks = build_y_ticks(y_max)
    x_for = build_x_scale()
    y_for = build_y_scale(y_max)

    body = [
      ~s'<rect width="#{@width}" height="#{@height}" fill="white"/>\n',
      title(),
      axes(),
      x_axis_ticks(x_for),
      x_axis_label(),
      y_axis_ticks(y_ticks, y_for),
      y_axis_label(),
      lines_and_dots(by_driver, x_for, y_for),
      legend()
    ]

    [
      ~s'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@width} #{@height}" width="#{@width}" height="#{@height}" font-family="-apple-system, system-ui, sans-serif">\n',
      body,
      "</svg>\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp ceil_to_friendly(v) when v <= 1.0, do: 1.0
  defp ceil_to_friendly(v) when v <= 2.0, do: 2.0
  defp ceil_to_friendly(v) when v <= 3.0, do: 3.0
  defp ceil_to_friendly(v) when v <= 4.0, do: 4.0
  defp ceil_to_friendly(v) when v <= 5.0, do: 5.0
  defp ceil_to_friendly(v), do: Float.ceil(v) * 1.0

  defp build_y_ticks(y_max) do
    # 5 evenly-spaced ticks 0..y_max.
    step = y_max / 4
    for i <- 0..4, do: i * step
  end

  defp build_x_scale do
    # mc 1,2,4,8,16 -> evenly spaced 70..540 (5 points).
    plot_w = @plot_right - @plot_left

    Enum.zip(@mc_levels, 0..4)
    |> Map.new(fn {mc, i} -> {mc, @plot_left + i * plot_w / 4} end)
  end

  defp build_y_scale(y_max) do
    # y=0 -> @plot_bottom (370), y=y_max -> @plot_top (30).
    plot_h = @plot_bottom - @plot_top

    fn val ->
      frac = val / y_max
      @plot_bottom - frac * plot_h
    end
  end

  defp title do
    ~s'<text x="70" y="20" font-size="14" font-weight="600" fill="#111">Per-test wall time vs --max-cases</text>\n'
  end

  defp axes do
    [
      ~s'<line x1="#{@plot_left}" y1="#{@plot_top}" x2="#{@plot_left}" y2="#{@plot_bottom}" stroke="#999" stroke-width="1"/>\n',
      ~s'<line x1="#{@plot_left}" y1="#{@plot_bottom}" x2="#{@plot_right}" y2="#{@plot_bottom}" stroke="#999" stroke-width="1"/>\n'
    ]
  end

  defp x_axis_ticks(x_for) do
    for mc <- @mc_levels do
      x = Map.fetch!(x_for, mc)

      [
        ~s'<line x1="#{x}" y1="#{@plot_bottom}" x2="#{x}" y2="#{@plot_bottom + 5}" stroke="#999"/>\n',
        ~s'<text x="#{x}" y="#{@plot_bottom + 22}" text-anchor="middle" font-size="11" fill="#444">#{mc}</text>\n'
      ]
    end
  end

  defp x_axis_label do
    mid_x = (@plot_left + @plot_right) / 2
    ~s'<text x="#{mid_x}" y="#{@plot_bottom + 40}" text-anchor="middle" font-size="12" fill="#222">--max-cases</text>\n'
  end

  defp y_axis_ticks(ticks, y_for) do
    for v <- ticks do
      y = y_for.(v)
      label = "#{format_seconds(v)}s"

      [
        ~s'<line x1="#{@plot_left - 5}" y1="#{y}" x2="#{@plot_left}" y2="#{y}" stroke="#999"/>\n',
        ~s'<text x="#{@plot_left - 8}" y="#{y + 4}" text-anchor="end" font-size="11" fill="#444">#{label}</text>\n'
      ]
    end
  end

  defp y_axis_label do
    mid_y = (@plot_top + @plot_bottom) / 2

    ~s'<text x="20" y="#{mid_y}" text-anchor="middle" font-size="12" fill="#222" transform="rotate(-90 20 #{mid_y})">seconds per test</text>\n'
  end

  defp format_seconds(v) do
    :erlang.float_to_binary(v * 1.0, decimals: 2)
  end

  defp lines_and_dots(by_driver, x_for, y_for) do
    for {driver, color} <- @driver_colors do
      points = Map.get(by_driver, driver, [])

      pts =
        points
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {mc, per_test} ->
          {Map.get(x_for, mc), y_for.(per_test)}
        end)
        |> Enum.reject(fn {x, _} -> is_nil(x) end)

      case pts do
        [] ->
          ""

        _ ->
          path_d =
            pts
            |> Enum.with_index()
            |> Enum.map(fn {{x, y}, i} ->
              cmd = if i == 0, do: "M", else: " L"
              "#{cmd}#{x},#{y}"
            end)
            |> Enum.join("")

          dots =
            pts
            |> Enum.map(fn {x, y} ->
              ~s'<circle cx="#{x}" cy="#{y}" r="3.5" fill="#{color}"/>\n'
            end)

          [
            ~s'<path d="#{path_d}" stroke="#{color}" stroke-width="2" fill="none"/>\n',
            dots
          ]
      end
    end
  end

  defp legend do
    # Top-right corner.
    x0 = 558
    x1 = 578
    label_x = 584
    start_y = 40
    spacing = 22

    @driver_colors
    |> Enum.with_index()
    |> Enum.map(fn {{driver, color}, i} ->
      y = start_y + i * spacing

      [
        ~s'<line x1="#{x0}" y1="#{y}" x2="#{x1}" y2="#{y}" stroke="#{color}" stroke-width="2"/>\n',
        ~s'<circle cx="#{(x0 + x1) / 2}" cy="#{y}" r="3.5" fill="#{color}"/>\n',
        ~s'<text x="#{label_x}" y="#{y + 4}" font-size="11" fill="#222">#{driver}</text>\n'
      ]
    end)
  end
end

case System.argv() do
  [] -> RenderPerfMatrix.run()
  [tsv] -> RenderPerfMatrix.run(tsv)
end
