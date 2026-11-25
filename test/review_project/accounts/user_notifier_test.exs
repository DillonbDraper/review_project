defmodule ReviewProject.Accounts.UserNotifierTest do
  use ExUnit.Case, async: false

  import Swoosh.TestAssertions

  alias ReviewProject.Accounts.{User, UserNotifier}

  test "all account emails use the configured sender and preserve their contents" do
    sender = {"ReviewProject", "noreply@whatgrabsme.org"}

    user = %User{email: "recipient@example.org"}
    url = "https://example.org/account/token"

    for {deliver, recipient, subject} <- [
          {&UserNotifier.deliver_update_email_instructions/2, user, "Update email instructions"},
          {&UserNotifier.deliver_login_instructions/2, user, "Confirmation instructions"},
          {&UserNotifier.deliver_login_instructions/2, %{user | confirmed_at: DateTime.utc_now()},
           "Log in instructions"}
        ] do
      assert {:ok, email} = deliver.(recipient, url)
      assert email.from == sender
      assert email.to == [{"", user.email}]
      assert email.subject == subject
      assert email.text_body =~ url
      assert_email_sent(email)
    end
  end

  test "local and test sender remains available without production configuration" do
    assert Application.fetch_env!(:review_project, :mail_sender) ==
             {"ReviewProject", "noreply@whatgrabsme.org"}
  end
end
