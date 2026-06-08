defmodule SpanChain.Web.Layouts do
  @moduledoc "Root layout for the Phoenix Trail UI. Inline CSS, no Tailwind."

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>{assigns[:page_title] || "GhostFactory Trail"}</title>
        <style>
          * { box-sizing: border-box; }
          body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
              "Helvetica Neue", sans-serif;
            margin: 0;
            padding: 2rem;
            background: #0d1117;
            color: #c9d1d9;
            line-height: 1.5;
          }
          a { color: #58a6ff; text-decoration: none; }
          a:hover { text-decoration: underline; }
          h1 { color: #f0f6fc; font-weight: 600; margin: 0 0 1.5rem; }
          h2 { color: #f0f6fc; font-weight: 500; font-size: 1.2rem; margin: 1.5rem 0 .5rem; }
          .meta { color: #8b949e; font-size: 0.9rem; }
          table { border-collapse: collapse; width: 100%; max-width: 960px; }
          th, td {
            text-align: left;
            padding: .55rem .75rem;
            border-bottom: 1px solid #30363d;
            font-variant-numeric: tabular-nums;
          }
          th { color: #f0f6fc; font-weight: 600; font-size: 0.85rem; text-transform: uppercase; letter-spacing: 0.05em; }
          tr:hover td { background: #161b22; }
          code, .mono {
            font-family: "SF Mono", Consolas, "Liberation Mono", monospace;
            font-size: 0.9rem;
          }
          .tree { font-family: "SF Mono", Consolas, monospace; font-size: 0.92rem; }
          .tree ul { list-style: none; padding-left: 1.5rem; margin: 0; border-left: 1px solid #30363d; }
          .tree li { padding: .25rem 0; }
          .badge {
            display: inline-block;
            padding: 1px 6px;
            border-radius: 4px;
            font-size: 0.75rem;
            font-weight: 600;
            margin-left: .5rem;
          }
          .badge-ok       { background: #1f6f2c; color: #fff; }
          .badge-error    { background: #c52c39; color: #fff; }
          .badge-abandoned{ background: #6e7681; color: #fff; }
          .badge-other    { background: #30363d; color: #c9d1d9; }
          .empty { color: #8b949e; padding: 2rem 0; }
          .breadcrumb { margin-bottom: 1rem; color: #8b949e; }
          .breadcrumb a { color: #58a6ff; }
        </style>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
