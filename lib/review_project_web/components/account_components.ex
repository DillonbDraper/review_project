defmodule ReviewProjectWeb.AccountComponents do
  use ReviewProjectWeb, :html

  attr :email, :string, required: true

  def profile_menu(assigns) do
    ~H"""
    <details class="profile-menu" data-profile-menu>
      <summary id="profile-menu-trigger" class="profile-trigger" aria-controls="profile-menu-popover">
        <span class="profile-avatar">
          <img src={~p"/images/user_silhoutte.svg"} alt="" width="16" height="16" />
        </span>
        <span id="account-email" class="account-email">{@email}</span>
      </summary>
      <div id="profile-menu-popover" class="profile-popover">
        <.link id="account-settings" class="profile-item" href={~p"/users/settings"}>
          User settings
        </.link>
        <.form for={%{}} id="log-out-form" action={~p"/users/log-out"} method="delete">
          <button id="log-out" class="profile-item" type="submit">Log out</button>
        </.form>
      </div>
    </details>
    """
  end
end
