defmodule Archdo.Mcp.SchemaValidator do
  @moduledoc false

  # Validates MCP tool arguments against the tool's declared JSON Schema.
  # Makes the input_schema/0 declarations load-bearing rather than decorative.

  @doc """
  Validate tool arguments against the tool's input schema.
  Returns `{:ok, arguments}` on success, `{:error, message}` on validation failure.
  """
  @spec validate(module(), map()) :: {:ok, map()} | {:error, String.t()}
  def validate(tool, arguments) when is_atom(tool) and is_map(arguments) do
    schema = tool.input_schema()

    case JSV.build(schema) do
      {:ok, root} ->
        case JSV.validate(arguments, root) do
          {:ok, validated} ->
            {:ok, validated}

          {:error, error} ->
            {:error, format_validation_error(error)}
        end

      {:error, build_error} ->
        # Schema build failure is a programming error — log and pass through
        IO.puts(:standard_error, "[archdo.mcp] schema build error: #{inspect(build_error)}")
        {:ok, arguments}
    end
  end

  defp format_validation_error(%JSV.ValidationError{} = error) do
    error
    |> JSV.normalize_error()
    |> format_normalized()
  end

  defp format_validation_error(error), do: "Validation failed: #{inspect(error)}"

  defp format_normalized(%{details: details}) when is_list(details) do
    details
    |> Enum.flat_map(fn
      %{errors: errors} when is_list(errors) -> errors
      _ -> []
    end)
    |> Enum.take(3)
    |> Enum.map_join("; ", &describe_error/1)
  end

  defp format_normalized(other), do: inspect(other)

  defp describe_error(%{message: message}) when is_binary(message), do: message
  defp describe_error(error), do: inspect(error)
end
