defmodule LiveEExTest do
  use ExUnit.Case, async: true

  def safe(do: {:safe, _} = safe), do: safe
  def unsafe(do: {:safe, content}), do: content

  describe "rendering" do
    test "escapes HTML" do
      template = """
      <start> <%= "<escaped>" %>
      """

      assert render(template) == "<start> &lt;escaped&gt;\n"
    end

    test "escapes HTML from nested content" do
      template = """
      <%= LiveEExTest.unsafe do %>
        <foo>
      <% end %>
      """

      assert render(template) == "\n  &lt;foo&gt;\n\n"
    end

    test "does not escape safe expressions" do
      assert render("Safe <%= {:safe, \"<value>\"} %>") == "Safe <value>"
    end

    test "nested content is always safe" do
      template = """
      <%= LiveEExTest.safe do %>
        <foo>
      <% end %>
      """

      assert render(template) == "\n  <foo>\n\n"

      template = """
      <%= LiveEExTest.safe do %>
        <%= "<foo>" %>
      <% end %>
      """

      assert render(template) == "\n  &lt;foo&gt;\n\n"
    end

    test "handles assigns" do
      assert render("<%= @foo %>", %{foo: "<hello>"}) == "&lt;hello&gt;"
    end

    test "supports non-output expressions" do
      template = """
      <% foo = @foo %>
      <%= foo %>
      """

      assert render(template, %{foo: "<hello>"}) == "\n&lt;hello&gt;\n"
    end

    test "raises ArgumentError for missing assigns" do
      assert_raise ArgumentError,
                   ~r/assign @foo not available in eex template.*Available assigns: \[:bar\]/s,
                   fn -> render("<%= @foo %>", %{bar: true}) end
    end
  end

  describe "rendered structure" do
    test "contains two static parts and one dynamic" do
      %{static: static, dynamic: dynamic} = eval("foo<%= 123 %>bar")
      assert dynamic == ["123"]
      assert static == ["foo", "bar"]
    end

    test "contains one static part at the beginning and one dynamic" do
      %{static: static, dynamic: dynamic} = eval("foo<%= 123 %>")
      assert dynamic == ["123"]
      assert static == ["foo", ""]
    end

    test "contains one static part at the end and one dynamic" do
      %{static: static, dynamic: dynamic} = eval("<%= 123 %>bar")
      assert dynamic == ["123"]
      assert static == ["", "bar"]
    end

    test "contains one dynamic only" do
      %{static: static, dynamic: dynamic} = eval("<%= 123 %>")
      assert dynamic == ["123"]
      assert static == ["", ""]
    end

    test "contains two dynamics only" do
      %{static: static, dynamic: dynamic} = eval("<%= 123 %><%= 456 %>")
      assert dynamic == ["123", "456"]
      assert static == ["", "", ""]
    end

    test "contains two static parts and two dynamics" do
      %{static: static, dynamic: dynamic} = eval("foo<%= 123 %><%= 456 %>bar")
      assert dynamic == ["123", "456"]
      assert static == ["foo", "", "bar"]
    end

    test "contains three static parts and two dynamics" do
      %{static: static, dynamic: dynamic} = eval("foo<%= 123 %>bar<%= 456 %>baz")
      assert dynamic == ["123", "456"]
      assert static == ["foo", "bar", "baz"]
    end
  end

  describe "change tracking" do
    test "does not render dynamic if it is unchanged" do
      assert unchanged("<%= @foo %>", %{foo: 123}, nil) == ["123"]
      assert unchanged("<%= @foo %>", %{foo: 123}, %{foo: true}) == [nil]
    end

    test "does not render dynamic without assigns" do
      assert unchanged("<%= 1 + 2 %>", %{}, nil) == ["3"]
      assert unchanged("<%= 1 + 2 %>", %{}, %{}) == [nil]
    end
  end

  defp eval(string, assigns \\ %{}) do
    EEx.eval_string(string, [assigns: assigns], file: __ENV__.file, engine: LiveEEx)
  end

  defp unchanged(string, assigns, unchanged) do
    %{dynamic: dynamic} = eval(string, Map.put(assigns, :__unchanged__, unchanged))
    dynamic
  end

  defp render(string, assigns \\ %{}) do
    string
    |> eval(assigns)
    |> LiveEEx.Rendered.to_iodata()
    |> IO.iodata_to_binary()
  end
end
