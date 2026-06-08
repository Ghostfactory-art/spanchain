defmodule SpanChain.Web.EvalLive do
  @moduledoc "Side-by-side diff UI for an Eval — run selection + Comparator.compare/2 render (GF-707)."

  use Phoenix.LiveView

  alias SpanChain.{Eval, Evals}
  alias SpanChain.Evals.Comparator

  # --------------------------------------------------------------------------
  # LiveView callbacks
  # --------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "GhostFactory Eval")
     |> assign(:view, :select)
     |> assign(:eval_id, nil)
     |> assign(:run_ids, [])
     |> assign(:run_a, nil)
     |> assign(:run_b, nil)
     |> assign(:summary, nil)
     |> assign(:diff, nil)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_params(
        %{"eval_id" => eval_id, "run_a" => run_a, "run_b" => run_b},
        _uri,
        socket
      )
      when run_a != "" and run_b != "" do
    case Comparator.compare(run_a, run_b) do
      {:ok, %{"summary" => summary, "differences" => diff}} ->
        {:noreply,
         socket
         |> assign(:view, :diff)
         |> assign(:eval_id, eval_id)
         |> assign(:run_a, run_a)
         |> assign(:run_b, run_b)
         |> assign(:summary, summary)
         |> assign(:diff, diff)
         |> assign(:page_title, "Eval / #{eval_id} / #{run_a} vs #{run_b}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:view, :error)
         |> assign(:eval_id, eval_id)
         |> assign(:error, error_message(reason))
         |> assign(:page_title, "Eval / #{eval_id} / error")}
    end
  end

  def handle_params(%{"eval_id" => eval_id}, _uri, socket) do
    case Evals.get_eval(eval_id) do
      nil ->
        {:noreply,
         socket
         |> assign(:view, :error)
         |> assign(:eval_id, eval_id)
         |> assign(:error, "Eval not found")
         |> assign(:page_title, "Eval / not found")}

      %Eval{} = eval ->
        run_ids = Enum.map(eval.runs, & &1.run_id)

        {:noreply,
         socket
         |> assign(:view, :select)
         |> assign(:eval_id, eval_id)
         |> assign(:run_ids, run_ids)
         |> assign(:run_a, nil)
         |> assign(:run_b, nil)
         |> assign(:diff, nil)
         |> assign(:summary, nil)
         |> assign(:error, nil)
         |> assign(:page_title, "Eval / #{eval_id}")}
    end
  end

  @impl true
  def handle_event("compare", %{"run_a" => run_a, "run_b" => run_b}, socket)
      when is_binary(run_a) and is_binary(run_b) and run_a != "" and run_b != "" do
    url =
      "/eval/#{socket.assigns.eval_id}?run_a=#{URI.encode_www_form(run_a)}&run_b=#{URI.encode_www_form(run_b)}"

    {:noreply, push_patch(socket, to: url)}
  end

  def handle_event("compare", _params, socket), do: {:noreply, socket}

  # --------------------------------------------------------------------------
  # Render — three views (pattern match on the :view assign)
  # --------------------------------------------------------------------------

  @impl true
  def render(%{view: :select} = assigns) do
    ~H"""
    <h1>Eval <span class="mono">{@eval_id}</span></h1>
    <p class="meta">{length(@run_ids)} runs in this eval.</p>

    <%= if @run_ids == [] do %>
      <p class="empty">
        No runs associated with this eval yet. POST a run with
        <code>resource.attributes["gf.eval_id"] = "{@eval_id}"</code> via
        <code>/v1/traces</code>.
      </p>
    <% else %>
      <form phx-submit="compare">
        <label>
          Run A:
          <select name="run_a">
            <option value="">— pick a run —</option>
            <%= for rid <- @run_ids do %>
              <option value={rid}>{rid}</option>
            <% end %>
          </select>
        </label>

        <label>
          Run B:
          <select name="run_b">
            <option value="">— pick a run —</option>
            <%= for rid <- @run_ids do %>
              <option value={rid}>{rid}</option>
            <% end %>
          </select>
        </label>

        <button type="submit">Compare</button>
      </form>
    <% end %>
    """
  end

  def render(%{view: :diff} = assigns) do
    ~H"""
    <div class="breadcrumb">
      <.link patch={"/eval/#{@eval_id}"}>← Back to eval</.link>
    </div>

    <h1>
      <span class="mono">{@run_a}</span> vs <span class="mono">{@run_b}</span>
    </h1>

    <p class="meta">
      A: {@summary["run_a"]["span_count"]} spans · {@summary["run_a"]["total_duration_ms"]}ms
      &nbsp;|&nbsp;
      B: {@summary["run_b"]["span_count"]} spans · {@summary["run_b"]["total_duration_ms"]}ms
      &nbsp;|&nbsp;
      {length(@diff)} differences
    </p>

    <%!-- GF-748: agent config diffs as a banner section (not a table row).
          Root-cause context BEFORE the span tree diffs. --%>
    <%= for d <- @diff, d["type"] == "config_diff" do %>
      <div class="config-diff-banner">
        <span class="label">⚙ Agent config diff</span>
        <span class="field"><code>{d["field"]}</code></span>
        <span class="val-a">{inspect(d["val_a"])}</span>
        <span class="arrow">→</span>
        <span class="val-b">{inspect(d["val_b"])}</span>
      </div>
    <% end %>

    <%= if @diff == [] do %>
      <p class="empty">✓ Identical runs — no differences detected.</p>
    <% else %>
      <table>
        <thead>
          <tr>
            <th></th>
            <th>Span</th>
            <th>Type</th>
            <th>Run A</th>
            <th>Run B</th>
            <th>Δ</th>
          </tr>
        </thead>
        <tbody>
          <%= for d <- @diff, d["type"] != "config_diff" do %>
            {render_diff_row(d)}
          <% end %>
        </tbody>
      </table>
    <% end %>
    """
  end

  def render(%{view: :error} = assigns) do
    ~H"""
    <div class="breadcrumb">
      <%= if @eval_id do %>
        <.link patch={"/eval/#{@eval_id}"}>← Back to eval</.link>
      <% end %>
    </div>
    <h1>Eval error</h1>
    <p class="error">{@error}</p>
    """
  end

  # --------------------------------------------------------------------------
  # Diff row rendering
  # --------------------------------------------------------------------------

  defp render_diff_row(diff) do
    assigns = %{
      span_name: diff["span_name"],
      type: diff["type"],
      deviation: diff["deviation_point"] == true,
      run_a_ms: diff["run_a_ms"],
      run_b_ms: diff["run_b_ms"]
    }

    ~H"""
    <tr>
      <td>
        <%= if @deviation do %>
          <span class="badge badge-error" title="deviation point">⚠</span>
        <% end %>
      </td>
      <td class="mono">{@span_name}</td>
      <td>
        {type_badge(@type)}
      </td>
      <td class="meta">
        <%= if @run_a_ms do %>{@run_a_ms}ms<% else %>—<% end %>
      </td>
      <td class="meta">
        <%= if @run_b_ms do %>{@run_b_ms}ms<% else %>—<% end %>
      </td>
      <td class="meta">
        <%= if @run_a_ms && @run_b_ms do %>{diff_pct(@run_a_ms, @run_b_ms)}%<% else %>—<% end %>
      </td>
    </tr>
    """
  end

  defp type_badge("duration_diff") do
    assigns = %{}
    ~H|<span class="badge badge-other">duration_diff</span>|
  end

  defp type_badge("span_added") do
    assigns = %{}
    ~H|<span class="badge badge-ok">span_added</span>|
  end

  defp type_badge("span_removed") do
    assigns = %{}
    ~H|<span class="badge badge-error">span_removed</span>|
  end

  defp type_badge(other) do
    assigns = %{label: to_string(other)}
    ~H|<span class="badge badge-other">{@label}</span>|
  end

  # round(abs(b - a) / max(a, 1) * 100) — symmetric with Comparator.significant_diff?
  defp diff_pct(a, b) when is_number(a) and is_number(b) do
    base = max(a, 1)
    round(abs(b - a) / base * 100)
  end

  defp diff_pct(_, _), do: 0

  # --------------------------------------------------------------------------
  # Error message formatting
  # --------------------------------------------------------------------------

  defp error_message(:run_not_found), do: "One or both runs not found in the Ledger."

  defp error_message(:different_eval),
    do: "These runs belong to different evals — cannot compare."

  defp error_message(other), do: "Comparison failed: #{inspect(other)}"
end
