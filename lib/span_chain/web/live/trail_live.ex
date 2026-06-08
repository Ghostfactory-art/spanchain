defmodule SpanChain.Web.TrailLive do
  @moduledoc """
  LiveView for inspecting the hash-chain Ledger.

  - `/trail` (action `:index`) — list of runs (run_id, span count, times)
  - `/trail/:run_id` (action `:detail`) — tree visualization of spans,
    hierarchy from `parent_span_id`.

  Real-time auto-refresh via `Phoenix.PubSub`: the Pipeline broadcasts
  `{:run_updated, run_id}` on the topic `"runs"` and `{:spans_flushed, run_id}`
  on the topic `"run:RUN_ID"` after every successful batch insert.
  `handle_info/2` re-fetches the data with the same query as `handle_params/3`.
  """

  use Phoenix.LiveView

  import Ecto.Query

  alias SpanChain.{Ledger, Repo}

  @list_limit 50
  @pubsub SpanChain.PubSub

  # --------------------------------------------------------------------------
  # LiveView callbacks
  # --------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "GhostFactory Trail")
     |> assign(:subscribed_topic, nil)}
  end

  @impl true
  def handle_params(%{"run_id" => run_id}, _uri, socket) do
    socket = maybe_resubscribe(socket, "run:#{run_id}")
    detail = fetch_detail(run_id)

    {:noreply,
     socket
     |> assign(:view, :detail)
     |> assign(:run_id, run_id)
     |> assign(:row_count, detail.row_count)
     |> assign(:tree, detail.tree)
     |> assign(:page_title, "Trail / #{run_id}")}
  end

  def handle_params(_params, _uri, socket) do
    socket = maybe_resubscribe(socket, "runs")

    {:noreply,
     socket
     |> assign(:view, :index)
     |> assign(:runs, list_runs())
     |> assign(:list_limit, @list_limit)
     |> assign(:page_title, "GhostFactory Trail")}
  end

  # PubSub messages — re-fetch with the same query as handle_params; the fallback
  # clause covers a foreign run_id in the detail view + unknown messages.
  @impl true
  def handle_info({:run_updated, _run_id}, %{assigns: %{view: :index}} = socket) do
    {:noreply, assign(socket, :runs, list_runs())}
  end

  def handle_info(
        {:spans_flushed, run_id},
        %{assigns: %{view: :detail, run_id: run_id}} = socket
      ) do
    detail = fetch_detail(run_id)

    {:noreply,
     socket
     |> assign(:row_count, detail.row_count)
     |> assign(:tree, detail.tree)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --------------------------------------------------------------------------
  # Subscription management
  # --------------------------------------------------------------------------

  defp maybe_resubscribe(socket, new_topic) do
    current = socket.assigns[:subscribed_topic]

    cond do
      not connected?(socket) ->
        socket

      current == new_topic ->
        socket

      true ->
        if current, do: Phoenix.PubSub.unsubscribe(@pubsub, current)
        Phoenix.PubSub.subscribe(@pubsub, new_topic)
        assign(socket, :subscribed_topic, new_topic)
    end
  end

  # --------------------------------------------------------------------------
  # Render
  # --------------------------------------------------------------------------

  @impl true
  def render(%{view: :index} = assigns) do
    ~H"""
    <h1>GhostFactory Trail</h1>
    <p class="meta">Latest {@list_limit} runs from <code>ledger_entries</code>.</p>

    <%= if @runs == [] do %>
      <p class="empty">
        No runs in the Ledger yet. POST to <code>localhost:4000/ingest</code> or use
        <code>SpanChain.Harness</code>.
      </p>
    <% else %>
      <table>
        <thead>
          <tr>
            <th>Run ID</th>
            <th>Spans</th>
            <th>Errors</th>
            <th>Started</th>
            <th>Last seen</th>
            <th>Duration</th>
          </tr>
        </thead>
        <tbody>
          <%= for run <- @runs do %>
            <tr>
              <td>
                <.link patch={"/trail/#{run.run_id}"} class="mono">{run.run_id}</.link>
              </td>
              <td>{run.span_count}</td>
              <td>
                <%= if run.error_count > 0 do %>
                  <span class="badge badge-error">{run.error_count}</span>
                <% else %>
                  <span class="meta">0</span>
                <% end %>
              </td>
              <td class="meta">{format_dt(run.started_at)}</td>
              <td class="meta">{format_dt(run.ended_at)}</td>
              <td class="meta">{format_duration_ms(run.started_at, run.ended_at)}</td>
            </tr>
          <% end %>
        </tbody>
      </table>
    <% end %>
    """
  end

  def render(%{view: :detail} = assigns) do
    ~H"""
    <div class="breadcrumb"><.link patch="/trail">← All runs</.link></div>
    <h1 class="mono">{@run_id}</h1>
    <p class="meta">{@row_count} ledger rows</p>

    <%= if @tree == [] do %>
      <p class="empty">No rows for this run_id.</p>
    <% else %>
      <div class="tree">
        <ul>
          <%= for node <- @tree do %>
            {render_node(node)}
          <% end %>
        </ul>
      </div>
    <% end %>
    """
  end

  # --------------------------------------------------------------------------
  # Tree node rendering (separate function so we can recurse cleanly)
  # --------------------------------------------------------------------------

  defp render_node(node) do
    assigns = %{row: node.row, children: node.children}

    ~H"""
    <li>
      <span class="mono">{@row.event_type}</span>
      <span class="meta">
        seq={@row.seq} epoch={@row.epoch_id}
        <%= if d = duration_for(@row) do %>
          · {d}ms
        <% end %>
      </span>
      {status_badge(@row)}
      <%= if @children != [] do %>
        <ul>
          <%= for child <- @children do %>
            {render_node(child)}
          <% end %>
        </ul>
      <% end %>
    </li>
    """
  end

  defp status_badge(row) do
    status = get_in(row.payload, ["attributes", "status"])
    assigns = %{status: status}

    case status do
      "ok" ->
        ~H|<span class="badge badge-ok">ok</span>|

      "error" ->
        ~H|<span class="badge badge-error">error</span>|

      "abandoned" ->
        ~H|<span class="badge badge-abandoned">abandoned</span>|

      nil ->
        ~H||

      _other ->
        assigns = %{label: to_string(status)}
        ~H|<span class="badge badge-other">{@label}</span>|
    end
  end

  defp duration_for(%{payload: payload}) do
    cond do
      is_integer(payload["duration_ms"]) ->
        payload["duration_ms"]

      is_integer(get_in(payload, ["attributes", "duration_ms"])) ->
        get_in(payload, ["attributes", "duration_ms"])

      true ->
        compute_duration(payload["started_at"], payload["ended_at"])
    end
  end

  defp compute_duration(s, e) when is_binary(s) and is_binary(e) do
    with {:ok, started, _} <- DateTime.from_iso8601(s),
         {:ok, ended, _} <- DateTime.from_iso8601(e) do
      DateTime.diff(ended, started, :millisecond)
    else
      _ -> nil
    end
  end

  defp compute_duration(_, _), do: nil

  # --------------------------------------------------------------------------
  # Queries
  # --------------------------------------------------------------------------

  defp fetch_detail(run_id) do
    rows =
      from(l in Ledger,
        where: l.run_id == ^run_id,
        order_by: [asc: l.epoch_id, asc: l.seq]
      )
      |> Repo.all()

    %{run_id: run_id, row_count: length(rows), tree: build_tree(rows)}
  end

  defp list_runs do
    runs =
      from(l in Ledger,
        group_by: l.run_id,
        select: %{
          run_id: l.run_id,
          span_count: count(l.id),
          started_at: min(l.inserted_at),
          ended_at: max(l.inserted_at)
        },
        order_by: [desc: max(l.inserted_at)],
        limit: @list_limit
      )
      |> Repo.all()

    error_counts =
      from(l in Ledger,
        # GF-704: Postgres jsonb extraction (`->`/`->>`) instead of SQLite `json_extract`.
        # payload is :map → jsonb; `->'attributes'->>'status'` returns text or NULL.
        where: fragment("?->'attributes'->>'status' = 'error'", l.payload),
        group_by: l.run_id,
        select: {l.run_id, count(l.id)}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(runs, fn r ->
      Map.put(r, :error_count, Map.get(error_counts, r.run_id, 0))
    end)
  end

  # --------------------------------------------------------------------------
  # Tree construction from flat list (already ordered by epoch_id, seq)
  # --------------------------------------------------------------------------

  defp build_tree(rows) do
    by_parent = Enum.group_by(rows, & &1.parent_span_id)
    roots = Map.get(by_parent, nil, [])
    Enum.map(roots, &attach(&1, by_parent))
  end

  defp attach(row, by_parent) do
    span_id = get_in(row.payload, ["span_id"])
    children = if span_id, do: Map.get(by_parent, span_id, []), else: []
    %{row: row, children: Enum.map(children, &attach(&1, by_parent))}
  end

  # --------------------------------------------------------------------------
  # Formatting
  # --------------------------------------------------------------------------

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_dt(other), do: to_string(other)

  defp format_duration_ms(%DateTime{} = a, %DateTime{} = b) do
    case DateTime.diff(b, a, :millisecond) do
      ms when ms >= 0 -> "#{ms}ms"
      _ -> "—"
    end
  end

  defp format_duration_ms(_, _), do: "—"
end
