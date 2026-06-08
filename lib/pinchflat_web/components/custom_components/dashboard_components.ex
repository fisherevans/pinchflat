defmodule PinchflatWeb.CustomComponents.DashboardComponents do
  @moduledoc """
  The "Control Room" UI kit: small, reusable building blocks shared across the
  subscription list, detail, and edit screens. Calm, dark, information-dense -
  green = gained/kept, red = removed/filtered. Reuses the existing theme tokens.
  """
  use Phoenix.Component

  @avatar_colors ~w(#3C50E0 #10B981 #F0950C #259AE6 #DC3545 #6577F3 #13C296 #FFBA00)

  @doc """
  A metric tile: mono label, big number, and an optional delta line.
  """
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :class, :string, default: ""
  slot :delta

  def stat_tile(assigns) do
    ~H"""
    <div class={[
      "rounded-xl border border-stroke bg-white p-4 dark:border-strokedark dark:bg-boxdark",
      @class
    ]}>
      <div class="font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-bodydark2">
        {@label}
      </div>
      <div class="mt-1.5 text-3xl font-bold leading-none text-black dark:text-white">{@value}</div>
      <div :if={@delta != []} class="mt-2 flex items-center gap-2 text-[13px] text-bodydark">
        {render_slot(@delta)}
      </div>
    </div>
    """
  end

  @doc """
  A small "i" affordance that reveals help text on hover or click. Lets verbose
  field guidance collapse to an icon next to a label instead of a paragraph under it.
  """
  attr :text, :string, required: true

  def info_tip(assigns) do
    ~H"""
    <span x-data="{ open: false }" class="relative inline-flex align-middle">
      <button
        type="button"
        x-on:mouseenter="open = true"
        x-on:mouseleave="open = false"
        x-on:click.prevent.stop="open = !open"
        class="grid h-4 w-4 place-items-center rounded-full border border-bodydark2 text-[10px] font-bold leading-none text-bodydark2 transition hover:border-primary hover:text-primary"
        aria-label="More info"
      >
        i
      </button>
      <span
        x-show="open"
        x-cloak
        class="absolute left-1/2 top-6 z-50 w-64 -translate-x-1/2 rounded-md border border-stroke bg-white px-3 py-2 text-xs font-normal normal-case leading-relaxed tracking-normal text-bodydark shadow-lg dark:border-strokedark dark:bg-boxdark"
      >
        {@text}
      </span>
    </span>
    """
  end

  @doc """
  A status pill with a colored dot. status: :active | :paused | :indexing | :disabled
  """
  attr :status, :atom, default: :active

  def status_pill(assigns) do
    {label, color} =
      case assigns.status do
        :active -> {"Active", "text-meta-3"}
        :indexing -> {"Indexing", "text-meta-5"}
        :paused -> {"Paused", "text-meta-6"}
        _ -> {"Disabled", "text-bodydark2"}
      end

    assigns = assign(assigns, label: label, color: color)

    ~H"""
    <span class={[
      "inline-flex items-center gap-2 rounded-full border border-strokedark bg-meta-4/40 px-2.5 py-0.5 text-xs font-semibold",
      @color
    ]}>
      <span class="h-1.5 w-1.5 rounded-full bg-current"></span>{@label}
    </span>
    """
  end

  @doc """
  A compact activity sparkline rendered as proportional bars from a list of numbers.
  """
  attr :values, :list, required: true
  attr :color, :string, default: "bg-primary"
  attr :height, :string, default: "28px"
  attr :class, :string, default: ""

  def sparkline(assigns) do
    max = Enum.max([1 | assigns.values])
    assigns = assign(assigns, :max, max)

    ~H"""
    <div class={["flex items-end gap-px", @class]} style={"height:#{@height}"}>
      <div :for={v <- @values} class={["flex-1 rounded-sm", @color]} style={"height:#{bar_pct(v, @max)}%; min-width:2px"}>
      </div>
    </div>
    """
  end

  defp bar_pct(0, _max), do: 0
  defp bar_pct(v, max), do: max(12, round(v / max * 100))

  @doc """
  A line sparkline (with a soft area fill) - better than bars for dense series
  like a year of weekly activity. `values` is oldest-first; `color` is a hex.
  """
  attr :values, :list, required: true
  attr :color, :string, default: "#3C50E0"
  attr :width, :integer, default: 220
  attr :height, :integer, default: 34

  def line_sparkline(assigns) do
    values = assigns.values
    count = max(length(values), 1)
    maxv = Enum.max([1 | values])
    w = assigns.width
    h = assigns.height

    points =
      values
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {v, i} ->
        x = if count > 1, do: i / (count - 1) * w, else: w / 2
        y = h - 1 - v / maxv * (h - 3)
        "#{Float.round(x, 1)},#{Float.round(y, 1)}"
      end)

    assigns = assign(assigns, line: points, area: "0,#{h} #{points} #{w},#{h}", w: w, h: h)

    ~H"""
    <svg viewBox={"0 0 #{@w} #{@h}"} width="100%" height={@h} preserveAspectRatio="none">
      <polygon points={@area} fill={@color} fill-opacity="0.14" />
      <polyline
        points={@line}
        fill="none"
        stroke={@color}
        stroke-width="1.5"
        stroke-linejoin="round"
        stroke-linecap="round"
        vector-effect="non-scaling-stroke"
      />
    </svg>
    """
  end

  @doc """
  Recent-change badges: "+N new" (green) and "-N culled" (red), or a quiet marker.
  """
  attr :new, :integer, default: 0
  attr :culled, :integer, default: 0

  def change_badge(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-1.5">
      <span :if={@new > 0} class="rounded-md bg-meta-3/15 px-2 py-0.5 font-mono text-xs font-semibold text-meta-3">
        +{@new} new
      </span>
      <span :if={@culled > 0} class="rounded-md bg-meta-1/15 px-2 py-0.5 font-mono text-xs font-semibold text-meta-1">
        &minus;{@culled} culled
      </span>
      <span :if={@new == 0 and @culled == 0} class="text-xs text-bodydark2">quiet</span>
    </div>
    """
  end

  @doc """
  A diverging weekly activity graph: downloads grow up (green), deletions grow
  down (red), around a center line. `weeks` is a list of `%{downloads:, deletions:}`.
  """
  attr :weeks, :list, required: true
  attr :height, :string, default: "120px"

  def activity_graph(assigns) do
    max = Enum.reduce(assigns.weeks, 1, fn w, acc -> max(acc, max(w.downloads, w.deletions)) end)
    assigns = assign(assigns, :max, max)

    ~H"""
    <div class="flex items-stretch gap-1" style={"height:#{@height}"}>
      <div :for={w <- @weeks} class="flex flex-1 flex-col" title={"#{w.downloads} downloaded, #{w.deletions} culled"}>
        <div class="flex flex-1 items-end justify-center border-b border-strokedark">
          <div class="w-2/3 rounded-t-sm bg-meta-3" style={"height:#{graph_pct(w.downloads, @max)}%"}></div>
        </div>
        <div class="flex flex-1 items-start justify-center">
          <div class="w-2/3 rounded-b-sm bg-meta-1" style={"height:#{graph_pct(w.deletions, @max)}%"}></div>
        </div>
      </div>
    </div>
    """
  end

  defp graph_pct(0, _max), do: 0
  defp graph_pct(v, max), do: max(4, round(v / max * 100))

  @doc """
  A colored, rounded avatar showing the first letter of a name. Color is derived
  from `seed` so it's stable per source.
  """
  attr :name, :string, required: true
  attr :seed, :integer, default: 0
  attr :size, :string, default: "h-10 w-10"

  def source_avatar(assigns) do
    color = Enum.at(@avatar_colors, rem(assigns.seed, length(@avatar_colors)))
    initial = assigns.name |> String.trim() |> String.first() |> Kernel.||("?") |> String.upcase()
    assigns = assign(assigns, color: color, initial: initial)

    ~H"""
    <div
      class={["grid flex-none place-items-center rounded-xl font-bold text-white", @size]}
      style={"background:linear-gradient(135deg, #{@color}, #{@color}bb)"}
    >
      {@initial}
    </div>
    """
  end

  @doc """
  A labelled config summary card with an optional edit link - the organized
  replacement for the raw attribute dump. Holds `config_kv` rows.
  """
  attr :title, :string, required: true
  attr :href, :string, default: nil
  slot :inner_block, required: true

  def config_card(assigns) do
    ~H"""
    <div class="rounded-xl border border-stroke bg-meta-4/20 p-4 dark:border-strokedark">
      <div class="mb-2 flex items-center justify-between">
        <h4 class="font-bold text-black dark:text-white">{@title}</h4>
        <.link :if={@href} href={@href} class="text-xs font-semibold text-primary hover:underline">edit</.link>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "A single key/value row inside a `config_card`."
  attr :label, :string, required: true
  attr :value, :any, required: true

  def config_kv(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3 border-b border-stroke py-1.5 text-sm last:border-0 dark:border-strokedark">
      <span class="flex-none text-bodydark2">{@label}</span>
      <span class="truncate text-right font-mono text-[13px] font-medium text-black dark:text-white">{@value}</span>
    </div>
    """
  end
end
