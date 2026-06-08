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

  defp bar_pct(0, _max), do: 6
  defp bar_pct(v, max), do: max(10, round(v / max * 100))

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
end
