defmodule Archdo.Compiled.DiagramHelpers do
  @moduledoc false

  # Shared SVG helpers used by diagram generators.

  @bg "#1E1E2E"

  @doc """
  Wrap SVG element strings in a complete SVG document with standard header and footer.
  """
  @spec wrap_svg([String.t()], number(), number()) :: String.t()
  def wrap_svg(elements, width, height) do
    header = [
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{ceil(width)} #{ceil(height)}" width="#{ceil(width)}" height="#{ceil(height)}">),
      ~s(<rect width="100%" height="100%" fill="#{@bg}"/>),
      ~s(<style>),
      ~s(  text { user-select: none; }),
      ~s(</style>)
    ]

    footer = ["</svg>"]
    Enum.join(header ++ elements ++ footer, "\n")
  end

  @doc """
  Generate an error SVG with a red message.
  """
  @spec error_svg(String.t(), String.t()) :: String.t()
  def error_svg(message, error_color \\ "#F38BA8") do
    wrap_svg(
      [
        ~s(<text x="20" y="30" fill="#{error_color}" font-size="14" font-family="monospace">#{message}</text>)
      ],
      400,
      60
    )
  end
end
