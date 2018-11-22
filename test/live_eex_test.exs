defmodule LiveEExTest do
  use ExUnit.Case, async: true

  def safe(do: {:safe, _} = safe), do: safe
  def unsafe(do: {:safe, content}), do: content

  test "escapes HTML" do
    template = """
    <start> <%= "<escaped>" %>
    """

    assert eval(template) == "<start> &lt;escaped&gt;\n"
  end

  test "escapes HTML from nested content" do
    template = """
    <%= LiveEExTest.unsafe do %>
      <foo>
    <% end %>
    """

    assert eval(template) == "\n  &lt;foo&gt;\n\n"
  end

  test "does not escape safe expressions" do
    assert eval("Safe <%= {:safe, \"<value>\"} %>") == "Safe <value>"
  end

  test "nested content is always safe" do
    template = """
    <%= LiveEExTest.safe do %>
      <foo>
    <% end %>
    """

    assert eval(template) == "\n  <foo>\n\n"

    template = """
    <%= LiveEExTest.safe do %>
      <%= "<foo>" %>
    <% end %>
    """

    assert eval(template) == "\n  &lt;foo&gt;\n\n"
  end

  test "handles assigns" do
    assert eval("<%= @foo %>", %{foo: "<hello>"}) == "&lt;hello&gt;"
  end

  test "supports non-output expressions" do
    template = """
    <% foo = @foo %>
    <%= foo %>
    """

    assert eval(template, %{foo: "<hello>"}) == "\n&lt;hello&gt;\n"
  end

  test "raises ArgumentError for missing assigns" do
    assert_raise ArgumentError,
                 ~r/assign @foo not available in eex template.*Available assigns: \[:bar\]/s,
                 fn -> eval("<%= @foo %>", %{bar: true}) end
  end

  defp eval(string, assigns \\ %{}) do
    %LiveEEx.Rendered{static: static, dynamic: dynamic} =
      EEx.eval_string(string, [assigns: assigns], file: __ENV__.file, engine: LiveEEx)

    static
    |> Enum.map(fn
      binary when is_binary(binary) -> binary
      integer when is_integer(integer) -> Map.fetch!(dynamic, integer)
    end)
    |> IO.iodata_to_binary()
  end
end
