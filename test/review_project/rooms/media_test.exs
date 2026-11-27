defmodule ReviewProject.Rooms.MediaTest do
  use ExUnit.Case, async: true
  alias ReviewProject.Rooms.Media

  setup do
    root = Path.join(System.tmp_dir!(), Ecto.UUID.generate())
    on_exit(fn -> File.rm_rf!(root) end)

    server =
      start_supervised!(
        {Media,
         name: nil,
         root: root,
         max_uploads: 2,
         max_file_bytes: 1_073_741_824,
         free_bytes: fn _ -> {:ok, 3_000_000_000} end,
         probe: fn _ -> {:ok, %{mime: "video/mp4", duration: 1.0}} end}
      )

    %{server: server, root: root}
  end

  test "bounded bytes, safe metadata, private file and strict retiring slot", %{server: s} do
    assert {:ok, a} = Media.reserve("r", "../clip.mp4", 3, s)
    assert a.name == "clip.mp4"
    refute Map.has_key?(a, :path)
    assert {:error, :media_busy} = Media.reserve("r", "x", 1, s)
    assert :ok = Media.append("r", a.id, "abc", s)
    assert {:ok, %{mime: "video/mp4"}} = Media.finish("r", a.id, s)
    assert {:ok, reader} = Media.acquire("r", a.id, s)
    assert File.read!(reader.path) == "abc"
    assert {:error, :already_acquired} = Media.acquire("r", a.id, s)
    assert {:error, :media_busy} = Media.discard("r", s)
    assert_receive :media_retired
    assert File.exists?(reader.path)
    assert {:error, :media_busy} = Media.reserve("r", "x", 1, s)
    assert :ok = Media.release("r", a.id, s)
    refute File.exists?(reader.path)
    assert nil == Media.staged("r", s)
  end

  test "exact 1 GiB reservation boundary needs no allocation", %{server: s} do
    assert {:ok, a} = Media.reserve("r", <<255>>, 1_073_741_824, s)
    assert a.name == "video"
    assert {:error, :quota_exceeded} = Media.reserve("other", "x", 1, s)
    assert :ok = Media.cancel("r", a.id, s)
    assert {:error, :too_large} = Media.reserve("r", "x", 1_073_741_825, s)
  end

  test "ready fails closed for missing and symlink files", %{server: s, root: root} do
    for replacement <- [:missing, :symlink] do
      assert {:ok, a} = Media.reserve("r", "x", 1, s)
      assert :ok = Media.append("r", a.id, "x", s)
      assert {:ok, _} = Media.finish("r", a.id, s)
      path = Path.join(root, a.id <> ".stage")
      File.rm!(path)
      if replacement == :symlink, do: File.ln_s!("/etc/hosts", path)
      assert {:error, :unavailable} = Media.ready("r", a.id, s)
      assert nil == Media.staged("r", s)
    end
  end

  test "restart fence retains orphan descriptors until closed", %{server: s, root: root} do
    # Model a descriptor held by an old HTTP reader, including already-unlinked files.
    for deleted <- [false, true] do
      path = Path.join(root, "old.stage")
      File.write!(path, "old")
      {:ok, io} = File.open(path, [:read, :binary])
      if deleted, do: File.rm!(path)
      assert {:error, :media_busy} = Media.reserve("r", "x", 1, s)
      assert IO.binread(io, 3) == "old"
      File.close(io)
      assert {:ok, a} = Media.reserve("r", "x", 1, s)
      assert :ok = Media.cancel("r", a.id, s)
    end
  end

  test "startup preserves old open files and fences new uploads", %{root: root} do
    path = Path.join(root, "orphan.stage")
    File.write!(path, "old")
    {:ok, io} = File.open(path, [:read, :binary])
    assert :ok = stop_supervised(Media)

    s =
      start_supervised!(
        {Media, name: nil, root: root, free_bytes: fn _ -> {:ok, 2_000_000_000} end}
      )

    assert File.exists?(path)
    assert {:error, :media_busy} = Media.reserve("new", "x", 1, s)
    File.close(io)
    assert {:ok, _} = Media.reserve("new", "x", 1, s)
    refute File.exists?(path)
  end

  test "global quota and disk reserve include outstanding uploads", %{server: s} do
    :sys.replace_state(s, fn state ->
      %{
        state
        | opts:
            Keyword.merge(state.opts,
              max_total_bytes: 3,
              min_free_bytes: 10,
              free_bytes: fn _ -> {:ok, 13} end
            )
      }
    end)

    assert {:ok, a} = Media.reserve("one", "x", 2, s)
    assert {:error, :quota_exceeded} = Media.reserve("two", "x", 2, s)
    assert {:ok, _} = Media.reserve("two", "x", 1, s)

    :sys.replace_state(s, fn state ->
      %{state | opts: Keyword.put(state.opts, :free_bytes, fn _ -> {:ok, 10} end)}
    end)

    assert {:error, :insufficient_disk} = Media.append("one", a.id, "x", s)
    assert nil == Media.staged("one", s)
  end

  test "actual byte overflow and mismatch remove partial files", %{server: s, root: root} do
    assert {:ok, a} = Media.reserve("r", "x", 2, s)
    assert {:error, :too_large} = Media.append("r", a.id, "abc", s)
    assert File.ls!(root) == []
    assert {:ok, a} = Media.reserve("r", "x", 2, s)
    assert {:error, :size_mismatch} = Media.finish("r", a.id, s)
    assert nil == Media.staged("r", s)
  end

  test "quota and concurrency are reserved before bytes arrive", %{server: s} do
    assert {:ok, _} = Media.reserve("one", "x", 1, s)
    assert {:ok, _} = Media.reserve("two", "x", 1, s)
    assert {:error, :too_many_uploads} = Media.reserve("three", "x", 1, s)
    assert {:error, :too_large} = Media.reserve("large", "x", 1_073_741_825, s)
  end

  test "stalled validation is killed and pending finish is released", %{server: s, root: root} do
    parent = self()

    :sys.replace_state(s, fn state ->
      %{
        state
        | opts:
            Keyword.put(state.opts, :probe, fn path ->
              send(parent, {:probing, self(), Path.basename(path, ".stage")})

              receive do
                :never -> {:error, :invalid_media}
              end
            end)
      }
    end)

    task =
      Task.async(fn ->
        {:ok, a} = Media.reserve("r", "x", 1, s)
        :ok = Media.append("r", a.id, "x", s)
        Media.finish("r", a.id, s)
      end)

    assert_receive {:probing, worker, id}
    ref = Process.monitor(worker)
    send(s, {:probe_timeout, "r", id})
    assert {:error, :validation_failed} = Task.await(task)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    assert nil == Media.staged("r", s)
    assert [] == File.ls!(root)
  end

  test "private root rejects symlink ancestors", %{root: root} do
    link = root <> "-link"
    File.ln_s!(root, link)
    on_exit(fn -> File.rm(link) end)

    assert {:error, _} =
             start_supervised(
               Supervisor.child_spec(
                 {Media, name: nil, root: Path.join(link, "child")},
                 id: :unsafe_root
               )
             )
  end

  test "injected clock expires abandoned uploads" do
    root = Path.join(System.tmp_dir!(), Ecto.UUID.generate())
    on_exit(fn -> File.rm_rf!(root) end)
    clock = start_supervised!({Agent, fn -> 0 end})

    s =
      start_supervised!(
        Supervisor.child_spec(
          {Media,
           name: nil,
           root: root,
           clock: fn -> Agent.get(clock, & &1) end,
           free_bytes: fn _ -> {:ok, 2_000_000_000} end,
           upload_timeout_ms: 100},
          id: :expiry_media
        )
      )

    assert {:ok, _} = Media.reserve("r", "x", 1, s)
    Agent.update(clock, fn _ -> 100 end)
    assert :ok = Media.sweep(s)
    assert Media.staged("r", s) == nil
    assert File.ls!(root) == []
  end

  test "ownership and owner death cleanup", %{server: s} do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, a} = Media.reserve("r", "x", 1, s)
        send(parent, {:asset, a})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:asset, a}
    assert {:error, :not_owner_or_state} = Media.append("r", a.id, "a", s)
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    # A server barrier after observing its owner DOWN is deterministic via sys state.
    :sys.get_state(s)
    assert nil == Media.staged("r", s)
  end
end
