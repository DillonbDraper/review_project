defmodule ReviewProjectWeb.EndpointSocketTest do
  use ExUnit.Case, async: false

  test "the compiled test endpoint excludes raw signaling but retains conference transport" do
    sockets = ReviewProjectWeb.Endpoint.__sockets__()
    refute List.keymember?(sockets, "/signaling", 0)

    assert {"/room-socket", ReviewProjectWeb.RoomSocket, _} =
             List.keyfind(sockets, "/room-socket", 0)
  end

  test "raw signaling registration compiles only in development" do
    # Compile the actual socket declaration and its enclosing conditional, without
    # booting the application or rewriting the running endpoint's BEAM files.
    {:defmodule, _, [_, [do: {:__block__, _, body}]]} =
      "lib/review_project_web/endpoint.ex" |> File.read!() |> Code.string_to_quoted!()

    declarations =
      Enum.filter(body, fn node ->
        {_node, sockets} =
          Macro.prewalk(node, [], fn
            {:socket, _, ["/signaling" | _]} = ast, acc -> {ast, [ast | acc]}
            ast, acc -> {ast, acc}
          end)

        sockets != []
      end)

    assert declarations != []

    for env <- [:dev, :prod, :test, :staging] do
      module = Module.concat(__MODULE__, env)

      declarations =
        Macro.prewalk(declarations, fn
          {{:., _, [{:__aliases__, _, [:Mix]}, :env]}, _, []} -> env
          ast -> ast
        end)

      try do
        Module.create(
          module,
          quote do
            use Phoenix.Endpoint, otp_app: :review_project
            unquote_splicing(declarations)
          end,
          Macro.Env.location(__ENV__)
        )

        sockets = module.__sockets__()

        if env == :dev do
          assert {"/signaling", Membrane.WebRTC.PhoenixSignaling.Socket, opts} =
                   List.keyfind(sockets, "/signaling", 0)

          assert opts[:websocket]
          assert opts[:longpoll] == false
        else
          refute List.keymember?(sockets, "/signaling", 0)
        end
      after
        :code.purge(module)
        :code.delete(module)
      end
    end
  end
end
