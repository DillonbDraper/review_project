defmodule ReviewProjectWeb.Hologram.AccountMenu do
  @moduledoc """
  Header links to log in or sign up, or to the logged in user's settings and log out.

  Reads the `:current_scope` that `ReviewProjectWeb.Hologram.UserAuth` puts in the
  stash, so the page rendering it must declare that middleware.
  """
  use Hologram.Component
  use Hologram.JS

  alias ReviewProjectWeb.Hologram.UserAuth

  js_import from: "../../../assets/js/ui_dom.mjs", as: :DOM

  @impl Component
  def init(_props, component, server) do
    case get_stash(server, :current_scope) do
      %{user: %{email: email}} ->
        {csrf_token, server} = UserAuth.csrf_token(server)

        # Only what the template shows enters the component state, which is sent to the browser.
        state = [
          menu_open: false,
          email: email,
          icon_path: ReviewProjectWeb.Endpoint.static_path("/images/user_silhoutte.svg"),
          csrf_token: csrf_token
        ]

        {put_state(component, state), server}

      _ ->
        {put_state(component, menu_open: false, email: nil, icon_path: nil, csrf_token: nil),
         server}
    end
  end

  @impl Component
  def template do
    ~HOLO"""
    <nav id="account-menu" class="account-menu" aria-label="Account">
      {%if @email}
        {%if @menu_open}
          <document $key_down.escape.prevent_default="escape" />
          <window $blur="close" />
        {/if}
        <details id="profile-menu" class="profile-menu" open={@menu_open} $click_outside="close">
          <summary id="profile-menu-trigger" class="profile-trigger" aria-controls="profile-menu-popover" aria-expanded={if(@menu_open, do: "true", else: "false")} $click.prevent_default="toggle" $blur="check_focus_later">
            <span class="profile-avatar"><img src={@icon_path} alt="" width="16" height="16" /></span>
            <span id="account-email" class="account-email">{@email}</span>
          </summary>
          <div id="profile-menu-popover" class="profile-popover">
            <a id="account-settings" class="profile-item" href="/users/settings" $click="close" $blur="check_focus_later">User settings</a>
            <form id="log-out-form" action="/users/log-out" method="post">
              <input type="hidden" name="_method" value="delete" />
              <input type="hidden" name="_csrf_token" value={@csrf_token} />
              <button id="log-out" type="submit" class="profile-item" $click="close" $blur="check_focus_later">Log out</button>
            </form>
          </div>
        </details>
      {%else}
        <a id="log-in" class="header-link" href="/users/log-in">Log in</a>
        <a id="sign-up" class="header-button" href="/users/register">Sign up</a>
      {/if}
    </nav>
    """
  end

  @impl Component
  def action(:toggle, _params, component) do
    if component.state.email,
      do: put_state(component, :menu_open, not component.state.menu_open),
      else: component
  end

  def action(:close, _params, component), do: put_state(component, :menu_open, false)

  def action(:escape, _params, component) do
    if component.state.menu_open, do: JS.call(:DOM, :focus, ["profile-menu-trigger"])
    action(:close, %{}, component)
  end

  def action(:check_focus_later, _params, component) do
    # Blur fires before the browser has moved focus to its next destination.
    put_action(component, name: :check_focus, delay: 1)
  end

  def action(:check_focus, _params, component) do
    if component.state.menu_open and JS.call(:DOM, :focusWithin, ["profile-menu"]) == false,
      do: action(:close, %{}, component),
      else: component
  end
end
