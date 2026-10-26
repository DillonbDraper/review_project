defmodule ReviewProjectWeb.Hologram.AccountMenu do
  @moduledoc """
  Header links to log in or sign up, or to the logged in user's settings and log out.

  Reads the `:current_scope` that `ReviewProjectWeb.Hologram.UserAuth` puts in the
  stash, so the page rendering it must declare that middleware.
  """
  use Hologram.Component

  alias ReviewProjectWeb.Hologram.UserAuth

  @impl Component
  def init(_props, component, server) do
    case get_stash(server, :current_scope) do
      %{user: %{email: email}} ->
        {csrf_token, server} = UserAuth.csrf_token(server)

        # Only what the template shows enters the component state, which is sent to the browser.
        state = [
          email: email,
          initial: String.upcase(String.first(email)),
          csrf_token: csrf_token
        ]

        {put_state(component, state), server}

      _ ->
        {put_state(component, email: nil, initial: nil, csrf_token: nil), server}
    end
  end

  @impl Component
  def template do
    ~HOLO"""
    <nav id="account-menu" class="account-menu" aria-label="Account">
      {%if @email}
        <a id="account-settings" class="account-chip" href="/users/settings" title="Account settings">
          <span class="account-avatar" aria-hidden="true">{@initial}</span>
          <span id="account-email" class="account-email">{@email}</span>
        </a>
        <form id="log-out-form" action="/users/log-out" method="post">
          <input type="hidden" name="_method" value="delete" />
          <input type="hidden" name="_csrf_token" value={@csrf_token} />
          <button id="log-out" type="submit" class="header-link">Log out</button>
        </form>
      {%else}
        <a id="log-in" class="header-link" href="/users/log-in">Log in</a>
        <a id="sign-up" class="header-button" href="/users/register">Sign up</a>
      {/if}
    </nav>
    """
  end
end
