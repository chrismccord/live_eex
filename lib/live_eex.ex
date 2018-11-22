defmodule LiveEEx do
  @moduledoc """
  """

  defmodule Rendered do
    defstruct [:static, :dynamic]

    def to_iodata(%{static: static, dynamic: dynamic}) do
      to_iodata(static, dynamic, [])
    end

    defp to_iodata([static_head | static_tail], [dynamic_head | dynamic_tail], acc) do
      to_iodata(static_tail, dynamic_tail, [dynamic_head, static_head | acc])
    end

    defp to_iodata([static_head], [], acc) do
      Enum.reverse([static_head | acc])
    end
  end

  @behaviour EEx.Engine

  @impl true
  def init(_opts) do
    %{
      static: [],
      dynamic: [],
      vars_count: 0,
      root: true
    }
  end

  @impl true
  def handle_begin(state) do
    %{state | static: [], dynamic: [], root: false}
  end

  @impl true
  def handle_end(state) do
    %{static: static, dynamic: dynamic} = state
    safe = {:safe, Enum.reverse(static)}
    {:__block__, [], Enum.reverse([safe | dynamic])}
  end

  @impl true
  def handle_body(state) do
    %{static: static, dynamic: dynamic} = state

    binaries = reverse_static(static)
    dynamic = Enum.reverse(dynamic)

    vars =
      for {counter, _} when is_integer(counter) <- dynamic do
        var(counter)
      end

    block =
      Enum.map(dynamic, fn
        {:ast, ast} ->
          {ast, _} = analyze(ast)
          ast

        {counter, ast} ->
          var = var(counter)

          case analyze(ast) do
            {ast, []} ->
              quote do
                unquote(var) =
                  case __unchanged__ do
                    %{} -> nil
                    _ -> unquote(ast)
                  end
              end

            {ast, assigns} ->
              quote do
                unquote(var) =
                  case unquote(unchanged_assigns(assigns)) do
                    true -> nil
                    false -> unquote(ast)
                  end
              end
          end
      end)

    prelude =
      quote do
        __unchanged__ = Map.get(var!(assigns), :__unchanged__, nil)
      end

    rendered =
      quote do
        %LiveEEx.Rendered{static: unquote(binaries), dynamic: unquote(vars)}
      end

    {:__block__, [], [prelude | block] ++ [rendered]}
  end

  @impl true
  def handle_text(state, text) do
    %{static: static} = state
    %{state | static: [text | static]}
  end

  @impl true
  def handle_expr(%{root: true} = state, "=", ast) do
    %{static: static, dynamic: dynamic, vars_count: vars_count} = state
    tuple = {vars_count, to_safe(ast)}

    %{
      state
      | dynamic: [tuple | dynamic],
        static: [vars_count | static],
        vars_count: vars_count + 1
    }
  end

  def handle_expr(%{root: true} = state, "", ast) do
    %{dynamic: dynamic} = state
    %{state | dynamic: [{:ast, ast} | dynamic]}
  end

  def handle_expr(%{root: false} = state, "=", ast) do
    %{static: static, dynamic: dynamic, vars_count: vars_count} = state
    var = var(vars_count)
    ast = quote do: unquote(var) = unquote(to_safe(ast))
    %{state | dynamic: [ast | dynamic], static: [var | static], vars_count: vars_count + 1}
  end

  def handle_expr(%{root: false} = state, "", ast) do
    %{dynamic: dynamic} = state
    %{state | dynamic: [ast | dynamic]}
  end

  def handle_expr(state, marker, ast) do
    EEx.Engine.handle_expr(state, marker, ast)
  end

  ## Var handling

  defp var(counter) do
    Macro.var(:"arg#{counter}", __MODULE__)
  end

  ## Safe conversion

  defp to_safe(ast) do
    to_safe(ast, line_from_expr(ast))
  end

  defp line_from_expr({_, meta, _}) when is_list(meta), do: Keyword.get(meta, :line)
  defp line_from_expr(_), do: nil

  # We can do the work at compile time
  defp to_safe(literal, _line)
       when is_binary(literal) or is_atom(literal) or is_number(literal) do
    Phoenix.HTML.Safe.to_iodata(literal)
  end

  # We can do the work at runtime
  defp to_safe(literal, line) when is_list(literal) do
    quote line: line, do: Phoenix.HTML.Safe.List.to_iodata(unquote(literal))
  end

  # We need to check at runtime and we do so by
  # optimizing common cases.
  defp to_safe(expr, line) do
    # Keep stacktraces for protocol dispatch...
    fallback = quote line: line, do: Phoenix.HTML.Safe.to_iodata(other)

    # However ignore them for the generated clauses to avoid warnings
    quote generated: true do
      case unquote(expr) do
        {:safe, data} -> data
        bin when is_binary(bin) -> Plug.HTML.html_escape_to_iodata(bin)
        other -> unquote(fallback)
      end
    end
  end

  ## Traversal/analyzis

  defp reverse_static([dynamic | static]) when is_integer(dynamic),
    do: reverse_static(static, [""])

  defp reverse_static(static),
    do: reverse_static(static, [])

  defp reverse_static([static, dynamic | rest], acc)
       when is_binary(static) and is_integer(dynamic),
       do: reverse_static(rest, [static | acc])

  defp reverse_static([dynamic | rest], acc) when is_integer(dynamic),
    do: reverse_static(rest, ["" | acc])

  defp reverse_static([static], acc) when is_binary(static),
    do: [static | acc]

  defp reverse_static([], acc),
    do: ["" | acc]

  defp analyze(expr) do
    {expr, assigns} = Macro.prewalk(expr, %{}, &analyze/2)
    {expr, Map.keys(assigns)}
  end

  defp analyze({:@, meta, [{name, _, context}]}, assigns)
       when is_atom(name) and is_atom(context) do
    expr =
      quote line: meta[:line] || 0 do
        unquote(__MODULE__).fetch_assign!(var!(assigns), unquote(name))
      end

    {expr, Map.put(assigns, name, true)}
  end

  defp analyze(arg, assigns), do: {arg, assigns}

  defp unchanged_assigns(assigns) do
    assigns
    |> Enum.map(fn assign ->
      quote do: unquote(__MODULE__).unchanged_assign?(__unchanged__, unquote(assign))
    end)
    |> Enum.reduce(&{:and, [], [&1, &2]})
  end

  @doc false
  def unchanged_assign?(nil, _name) do
    false
  end

  def unchanged_assign?(unchanged, name) do
    case unchanged do
      %{^name => _} -> true
      _ -> false
    end
  end

  @doc false
  def fetch_assign!(assigns, key) do
    case Access.fetch(assigns, key) do
      {:ok, val} ->
        val

      :error ->
        raise ArgumentError, """
        assign @#{key} not available in eex template.

        Please make sure all proper assigns have been set. If this
        is a child template, ensure assigns are given explicitly by
        the parent template as they are not automatically forwarded.

        Available assigns: #{inspect(Enum.map(assigns, &elem(&1, 0)))}
        """
    end
  end
end
