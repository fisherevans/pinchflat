defmodule PinchflatWeb.CustomComponents.TitleCleanComponents do
  @moduledoc """
  The shared title-cleaning chain editor + live tester. Used in two places:

    - the source form's "Titles" tab (per-source chain, plus a read-only view of the global
      chain and a toggle to opt the source out of it)
    - the Settings page (the global chain itself, no global block, no toggle)

  Everything is Alpine-driven and talks to a preview endpoint that runs the (effective) chain
  server-side and returns a per-step trace. The component is presentation-only; the caller
  supplies the preview URL, the hidden-input names for form submission, and the seed data.
  """

  use Phoenix.Component

  @doc """
  Renders the chain editor + tester.

  Attrs:
    * `url` - preview endpoint (empty string disables the tester)
    * `submit_name` - hidden input name carrying the chain JSON (e.g. "source[title_clean_chain_json]")
    * `seed_steps` - current chain (a `%{"steps" => [...]}` map or a bare list)
    * `empty_text` - message shown when there's no preview URL
    * `show_global` - render the read-only global block + opt-out toggle (source page only)
    * `global_steps` - the global chain steps, for the read-only block
    * `use_global` - current value of the per-source opt-in toggle
    * `use_global_name` - hidden input name for the toggle
  """
  attr :url, :string, default: ""
  attr :submit_name, :string, required: true
  attr :seed_steps, :any, default: %{"steps" => []}
  attr :empty_text, :string, default: "Save first to preview the chain against indexed titles."
  attr :show_global, :boolean, default: false
  attr :global_steps, :any, default: []
  attr :use_global, :boolean, default: true
  attr :use_global_name, :string, default: nil

  def title_clean_chain_editor(assigns) do
    ~H"""
    <section
      data-steps={Phoenix.json_library().encode!(steps_list(@seed_steps))}
      data-global={Phoenix.json_library().encode!(steps_list(@global_steps))}
      data-use-global={to_string(@use_global)}
      x-data={editor_state(@url, @show_global)}
      x-on:input.debounce.350ms="scheduleRefresh()"
      x-on:change.debounce.350ms="scheduleRefresh()"
    >
      <input type="hidden" name={@submit_name} x-bind:value="stepsJson()" />
      <input
        :if={@show_global && @use_global_name}
        type="hidden"
        name={@use_global_name}
        x-bind:value="useGlobal ? 'true' : 'false'"
      />

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <%!-- ===== LEFT: the chain ===== --%>
        <div>
          <%!-- read-only global block (source page only) --%>
          <div
            :if={@show_global}
            class="mb-4 rounded-lg border border-strokedark/60 bg-meta-4/10 p-3 transition-opacity"
            x-bind:class="useGlobal ? '' : 'opacity-50'"
          >
            <div class="mb-1 flex items-center justify-between gap-2">
              <span class="text-xs font-semibold uppercase tracking-wider text-bodydark2">Global rules</span>
              <div class="flex items-center gap-2 text-xs text-bodydark2">
                <span x-text="useGlobal ? 'Applied' : 'Off'"></span>
                <button
                  type="button"
                  x-on:click="useGlobal = !useGlobal; scheduleRefresh()"
                  class="relative h-5 w-9 shrink-0 rounded-full transition"
                  x-bind:class="useGlobal ? 'bg-primary' : 'bg-stroke dark:bg-meta-4'"
                  title="Apply the global chain to this source"
                >
                  <span
                    class="absolute top-0.5 h-4 w-4 rounded-full bg-white transition-all"
                    x-bind:class="useGlobal ? 'left-4' : 'left-0.5'"
                  >
                  </span>
                </button>
              </div>
            </div>
            <p class="mb-2 text-xs text-bodydark2">
              Configured in <.link navigate="/settings" class="text-primary hover:underline">Settings</.link>
              and run before this source's rules. Toggle off to skip them for this source.
            </p>
            <ul class="flex flex-col gap-1.5">
              <template x-for="(r, i) in globalSteps" x-bind:key="i">
                <li class="rounded border border-strokedark/60 bg-boxdark/40 px-3 py-1.5">
                  <div class="flex items-center gap-2">
                    <span class="w-4 text-center font-mono text-xs text-bodydark2" x-text="i + 1"></span>
                    <span class="truncate text-sm font-medium text-bodydark1" x-text="r.name || (r.preset_key || '(rule)')">
                    </span>
                    <span
                      x-show="r.preset_key"
                      class="shrink-0 rounded bg-secondary/20 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-secondary"
                    >
                      preset
                    </span>
                    <span
                      x-show="r.condition.kind !== 'none'"
                      class="shrink-0 rounded bg-meta-6/20 px-1.5 py-0.5 text-[10px] font-semibold text-meta-6"
                      x-text="condLabel(r.condition)"
                    >
                    </span>
                    <span
                      x-show="url && useGlobal"
                      class="ml-auto shrink-0 rounded-full bg-stroke px-2 py-0.5 text-[11px] text-bodydark2 dark:bg-meta-4"
                      x-text="ruleHits(i + 1) + ' hit' + (ruleHits(i + 1) === 1 ? '' : 's')"
                    >
                    </span>
                  </div>
                  <div class="ml-6 mt-0.5 truncate font-mono text-xs text-bodydark2">
                    <template x-if="r.preset_key"><span x-text="presetDesc(r.preset_key)"></span></template>
                    <template x-if="!r.preset_key">
                      <span>
                        <span class="text-meta-1/80" x-text="'/' + r.find + '/'"></span>
                        <span>&rarr;</span>
                        <span class="text-meta-3" x-text="r.replace === '' ? '(remove)' : '“' + r.replace + '”'"></span>
                      </span>
                    </template>
                  </div>
                </li>
              </template>
            </ul>
            <p x-show="globalSteps.length === 0" class="text-xs text-bodydark2">No global rules configured.</p>
          </div>

          <div class="mb-3 flex items-center justify-between gap-2">
            <span class="text-xs font-semibold uppercase tracking-wider text-bodydark2">
              {if @show_global, do: "This source's rules", else: "The chain"}
            </span>
            <div class="flex items-center gap-2">
              <div class="relative" x-data="{ open: false }">
                <button
                  type="button"
                  x-on:click="open = !open"
                  class="rounded border border-stroke px-3 py-1.5 text-sm hover:bg-meta-4/40 dark:border-strokedark"
                >
                  + Preset
                </button>
                <div
                  x-show="open"
                  x-cloak
                  x-on:click.outside="open = false"
                  class="absolute right-0 z-10 mt-1 w-64 rounded-lg border border-stroke bg-white py-1 shadow-lg dark:border-strokedark dark:bg-boxdark"
                >
                  <template x-for="p in presets" x-bind:key="p.key">
                    <button
                      type="button"
                      x-on:click="addPreset(p); open = false"
                      class="block w-full px-4 py-2 text-left text-sm hover:bg-meta-4/40"
                    >
                      <span class="font-medium" x-text="p.name"></span>
                      <span class="block text-xs text-bodydark2" x-text="p.desc"></span>
                    </button>
                  </template>
                </div>
              </div>
              <button
                type="button"
                x-on:click="addCustom()"
                class="rounded bg-primary px-3 py-1.5 text-sm font-medium text-white hover:bg-opacity-90"
              >
                + Custom rule
              </button>
            </div>
          </div>

          <ul class="flex flex-col gap-2">
            <template x-for="(r, i) in steps" x-bind:key="r._id">
              <li
                class="rounded-lg border bg-white transition dark:bg-boxdark"
                x-bind:class="r.enabled ? 'border-stroke dark:border-strokedark' : 'border-stroke/60 opacity-60 dark:border-strokedark/60'"
              >
                <div class="flex items-center gap-2.5 px-3 py-2.5">
                  <span class="w-4 text-center font-mono text-xs text-bodydark2" x-text="i + 1"></span>

                  <div class="-my-1 flex flex-col leading-none">
                    <button
                      type="button"
                      x-on:click="move(i, -1)"
                      x-bind:disabled="i === 0"
                      class="text-bodydark2 hover:text-black disabled:opacity-20 dark:hover:text-white"
                    >
                      &#9650;
                    </button>
                    <button
                      type="button"
                      x-on:click="move(i, 1)"
                      x-bind:disabled="i === steps.length - 1"
                      class="text-bodydark2 hover:text-black disabled:opacity-20 dark:hover:text-white"
                    >
                      &#9660;
                    </button>
                  </div>

                  <button
                    type="button"
                    x-on:click="r.enabled = !r.enabled; scheduleRefresh()"
                    class="relative h-5 w-9 shrink-0 rounded-full transition"
                    x-bind:class="r.enabled ? 'bg-primary' : 'bg-stroke dark:bg-meta-4'"
                    title="Enable / disable"
                  >
                    <span
                      class="absolute top-0.5 h-4 w-4 rounded-full bg-white transition-all"
                      x-bind:class="r.enabled ? 'left-4' : 'left-0.5'"
                    >
                    </span>
                  </button>

                  <button
                    type="button"
                    x-on:click="editId = (editId === r._id ? null : r._id)"
                    class="min-w-0 flex-1 text-left"
                  >
                    <div class="flex items-center gap-2">
                      <span
                        class="truncate text-sm font-medium text-black dark:text-white"
                        x-text="r.name || (r.preset_key || '(unnamed rule)')"
                      >
                      </span>
                      <span
                        x-show="r.preset_key"
                        class="shrink-0 rounded bg-secondary/20 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-secondary"
                      >
                        preset
                      </span>
                      <span
                        x-show="r.condition.kind !== 'none'"
                        class="shrink-0 rounded bg-meta-6/20 px-1.5 py-0.5 text-[10px] font-semibold text-meta-6"
                        x-text="condLabel(r.condition)"
                      >
                      </span>
                    </div>
                    <div class="mt-0.5 truncate font-mono text-xs text-bodydark2">
                      <template x-if="r.preset_key"><span x-text="presetDesc(r.preset_key)"></span></template>
                      <template x-if="!r.preset_key">
                        <span>
                          <span class="text-meta-1/80" x-text="'/' + r.find + '/'"></span>
                          <span>&rarr;</span>
                          <span class="text-meta-3" x-text="r.replace === '' ? '(remove)' : '“' + r.replace + '”'">
                          </span>
                        </span>
                      </template>
                    </div>
                  </button>

                  <span
                    x-show="url"
                    class="shrink-0 rounded-full bg-stroke px-2 py-0.5 text-[11px] text-bodydark2 dark:bg-meta-4"
                    x-text="ruleHits(globalOffset() + i + 1) + ' hit' + (ruleHits(globalOffset() + i + 1) === 1 ? '' : 's')"
                    title="How many of the previewed titles this rule changes"
                  >
                  </span>

                  <button
                    type="button"
                    x-on:click="removeStep(i)"
                    class="shrink-0 text-bodydark2 hover:text-meta-1"
                    title="Remove"
                  >
                    &times;
                  </button>
                </div>

                <%!-- expanded editor --%>
                <div
                  x-show="editId === r._id"
                  x-cloak
                  class="space-y-4 border-t border-stroke px-4 py-4 dark:border-strokedark"
                >
                  <div>
                    <label class="mb-1 block text-xs font-medium text-bodydark2">Name</label>
                    <input
                      type="text"
                      x-model="r.name"
                      class="w-full rounded border border-stroke bg-transparent px-3 py-1.5 text-sm dark:border-strokedark dark:bg-meta-4"
                    />
                  </div>

                  <template x-if="!r.preset_key">
                    <div class="grid grid-cols-2 gap-3">
                      <div>
                        <label class="mb-1 block text-xs font-medium text-bodydark2">Find (regex)</label>
                        <input
                          type="text"
                          spellcheck="false"
                          x-model="r.find"
                          class="w-full rounded border border-stroke bg-transparent px-3 py-1.5 font-mono text-sm dark:border-strokedark dark:bg-meta-4"
                        />
                      </div>
                      <div>
                        <label class="mb-1 block text-xs font-medium text-bodydark2">Replace with</label>
                        <input
                          type="text"
                          spellcheck="false"
                          x-model="r.replace"
                          placeholder="(blank = delete)"
                          class="w-full rounded border border-stroke bg-transparent px-3 py-1.5 font-mono text-sm dark:border-strokedark dark:bg-meta-4"
                        />
                      </div>
                      <label class="col-span-2 flex items-center gap-2 text-sm">
                        <input type="checkbox" x-model="r.case_sensitive" class="rounded" /> Case sensitive
                      </label>
                    </div>
                  </template>

                  <div class="rounded-lg border border-stroke p-3 dark:border-strokedark">
                    <label class="mb-2 block text-xs font-semibold uppercase tracking-wide text-bodydark2">
                      Only apply when&hellip;
                    </label>
                    <div class="flex flex-wrap items-center gap-2">
                      <select
                        x-model="r.condition.kind"
                        class="rounded border border-stroke bg-transparent px-2 py-1.5 text-sm dark:border-strokedark dark:bg-meta-4"
                      >
                        <option value="none">always</option>
                        <option value="title_contains">title contains</option>
                        <option value="title_matches">title matches regex</option>
                        <option value="duration_lt">duration &lt; (sec)</option>
                        <option value="duration_gt">duration &gt; (sec)</option>
                        <option value="duration_between">duration between (sec)</option>
                      </select>
                      <input
                        x-show="['title_contains', 'title_matches'].includes(r.condition.kind)"
                        x-model="r.condition.value"
                        type="text"
                        placeholder="value"
                        class="rounded border border-stroke bg-transparent px-2 py-1.5 font-mono text-sm dark:border-strokedark dark:bg-meta-4"
                      />
                      <input
                        x-show="['duration_lt', 'duration_gt'].includes(r.condition.kind)"
                        x-model="r.condition.value"
                        type="number"
                        placeholder="seconds"
                        class="w-28 rounded border border-stroke bg-transparent px-2 py-1.5 font-mono text-sm dark:border-strokedark dark:bg-meta-4"
                      />
                      <template x-if="r.condition.kind === 'duration_between'">
                        <div class="flex items-center gap-1">
                          <input
                            x-model="r.condition.min"
                            type="number"
                            placeholder="min"
                            class="w-20 rounded border border-stroke bg-transparent px-2 py-1.5 font-mono text-sm dark:border-strokedark dark:bg-meta-4"
                          />
                          <span class="text-bodydark2">-</span>
                          <input
                            x-model="r.condition.max"
                            type="number"
                            placeholder="max"
                            class="w-20 rounded border border-stroke bg-transparent px-2 py-1.5 font-mono text-sm dark:border-strokedark dark:bg-meta-4"
                          />
                        </div>
                      </template>
                    </div>
                    <p class="mt-2 text-xs text-bodydark2">
                      Checked against the running title (after earlier rules) and the item's duration.
                    </p>
                  </div>

                  <div class="flex justify-end">
                    <button
                      type="button"
                      x-on:click="editId = null"
                      class="rounded bg-stroke px-3 py-1.5 text-sm dark:bg-meta-4"
                    >
                      Done
                    </button>
                  </div>
                </div>
              </li>
            </template>
          </ul>
          <p
            x-show="steps.length === 0"
            class="rounded-lg border border-dashed border-stroke py-8 text-center text-sm text-bodydark2 dark:border-strokedark"
          >
            No rules yet. Titles pass through unchanged.
          </p>
        </div>

        <%!-- ===== RIGHT: the tester ===== --%>
        <div>
          <div class="mb-3 flex items-center justify-between gap-2">
            <span class="text-xs font-semibold uppercase tracking-wider text-bodydark2">Tester</span>
            <span
              x-show="url"
              class="rounded-full bg-meta-3/15 px-3 py-1 text-sm font-semibold text-meta-3"
              x-text="preview.changed + ' of ' + preview.total + ' titles change'"
            >
            </span>
          </div>

          <p
            x-show="!url"
            class="rounded-lg border border-dashed border-stroke py-8 text-center text-sm text-bodydark2 dark:border-strokedark"
          >
            {@empty_text}
          </p>

          <%!-- your own test titles --%>
          <div x-show="url" class="mb-4">
            <div class="mb-2 flex items-center justify-between">
              <span class="text-xs font-medium text-bodydark2">Test titles</span>
              <button type="button" x-on:click="addTest()" class="text-sm text-primary hover:underline">
                + Add
              </button>
            </div>
            <template x-for="(t, i) in testTitles" x-bind:key="i">
              <div class="mb-2 flex items-center gap-2">
                <input
                  type="text"
                  spellcheck="false"
                  x-model="t.title"
                  placeholder="paste a title to test"
                  class="min-w-0 flex-1 rounded border border-stroke bg-transparent px-3 py-1.5 font-mono text-xs dark:border-strokedark dark:bg-meta-4"
                />
                <input
                  type="number"
                  x-model="t.duration"
                  placeholder="dur(s)"
                  class="w-20 rounded border border-stroke bg-transparent px-2 py-1.5 font-mono text-xs dark:border-strokedark dark:bg-meta-4"
                />
                <button type="button" x-on:click="removeTest(i)" class="shrink-0 text-bodydark2 hover:text-meta-1">
                  &times;
                </button>
              </div>
            </template>
          </div>

          <div x-show="error" x-cloak class="text-sm text-meta-1">Couldn't run the preview - check your rules.</div>

          <div x-show="url && loaded && !error" class="mb-2">
            <input
              type="text"
              spellcheck="false"
              x-model="filter"
              placeholder="Filter loaded titles..."
              class="w-full rounded border border-stroke bg-transparent px-3 py-1.5 text-sm dark:border-strokedark dark:bg-meta-4"
            />
          </div>

          <div x-show="url && loaded && !error" class="flex max-h-[40rem] flex-col gap-2 overflow-y-auto">
            <template x-for="(s, si) in preview.samples" x-bind:key="si">
              <div
                x-show="matchesFilter(s)"
                class="shrink-0 overflow-hidden rounded-md border transition-colors"
                x-bind:class="expanded[s.title] ? 'border-primary/60 bg-meta-4/10' : 'border-stroke hover:border-bodydark2/40 dark:border-strokedark'"
              >
                <button
                  type="button"
                  x-on:click="toggleExpand(s.title)"
                  class="flex w-full items-start gap-2 px-2.5 py-2 text-left hover:bg-meta-4/10"
                >
                  <span
                    class="mt-0.5 shrink-0 text-[10px] leading-none text-bodydark2 transition-transform"
                    x-bind:class="expanded[s.title] ? 'rotate-90' : ''"
                  >
                    &#9656;
                  </span>
                  <div class="min-w-0 flex-1">
                    <template x-if="!s.changed">
                      <div class="truncate font-mono text-xs text-bodydark1" x-text="s.title"></div>
                    </template>
                    <template x-if="s.changed">
                      <div class="space-y-0.5">
                        <div class="truncate font-mono text-xs text-bodydark2">
                          <template x-for="(seg, j) in s.diff" x-bind:key="j">
                            <span
                              x-bind:class="{
                                'rounded bg-meta-1/20 px-0.5 text-meta-1 line-through': seg.op === 'del',
                                'rounded bg-meta-3/20 px-0.5 font-medium text-meta-3': seg.op === 'ins'
                              }"
                              x-text="seg.text"
                            >
                            </span>
                          </template>
                        </div>
                        <div class="truncate font-mono text-xs">
                          <span class="text-bodydark2">&rarr;&nbsp;</span><span class="text-bodydark1" x-text="s.final"></span>
                        </div>
                      </div>
                    </template>
                    <div class="mt-1 flex items-center gap-2 text-[10px] leading-none text-bodydark2">
                      <span x-show="s.duration != null" class="font-mono" x-text="fmtDur(s.duration)"></span>
                      <span x-show="!s.changed" class="rounded bg-meta-4 px-1.5 py-0.5">no changes</span>
                    </div>
                  </div>
                </button>

                <div
                  x-show="expanded[s.title]"
                  x-cloak
                  class="divide-y divide-stroke/60 border-t border-strokedark bg-black/20 dark:divide-strokedark/60"
                >
                  <template x-for="(st, sti) in s.steps" x-bind:key="sti">
                    <div class="flex items-start gap-2.5 px-3 py-2">
                      <span class="mt-0.5 w-4 shrink-0 text-center font-mono text-[11px] text-bodydark2" x-text="st.n">
                      </span>
                      <span
                        class="mt-1.5 h-2 w-2 shrink-0 rounded-full"
                        x-bind:class="{
                          'bg-meta-3': st.status === 'changed',
                          'bg-bodydark2/40': st.status === 'unchanged',
                          'bg-meta-6/70': st.status === 'condition_skipped',
                          'bg-stroke dark:bg-strokedark': st.status === 'disabled'
                        }"
                      >
                      </span>
                      <div class="min-w-0 flex-1">
                        <div class="flex flex-wrap items-center gap-2">
                          <span class="truncate text-xs font-medium" x-text="st.name"></span>
                          <span
                            x-show="st.is_global"
                            class="rounded bg-secondary/20 px-1.5 text-[10px] font-semibold uppercase text-secondary"
                          >
                            global
                          </span>
                          <span
                            x-show="st.status === 'condition_skipped'"
                            class="rounded bg-meta-6/15 px-1.5 text-[10px] text-meta-6"
                          >
                            condition not met
                          </span>
                          <span
                            x-show="st.status === 'disabled'"
                            class="rounded bg-stroke px-1.5 text-[10px] text-bodydark2 dark:bg-meta-4"
                          >
                            disabled
                          </span>
                          <span x-show="st.status === 'unchanged'" class="text-[10px] text-bodydark2">
                            no change
                          </span>
                        </div>
                        <div x-show="st.status === 'changed'" class="mt-0.5 break-words font-mono text-xs leading-relaxed">
                          <template x-for="(seg, j) in st.diff" x-bind:key="j">
                            <span
                              x-bind:class="{
                                'bg-meta-1/15 text-meta-1 line-through rounded px-0.5': seg.op === 'del',
                                'bg-meta-3/15 text-meta-3 rounded px-0.5': seg.op === 'ins',
                                'text-bodydark2': seg.op === 'eq'
                              }"
                              x-text="seg.text"
                            >
                            </span>
                          </template>
                        </div>
                      </div>
                    </div>
                  </template>

                  <div class="flex items-center gap-2.5 bg-meta-3/5 px-3 py-2.5">
                    <span class="w-4 shrink-0 text-center text-bodydark2">=</span>
                    <div class="min-w-0 flex-1">
                      <div class="text-[10px] font-semibold uppercase tracking-wide text-bodydark2">Result</div>
                      <div
                        class="truncate font-mono text-xs font-medium"
                        x-bind:class="s.changed ? 'text-meta-3' : 'text-bodydark2'"
                        x-text="s.final"
                      >
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </template>
            <p x-show="visibleCount() === 0" x-cloak class="py-6 text-center text-xs text-bodydark2">
              No loaded titles match that filter.
            </p>
          </div>

          <div x-show="url && loaded && !error" class="mt-3 flex items-center justify-between gap-2 text-xs text-bodydark2">
            <span x-text="(filter.trim() ? visibleCount() + ' matching / ' : '') + 'Showing ' + preview.indexed_shown + ' of ' + preview.indexed_total + ' indexed titles'">
            </span>
            <button
              type="button"
              x-show="canLoadMore()"
              x-on:click="loadMore()"
              class="rounded border border-stroke px-2.5 py-1 text-primary hover:bg-meta-4/40 dark:border-strokedark"
            >
              Load 25 more
            </button>
          </div>

          <div
            x-show="url && loaded && !error"
            class="mt-4 flex flex-wrap items-center gap-x-4 gap-y-1 text-[11px] text-bodydark2"
          >
            <span class="flex items-center gap-1.5">
              <span class="h-2 w-2 rounded-full bg-meta-3"></span> changed
            </span>
            <span class="flex items-center gap-1.5">
              <span class="h-2 w-2 rounded-full bg-bodydark2/40"></span> ran, no change
            </span>
            <span class="flex items-center gap-1.5">
              <span class="h-2 w-2 rounded-full bg-meta-6/70"></span> condition skipped
            </span>
            <span class="flex items-center gap-1.5">
              <span class="h-2 w-2 rounded-full bg-stroke dark:bg-strokedark"></span> disabled
            </span>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp steps_list(%{"steps" => steps}) when is_list(steps), do: steps
  defp steps_list(steps) when is_list(steps), do: steps
  defp steps_list(_), do: []

  # The Alpine component state. `url` is the preview endpoint; `has_global` controls whether the
  # source opt-out toggle participates in the effective-chain offset math.
  defp editor_state(url, has_global) do
    """
    {
      url: '#{url}',
      hasGlobal: #{has_global},
      steps: [],
      globalSteps: [],
      useGlobal: true,
      testTitles: [],
      editId: null,
      loaded: false,
      error: false,
      _uid: 0,
      _t: null,
      sampleLimit: 25,
      filter: '',
      expanded: {},
      preview: { total: 0, changed: 0, samples: [], indexed_shown: 0, indexed_total: 0, indexed_cap: 200 },
      presets: [
        { key: 'strip_emojis', name: 'Strip emojis', desc: 'Remove emoji & pictographs' },
        { key: 'normalize_whitespace', name: 'Normalize whitespace', desc: 'Collapse runs of whitespace, trim ends' },
        { key: 'strip_hashtags', name: 'Strip hashtags & @handles', desc: 'Remove #hashtags and @channel handles' }
      ],
      init() {
        let seed = [];
        try { seed = JSON.parse(this.$el.dataset.steps || '[]'); } catch (e) {}
        this.steps = seed.map(s => this.normalize(s));
        try { this.globalSteps = JSON.parse(this.$el.dataset.global || '[]').map(s => this.normalize(s)); } catch (e) {}
        this.useGlobal = (this.$el.dataset.useGlobal || 'true') !== 'false';
        this.refresh();
      },
      normalize(s) {
        return {
          _id: ++this._uid,
          enabled: s.enabled !== false,
          name: s.name || '',
          preset_key: s.preset_key || null,
          find: s.find || '',
          replace: s.replace || '',
          case_sensitive: s.case_sensitive === true,
          condition: Object.assign({ kind: 'none', value: '', min: '', max: '' }, s.condition || {})
        };
      },
      globalOffset() { return (this.hasGlobal && this.useGlobal) ? this.globalSteps.length : 0; },
      presetDesc(key) { const p = this.presets.find(p => p.key === key); return p ? p.desc : ''; },
      addPreset(p) { this.steps.push(this.normalize({ preset_key: p.key, name: p.name })); this.scheduleRefresh(); },
      addCustom() {
        const s = this.normalize({ name: 'New rule' });
        this.steps.push(s);
        this.editId = s._id;
        this.scheduleRefresh();
      },
      removeStep(i) {
        if (this.steps[i]._id === this.editId) this.editId = null;
        this.steps.splice(i, 1);
        this.scheduleRefresh();
      },
      move(i, d) {
        const j = i + d;
        if (j < 0 || j >= this.steps.length) return;
        const a = this.steps; [a[i], a[j]] = [a[j], a[i]];
        this.scheduleRefresh();
      },
      addTest() { this.testTitles.push({ title: '', duration: '' }); },
      removeTest(i) { this.testTitles.splice(i, 1); this.scheduleRefresh(); },
      condLabel(c) {
        const m = { title_contains: 'if contains', title_matches: 'if matches', duration_lt: 'if dur <', duration_gt: 'if dur >', duration_between: 'if dur in' };
        if (!m[c.kind]) return '';
        const v = c.kind === 'duration_between' ? (c.min + '-' + c.max) : c.value;
        return m[c.kind] + (v !== '' && v != null ? ' ' + v : '');
      },
      ruleHits(n) {
        return (this.preview.samples || []).filter(s => {
          const st = (s.steps || []).find(st => st.n === n);
          return st && st.status === 'changed';
        }).length;
      },
      cleanStep(s) {
        return { enabled: s.enabled, name: s.name, preset_key: s.preset_key, find: s.find, replace: s.replace, case_sensitive: s.case_sensitive, condition: s.condition };
      },
      stepsJson() { return JSON.stringify({ steps: this.steps.map(s => this.cleanStep(s)) }); },
      scheduleRefresh() { clearTimeout(this._t); this._t = setTimeout(() => this.refresh(), 350); },
      loadMore() { this.sampleLimit = Math.min(this.sampleLimit + 25, this.preview.indexed_cap || 200); this.refresh(); },
      canLoadMore() { return this.preview.indexed_shown < this.preview.indexed_total && this.preview.indexed_shown < (this.preview.indexed_cap || 200); },
      toggleExpand(k) { this.expanded[k] = !this.expanded[k]; },
      matchesFilter(s) { const q = this.filter.trim().toLowerCase(); return !q || (s.title || '').toLowerCase().includes(q); },
      visibleCount() { return (this.preview.samples || []).filter(s => this.matchesFilter(s)).length; },
      fmtDur(sec) {
        if (sec === null || sec === undefined || sec === '') return '';
        sec = Math.round(Number(sec));
        if (isNaN(sec)) return '';
        const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
        const p = (n) => String(n).padStart(2, '0');
        if (h > 0) return h + 'h' + p(m) + 'm' + p(s) + 's';
        if (m > 0) return m + 'm' + p(s) + 's';
        return s + 's';
      },
      async refresh() {
        if (!this.url) { this.loaded = true; return; }
        const titles = JSON.stringify(this.testTitles.filter(t => t.title && t.title.trim() !== ''));
        const q = new URLSearchParams({ chain: this.stepsJson(), titles: titles, limit: this.sampleLimit, use_global: this.useGlobal ? '1' : '0' });
        try {
          const res = await fetch(this.url + '?' + q.toString());
          const d = await res.json();
          if (d.error) { this.error = true; this.loaded = true; return; }
          this.error = false; this.preview = d; this.loaded = true;
        } catch (e) { this.error = true; this.loaded = true; }
      }
    }
    """
  end
end
