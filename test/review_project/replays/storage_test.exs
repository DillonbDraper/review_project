defmodule ReviewProject.Replays.StorageTest do
  use ExUnit.Case, async: true
  alias ReviewProject.Replays.Storage

  setup do
    directory = Path.join(System.tmp_dir!(), "replay-storage-test-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "orphan.slp"), "orphan")

    storage =
      start_supervised!(
        {Storage,
         name: nil, directory: directory, headroom: 10, free_bytes: fn _ -> {:ok, 100} end}
      )

    on_exit(fn -> File.rm_rf!(directory) end)
    %{storage: storage, directory: directory, test_pid: self()}
  end

  test "startup removes orphans, reserves headroom and enforces room/node concurrency", ctx do
    assert File.ls!(ctx.directory) == []
    assert {:ok, first} = Storage.reserve("a", 40, self(), [], ctx.storage)
    assert {:error, :busy} = Storage.reserve("a", 1, self(), [], ctx.storage)
    assert {:error, :disk_full} = Storage.reserve("b", 51, self(), [], ctx.storage)
    assert {:ok, second} = Storage.reserve("b", 40, self(), [], ctx.storage)
    assert {:error, :busy} = Storage.reserve("c", 1, self(), [], ctx.storage)
    assert :ok = Storage.release(first.token, ctx.storage)
    assert :ok = Storage.release(second.token, ctx.storage)
    assert File.ls!(ctx.directory) == []
  end

  test "request death reclaims staging bytes", ctx do
    owner =
      start_supervised!(
        {Task,
         fn ->
           {:ok, reservation} = Storage.reserve("room", 20, ctx.test_pid, [], ctx.storage)
           send(ctx.test_pid, {:reservation, reservation})

           receive do
             :finish -> :ok
           end
         end}
      )

    assert_receive {:reservation, reservation}
    ref = Process.monitor(owner)
    send(owner, :finish)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}
    # DOWN messages from the same process are ordered, and the call fences the manager.
    _ = :sys.get_state(ctx.storage)
    assert Storage.stats(ctx.storage).active_transfers == 0
    refute File.exists?(reservation.path)
  end

  test "publication transfers lifetime to coordinator and rejects a cancelled reservation", ctx do
    {:ok, reservation} = Storage.reserve("room", 4, self(), [], ctx.storage)
    File.write!(reservation.path, "data")
    assert {:ok, path} = Storage.accept(reservation.token, ctx.storage)
    assert File.exists?(path)
    assert Storage.stats(ctx.storage).active_transfers == 0
    assert :ok = Storage.release(reservation.token, ctx.storage)
    refute File.exists?(path)
    assert {:error, :stale_selection} = Storage.accept(reservation.token, ctx.storage)
  end

  test "storage failure stops its dependent coordinators before orphan cleanup", ctx do
    children = [
      {Storage,
       name: __MODULE__.RestartedStorage,
       directory: ctx.directory <> "-restart",
       headroom: 0,
       free_bytes: fn _ -> {:ok, 100} end},
      {DynamicSupervisor, name: __MODULE__.Coordinators, strategy: :one_for_one}
    ]

    supervisor =
      start_supervised!(%{
        id: :restart_tree,
        start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]}
      })

    on_exit(fn -> File.rm_rf!(ctx.directory <> "-restart") end)

    {:ok, coordinator} =
      DynamicSupervisor.start_child(
        __MODULE__.Coordinators,
        {Agent,
         fn ->
           {:ok, reservation} =
             Storage.reserve("room", 4, self(), [], __MODULE__.RestartedStorage)

           File.write!(reservation.path, "data")
           {:ok, path} = Storage.accept(reservation.token, __MODULE__.RestartedStorage)
           path
         end}
      )

    path = Agent.get(coordinator, & &1)
    ref = Process.monitor(coordinator)
    Process.exit(Process.whereis(__MODULE__.RestartedStorage), :kill)
    assert_receive {:DOWN, ^ref, :process, ^coordinator, :shutdown}
    _ = :sys.get_state(supervisor)
    refute File.exists?(path)
    assert Storage.stats(__MODULE__.RestartedStorage).stored_bytes == 0
  end

  test "storage unavailability returns an operational error without exiting its caller" do
    assert {:error, :storage_unavailable} =
             Storage.reserve("room", 4, self(), [], :absent_replay_storage)

    assert {:error, :storage_unavailable} = Storage.accept("reservation", :absent_replay_storage)
  end
end
