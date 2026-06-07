defmodule SpanChain.MixProject do
  use Mix.Project

  def project do
    [
      app: :span_chain,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      releases: releases(),
      deps: deps()
    ]
  end

  # GF-783: OTP release for Docker self-hosting. Name defaults to the app, so the
  # entrypoint calls bin/span_chain. Unix-only executables (Debian container).
  defp releases do
    [
      span_chain: [
        include_executables_for: [:unix],
        steps: [:assemble]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {SpanChain.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "docs.graph": ["docs.graph"],
      # GF-796: npm ci + Vite build → priv/static/app.js + app.css.
      # Mix.shell().cmd/1 runs through the OS shell (cmd.exe on Windows, sh on
      # Unix) so it can invoke npm.cmd, which a bare `cmd npm` (System.cmd /
      # spawn_executable) cannot on Windows. `--prefix assets` is shell-cwd-independent.
      "assets.deploy": [&npm_ci/1, &npm_build/1]
    ]
  end

  defp npm_ci(_), do: Mix.shell().cmd("npm ci --prefix assets")
  defp npm_build(_), do: Mix.shell().cmd("npm run build --prefix assets")

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},
      {:telemetry, "~> 1.3"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:corsica, "~> 2.0"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:broadway, "~> 1.0"},
      {:plug_attack, "~> 0.4"},
      {:dotenvy, "~> 0.8", only: [:dev, :test]}
    ]
  end
end
