defmodule Phoenix.LiveView.Rendered do
  @moduledoc """
  The struct returned by .leex templates.

  See a description about its fields and use cases
  in `Phoenix.LiveView.Engine` docs.
  """

  defstruct [:static, :dynamic, :fingerprint]

  @type t :: %__MODULE__{
          static: [String.t()],
          dynamic: [String.t() | nil | t],
          fingerprint: binary()
        }

  defimpl Phoenix.HTML.Safe do
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
end

defmodule Phoenix.LiveView.Engine do
  @moduledoc """
  A EEx template engine that tracks changes.

  On the docs below, we will explain how it works internally.
  For user-facing documentation, see `Phoenix.LiveView`.

  ## User facing docs

  TODO: Move this to the Phoenix.live view module.

  `Phoenix.LiveView`'s built-in templates use the `.leex`
  extension. They are similar to regular `.eex` templates
  except they are designed to minimize the amount of data
  sent over the wire by tracking changes.

  When you first render a `.leex` template, it will send
  all of the static and dynamic parts of the template to
  the client. After that, any change you do on the server
  will now send only the dyamic parts and only if those
  parts have changed.

  The tracking of changes are done via assigns. Therefore,
  if part of your template does this:

      <%= something_with_user(@user) %>

  That particular section will be re-rendered only if the
  `@user` assign changes between events. Therefore, you
  MUST pass all of the data to your templates via assigns
  and avoid performing direct operations on the template
  as much as possible. For example, if you perform this
  operation in your template:

      <%= Repo.all(User) |> Enum.map(& &1.name) %>

  Then Phoenix will never re-render the section above, even
  if the amount of users in the database changes. Instead,
  you need to store the users as assigns in your LiveView
  before it renders the template:

      assign(socket, :users, Repo.all(User))

  Generally speaking, **data loading should never happen inside
  the template**, regardless if you are using LiveView or not.
  The difference is that LiveView` enforces those as best
  practices.

  Another restriction of LiveView is that, in order to track
  variables, it may make some macros incompatible with `.leex`
  templates. However, this would only happen if those macros
  are injecting or accessing user variables, which are not
  recommended in the first place. Overall, `.leex` templates
  do their best to be compatible with any Elixir code, sometimes
  even turning off optmiizations to keep compatibility.
  """

  @behaviour Phoenix.Template.Engine

  @impl true
  def compile(path, _name) do
    EEx.compile_file(path, engine: __MODULE__, line: 1, trim: true)
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

    # We compute the term to binary instead of passing all binaries
    # because we need to take into account the positions of dynamics.
    fingerprint =
      binaries
      |> :erlang.term_to_binary()
      |> :erlang.md5()

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
          ast
          |> analyze()
          |> to_conditional_var(var(counter))
      end)

    prelude =
      quote do
        __changed__ = Map.get(var!(assigns), :__changed__, nil)
      end

    rendered =
      quote do
        %Phoenix.LiveView.Rendered{
          static: unquote(binaries),
          dynamic: unquote(vars),
          fingerprint: unquote(fingerprint)
        }
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
    tuple = {vars_count, ast}

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
    ast = quote do: unquote(var) = unquote(to_safe(ast, []))
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

  defp to_safe(ast, extra_clauses) do
    to_safe(ast, line_from_expr(ast), extra_clauses)
  end

  defp line_from_expr({_, meta, _}) when is_list(meta), do: Keyword.get(meta, :line)
  defp line_from_expr(_), do: nil

  # We can do the work at compile time
  defp to_safe(literal, _line, _extra_clauses)
       when is_binary(literal) or is_atom(literal) or is_number(literal) do
    Phoenix.HTML.Safe.to_iodata(literal)
  end

  # We can do the work at runtime
  defp to_safe(literal, line, _extra_clauses) when is_list(literal) do
    quote line: line, do: Phoenix.HTML.Safe.List.to_iodata(unquote(literal))
  end

  # We need to check at runtime and we do so by
  # optimizing common cases.
  defp to_safe(expr, line, extra_clauses) do
    # Keep stacktraces for protocol dispatch...
    fallback = quote line: line, do: Phoenix.HTML.Safe.to_iodata(other)

    # However ignore them for the generated clauses to avoid warnings
    clauses =
      quote generated: true do
        {:safe, data} -> data
        bin when is_binary(bin) -> Plug.HTML.html_escape_to_iodata(bin)
        other -> unquote(fallback)
      end

    quote generated: true do
      case unquote(expr), do: unquote(extra_clauses ++ clauses)
    end
  end

  ## Static traversal

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

  ## Dynamic traversal

  @lexical_forms [:import, :alias, :require]

  defp analyze(expr) do
    case analyze(expr, false, %{}) do
      {expr, true, _assigns} -> {expr, :tainted}
      {expr, false, assigns} -> {expr, Map.keys(assigns)}
    end
  end

  defp analyze({:@, meta, [{name, _, context}]}, tainted, assigns)
       when is_atom(name) and is_atom(context) do
    expr =
      quote line: meta[:line] || 0 do
        unquote(__MODULE__).fetch_assign!(var!(assigns), unquote(name))
      end

    {expr, tainted, Map.put(assigns, name, true)}
  end

  # Vars always taint
  defp analyze({name, _, context} = expr, _tainted, assigns)
       when is_atom(name) and is_atom(context) do
    {expr, true, assigns}
  end

  # Lexical forms always taint
  defp analyze({lexical_form, _, [_]} = expr, _tainted, assigns)
       when lexical_form in @lexical_forms do
    {expr, true, assigns}
  end

  # with/for/fn never taint regardless of arity
  defp analyze({special_form, meta, args}, tainted, assigns)
       when special_form in [:with, :for, :fn] do
    {args, _tainted, assigns} = analyze_list(args, tainted, assigns, [])
    {{special_form, meta, args}, tainted, assigns}
  end

  # case/2 only taint first arg
  defp analyze({:case, meta, [expr, blocks]}, tainted, assigns) do
    {expr, tainted, assigns} = analyze(expr, tainted, assigns)
    {blocks, _tainted, assigns} = analyze(blocks, tainted, assigns)
    {{:case, meta, [expr, blocks]}, tainted, assigns}
  end

  # try/receive/cond/&/1 never taint
  defp analyze({special_form, meta, [blocks]}, tainted, assigns)
       when special_form in [:try, :receive, :cond, :&] do
    {blocks, _tainted, assigns} = analyze(blocks, tainted, assigns)
    {{special_form, meta, [blocks]}, tainted, assigns}
  end

  defp analyze({lexical_form, _, [_, _]} = expr, _tainted, assigns)
       when lexical_form in @lexical_forms do
    {expr, true, assigns}
  end

  defp analyze({left, meta, args}, tainted, assigns) do
    {left, tainted, assigns} = analyze(left, tainted, assigns)
    {args, tainted, assigns} = analyze_list(args, tainted, assigns, [])
    {{left, meta, args}, tainted, assigns}
  end

  defp analyze({left, right}, tainted, assigns) do
    {left, tainted, assigns} = analyze(left, tainted, assigns)
    {right, tainted, assigns} = analyze(right, tainted, assigns)
    {{left, right}, tainted, assigns}
  end

  defp analyze([_ | _] = list, tainted, assigns) do
    analyze_list(list, tainted, assigns, [])
  end

  defp analyze(other, tainted, assigns) do
    {other, tainted, assigns}
  end

  defp analyze_list([head | tail], tainted, assigns, acc) do
    {head, tainted, assigns} = analyze(head, tainted, assigns)
    analyze_list(tail, tainted, assigns, [head | acc])
  end

  defp analyze_list([], tainted, assigns, acc) do
    {Enum.reverse(acc), tainted, assigns}
  end

  @extra_clauses (quote do
                    %{__struct__: Phoenix.LiveView.Rendered} = other -> other
                  end)

  defp to_conditional_var({ast, :tainted}, var) do
    quote do: unquote(var) = unquote(to_safe(ast, @extra_clauses))
  end

  defp to_conditional_var({ast, []}, var) do
    quote do
      unquote(var) =
        case __changed__ do
          %{} -> nil
          _ -> unquote(to_safe(ast, @extra_clauses))
        end
    end
  end

  defp to_conditional_var({ast, assigns}, var) do
    quote do
      unquote(var) =
        case unquote(changed_assigns(assigns)) do
          true -> unquote(to_safe(ast, @extra_clauses))
          false -> nil
        end
    end
  end

  defp changed_assigns(assigns) do
    assigns
    |> Enum.map(fn assign ->
      quote do: unquote(__MODULE__).changed_assign?(__changed__, unquote(assign))
    end)
    |> Enum.reduce(&{:and, [], [&1, &2]})
  end

  @doc false
  def changed_assign?(nil, _name) do
    true
  end

  def changed_assign?(changed, name) do
    case changed do
      %{^name => _} -> false
      _ -> true
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
