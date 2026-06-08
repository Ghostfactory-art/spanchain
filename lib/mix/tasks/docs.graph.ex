defmodule Mix.Tasks.Docs.Graph do
  @moduledoc """
  Generates Obsidian `.md` files with `[[wikilinks]]` from `mix xref graph`.

  For each module it creates a file in `docs/graph/` with "Depends on"
  and "Depended on by" sections, so the Obsidian graph view shows the
  live dependency structure (unlike the manually maintained
  `docs/architecture-map.md` section 4).

  Run: `mix docs.graph`
  """

  use Mix.Task

  @shortdoc "Generates Obsidian wikilinks from mix xref graph"
  @output_dir "docs/graph"
  @xref_dot_path "_build/docs_graph_xref.dot"

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("Generating Obsidian wikilinks from mix xref graph...")

    File.mkdir_p!(Path.dirname(@xref_dot_path))

    Mix.Task.reenable("xref")
    Mix.Task.run("xref", ["graph", "--format", "dot", "--output", @xref_dot_path])

    case File.read(@xref_dot_path) do
      {:ok, dot} ->
        edges = parse_dot_edges(dot)
        modules = build_module_map(edges)
        slugs = build_slug_table(Map.keys(modules))
        File.mkdir_p!(@output_dir)

        Enum.each(modules, fn {mod, %{depends_on: deps, depended_on_by: by}} ->
          File.write!(
            Path.join(@output_dir, slugs[mod] <> ".md"),
            render_md(mod, deps, by, slugs)
          )
        end)

        File.rm(@xref_dot_path)
        Mix.shell().info("Generated #{map_size(modules)} files in #{@output_dir}/")

      {:error, reason} ->
        Mix.shell().error("Failed to read xref DOT output (#{inspect(reason)})")
        :ok
    end
  end

  # Filename slug: short name when unique, else `Parent.Short` to disambiguate
  # (e.g., 4× `Router` → `Cassettes.Router`, `Evals.Router`, `Ingestion.Router`, `Web.Router`).
  defp build_slug_table(modules) do
    by_short = Enum.group_by(modules, &module_short/1)

    Map.new(modules, fn mod ->
      slug =
        case by_short[module_short(mod)] do
          [_only] -> module_short(mod)
          _collision -> module_tail(mod, 2)
        end

      {mod, slug}
    end)
  end

  defp parse_dot_edges(dot) do
    ~r/"([^"]+)"\s*->\s*"([^"]+)"/
    |> Regex.scan(dot)
    |> Enum.map(fn [_, from, to] -> {path_to_module(from), path_to_module(to)} end)
    |> Enum.uniq()
  end

  defp build_module_map(edges) do
    all_modules =
      edges
      |> Enum.flat_map(fn {from, to} -> [from, to] end)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.reduce(all_modules, %{}, fn mod, acc ->
      deps =
        edges |> Enum.filter(fn {f, _} -> f == mod end) |> Enum.map(&elem(&1, 1)) |> Enum.sort()

      by =
        edges |> Enum.filter(fn {_, t} -> t == mod end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      Map.put(acc, mod, %{depends_on: deps, depended_on_by: by})
    end)
  end

  defp render_md(mod, depends_on, depended_on_by, slugs) do
    """
    # #{module_short(mod)}

    > `#{mod}`

    ## Depends on
    #{section(depends_on, slugs)}

    ## Depended on by
    #{section(depended_on_by, slugs)}
    """
  end

  defp section([], _slugs), do: "_none_"

  defp section(mods, slugs) do
    Enum.map_join(mods, "\n", fn mod -> "- #{wikilink(mod, slugs)}" end)
  end

  # Obsidian `[[Target|Display]]` — Display is always short name; Target may be
  # disambiguated slug. When they match, render as plain `[[Short]]`.
  defp wikilink(mod, slugs) do
    short = module_short(mod)
    slug = Map.get(slugs, mod, short)
    if slug == short, do: "[[#{short}]]", else: "[[#{slug}|#{short}]]"
  end

  defp module_short(mod), do: mod |> String.split(".") |> List.last()

  defp module_tail(mod, n) do
    mod |> String.split(".") |> Enum.take(-n) |> Enum.join(".")
  end

  # "lib/span_chain/ingestion/pipeline.ex" -> "SpanChain.Ingestion.Pipeline"
  defp path_to_module(path) do
    path
    |> String.replace_prefix("lib/", "")
    |> String.replace_suffix(".ex", "")
    |> String.split("/")
    |> Enum.map_join(".", &snake_to_camel/1)
  end

  defp snake_to_camel(segment) do
    segment
    |> String.split("_")
    |> Enum.map_join("", &String.capitalize/1)
  end
end
