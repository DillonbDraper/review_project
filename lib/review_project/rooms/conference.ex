defmodule ReviewProject.Rooms.Conference do
  @moduledoc false

  def new, do: %{ready: false, microphone: false, camera: false, generation: 0}

  def update(current, %{"ready" => ready, "microphone" => microphone, "camera" => camera})
      when is_boolean(ready) and is_boolean(microphone) and is_boolean(camera) do
    if ready or not (microphone or camera) do
      {:ok,
       %{
         ready: ready,
         microphone: microphone,
         camera: camera,
         generation: current.generation + if(ready != current.ready, do: 1, else: 0)
       }}
    else
      {:error, :invalid_conference_state}
    end
  end

  def update(_current, _params), do: {:error, :invalid_conference_state}

  def valid_signal?(
        %{
          "negotiation_id" => negotiation_id,
          "type" => "description",
          "description" => %{"type" => type, "sdp" => sdp} = description
        } = data
      )
      when type in ["offer", "answer"] and is_binary(sdp) do
    valid_id?(negotiation_id) and map_size(data) == 3 and map_size(description) == 2 and
      byte_size(sdp) in 1..65_536 and byte_size(Jason.encode!(data)) <= 73_728
  end

  def valid_signal?(
        %{
          "negotiation_id" => negotiation_id,
          "type" => "candidate",
          "candidate" => %{"candidate" => candidate} = ice
        } = data
      )
      when is_binary(candidate) do
    valid_id?(negotiation_id) and map_size(data) == 3 and
      Enum.all?(Map.keys(ice), &(&1 in ~w(candidate sdpMid sdpMLineIndex usernameFragment))) and
      byte_size(candidate) <= 4096 and byte_size(Jason.encode!(data)) <= 8192 and
      optional_string?(ice["sdpMid"]) and optional_string?(ice["usernameFragment"]) and
      (is_nil(ice["sdpMLineIndex"]) or
         (is_integer(ice["sdpMLineIndex"]) and ice["sdpMLineIndex"] in 0..32))
  end

  def valid_signal?(_data), do: false

  defp valid_id?(value) when is_binary(value), do: byte_size(value) in 1..64
  defp valid_id?(_value), do: false
  defp optional_string?(nil), do: true
  defp optional_string?(value) when is_binary(value), do: byte_size(value) <= 256
  defp optional_string?(_value), do: false
end
