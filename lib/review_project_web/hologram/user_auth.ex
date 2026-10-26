defmodule ReviewProjectWeb.Hologram.UserAuth do
  @moduledoc """
  Authenticates Hologram pages and commands from the Phoenix session.

  `Hologram.Router` serves pages and commands from the endpoint, before the
  router's `:browser` pipeline, so `ReviewProjectWeb.UserAuth` never runs for
  them. Declare this middleware on Hologram pages and components instead:

      middleware ReviewProjectWeb.Hologram.UserAuth, :mount_current_scope

  ## Middleware options

    * `:mount_current_scope` - Puts the `:current_scope` in the stash based on
      the session's `user_token`, or nil if there's no user_token or no
      matching user.

    * `:require_authenticated` - Like `:mount_current_scope`, but redirects
      pages to the log in page and refuses commands if there's no logged user.

  The token is checked against the database on every page render and command,
  so a session that was logged out or expired is never trusted. Read the scope
  with `get_stash(server, :current_scope)` and pass it to context functions.

  Middleware only runs for the module that declares it. A component's commands
  run the component's middleware, not the page's.
  """
  use Hologram.Middleware

  alias ReviewProject.Accounts
  alias ReviewProject.Accounts.Scope

  @impl Hologram.Middleware
  def call(server, :mount_current_scope), do: mount_current_scope(server)

  def call(server, :require_authenticated) do
    server = mount_current_scope(server)

    if get_stash(server, :current_scope) do
      server
    else
      deny(server)
    end
  end

  @doc """
  Returns a CSRF token for forms posted to Phoenix routes, such as log out,
  and the server with the session state the token is checked against.

  Hologram pages are rendered outside of the router's `:protect_from_forgery`
  plug, so the token is derived from the Phoenix session in the same way.
  """
  def csrf_token(server) do
    state = Plug.CSRFProtection.dump_state_from_session(get_session(server, "_csrf_token"))

    # The state lives in the process dictionary, so first clear any token
    # generated for another session.
    Plug.CSRFProtection.delete_csrf_token()
    Plug.CSRFProtection.load_state(ReviewProjectWeb.Endpoint.config(:secret_key_base), state)
    token = Plug.CSRFProtection.get_csrf_token()

    case Plug.CSRFProtection.dump_state() do
      ^state -> {token, server}
      new_state -> {token, put_session(server, "_csrf_token", new_state)}
    end
  end

  defp mount_current_scope(%{stash: %{current_scope: _}} = server), do: server

  defp mount_current_scope(server) do
    user =
      with token when is_binary(token) <- get_session(server, :user_token),
           {user, _token_inserted_at} <- Accounts.get_user_by_session_token(token) do
        user
      else
        _ -> nil
      end

    put_stash(server, :current_scope, Scope.for_user(user))
  end

  # Only pages can redirect the browser. Commands are requests from a page
  # that is already open, so they are refused instead.
  defp deny(%{path: "/hologram/command"} = server), do: put_status(server, :forbidden)

  defp deny(server) do
    flash =
      server
      |> get_session("phoenix_flash", %{})
      |> Map.put("error", "You must log in to access this page.")

    server
    |> put_session("phoenix_flash", flash)
    |> maybe_store_return_to()
    |> put_redirect("/users/log-in")
  end

  # As in ReviewProjectWeb.UserAuth, only pages loaded with GET are returned to.
  # Hologram's client-side navigation fetches pages with POST.
  defp maybe_store_return_to(%{method: :get, path: path, raw_query: query} = server) do
    return_to = if query in [nil, ""], do: path, else: path <> "?" <> query
    put_session(server, :user_return_to, return_to)
  end

  defp maybe_store_return_to(server), do: server
end
