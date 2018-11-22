defmodule LiveEEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :live_eex,
      version: "0.1.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :eex]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:phoenix, "~> 1.4.1-dev", github: "phoenixframework/phoenix", branch: "v1.4"},
      {:phoenix_html, "~> 2.13", github: "phoenixframework/phoenix_html"},
      {:jason, ">= 0.0.0"}
    ]
  end
end
