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
      {:phoenix_html, github: "phoenixframework/phoenix_html"}
    ]
  end
end
