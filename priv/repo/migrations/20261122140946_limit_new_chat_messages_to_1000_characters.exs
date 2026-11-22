defmodule ReviewProject.Repo.Migrations.LimitNewChatMessagesTo1000Characters do
  use Ecto.Migration

  def change do
    # Preserve previously accepted messages while enforcing the cap on new writes.
    create constraint(:chat_room_messages, :chat_room_messages_body_length,
             check: "char_length(body) <= 1000",
             validate: false
           )
  end
end
