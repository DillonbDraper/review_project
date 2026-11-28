import { createMemo } from "solid-js";
import { For } from "solid-js/web";
import { useReplayStore } from "~/state/replayStore";
import { PlayerHUD } from "~/components/viewer/PlayerHUD";
import { Timer } from "~/components/viewer/Timer";

export function HUD() {
  const playerIndexes = createMemo(() =>
    useReplayStore()
      .replayData!.settings.playerSettings.filter(Boolean)
      .map((playerSettings) => playerSettings.playerIndex)
  );
  return (
    <>
      <Timer />
      <For each={playerIndexes()}>
        {(playerIndex) => <PlayerHUD player={playerIndex} />}
      </For>
    </>
  );
}
