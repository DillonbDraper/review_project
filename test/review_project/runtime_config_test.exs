defmodule ReviewProject.RuntimeConfigTest do
  use ExUnit.Case, async: false

  defp with_env(env, fun) do
    previous = Map.new(env, fn {key, _} -> {key, System.get_env(key)} end)

    try do
      set_env(env)
      fun.()
    after
      set_env(previous)
    end
  end

  defp set_env(env) do
    Enum.each(env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp config(env, overrides) do
    with_env(
      Map.merge(
        %{
          "DATABASE_URL" => "ecto://user:password@db.example.org/postgres",
          "SECRET_KEY_BASE" => String.duplicate("a", 64),
          "PHX_HOST" => "staging.example.org",
          "RESEND_API_KEY" => "test-resend-key",
          "DATABASE_SSL" => nil,
          "DATABASE_CA_CERT_FILE" => nil,
          "MIGRATION_DATABASE_URL" => nil,
          "ECTO_IPV6" => nil,
          "POOL_SIZE" => nil,
          "CONFERENCE_ICE_CONFIG" => nil,
          "GOOGLE_CLIENT_ID" => nil,
          "TURN_SPIKE_CONFIG" => nil,
          "UPLOADED_VIDEO_ENABLED" => nil,
          "UPLOADED_VIDEO_ROOT" => nil
        },
        overrides
      ),
      fn -> Config.Reader.read!("config/runtime.exs", env: env, target: :host) end
    )
  end

  test "production uploads are opt-in without raising the approved cap" do
    uploads = config(:prod, %{})[:review_project][:uploaded_video]
    refute uploads[:enabled]
    assert uploads[:root] == "/tmp/review-project-media"
    assert uploads[:max_file_bytes] == 1_073_741_824
    assert uploads[:max_total_bytes] == 1_073_741_824
    assert uploads[:max_uploads] == 1
    assert uploads[:min_free_bytes] == 1_073_741_824

    enabled =
      config(:prod, %{
        "UPLOADED_VIDEO_ENABLED" => "true",
        "UPLOADED_VIDEO_ROOT" => "/tmp/private-upload-test"
      })[:review_project][:uploaded_video]

    assert enabled[:enabled]
    assert enabled[:root] == "/tmp/private-upload-test"
    assert enabled[:max_file_bytes] == 1_073_741_824

    refute config(:prod, %{"UPLOADED_VIDEO_ENABLED" => "yes"})[:review_project][:uploaded_video][
             :enabled
           ]

    assert config(:test, %{})[:review_project][:uploaded_video] == nil
  end

  test "production TLS verifies the database hostname with system roots" do
    repo =
      config(:prod, %{"DATABASE_SSL" => "true", "ECTO_IPV6" => "true", "POOL_SIZE" => "3"})[
        :review_project
      ][ReviewProject.Repo]

    assert repo[:pool_size] == 3
    assert repo[:socket_options] == [:inet6]
    assert repo[:ssl][:verify] == :verify_peer
    assert repo[:ssl][:server_name_indication] == ~c"db.example.org"
    assert [_ | _] = repo[:ssl][:cacerts]
    assert is_function(repo[:ssl][:customize_hostname_check][:match_fun], 2)
  end

  test "TLS remains opt in and development/test repo configuration is untouched" do
    repo = config(:prod, %{})[:review_project][ReviewProject.Repo]
    assert repo[:ssl] == false
    assert repo[:pool_size] == 10
    assert repo[:socket_options] == []

    for env <- [:dev, :test] do
      refute Keyword.has_key?(
               config(env, %{"DATABASE_SSL" => "true"})[:review_project],
               ReviewProject.Repo
             )
    end
  end

  test "bundled public Supabase root has the approved identity and database-only trust" do
    path = "priv/certificates/supabase-root-ca.crt"
    pem = File.read!(path)

    assert Regex.match?(
             ~r/\A\s*-----BEGIN CERTIFICATE-----\s+[A-Za-z0-9+\/=\r\n]+-----END CERTIFICATE-----\s*\z/,
             pem
           )

    assert [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)

    assert Base.encode16(:crypto.hash(:sha256, der)) ==
             "807025AD50D4ED219D2C9C7D299C004F824EB00CF7F65AFEF607D07B72E6CAFA"

    cert = :public_key.pkix_decode_cert(der, :otp)
    tbs = elem(cert, 1)

    assert Enum.any?(elem(tbs, 10), fn extension ->
             match?({:Extension, {2, 5, 29, 19}, true, {:BasicConstraints, true, _}}, extension)
           end)

    repo =
      config(:prod, %{"DATABASE_SSL" => "true", "DATABASE_CA_CERT_FILE" => path})[
        :review_project
      ][ReviewProject.Repo]

    assert repo[:ssl][:cacerts] == [der | :public_key.cacerts_get()]
    assert repo[:ssl][:verify] == :verify_peer
    assert repo[:ssl][:server_name_indication] == ~c"db.example.org"

    refute :public_key.pkix_verify_hostname(cert, [{:dns_id, ~c"wrong.example.org"}],
             match_fun: repo[:ssl][:customize_hostname_check][:match_fun]
           )

    assert config(:prod, %{"DATABASE_CA_CERT_FILE" => path})[:review_project][ReviewProject.Repo][
             :ssl
           ] == false
  end

  @tag :tmp_dir
  test "custom CA augments system roots without weakening TLS", %{tmp_dir: tmp_dir} do
    der =
      case hd(:public_key.cacerts_get()) do
        {:cert, der, _decoded} -> der
        der when is_binary(der) -> der
      end

    path = Path.join(tmp_dir, "database-ca.pem")
    File.write!(path, :public_key.pem_encode([{:Certificate, der, :not_encrypted}]))

    repo =
      config(:prod, %{"DATABASE_SSL" => "true", "DATABASE_CA_CERT_FILE" => path})[
        :review_project
      ][ReviewProject.Repo]

    assert repo[:ssl][:cacerts] == [der | :public_key.cacerts_get()]
    assert repo[:ssl][:verify] == :verify_peer
    assert repo[:ssl][:server_name_indication] == ~c"db.example.org"
    assert is_function(repo[:ssl][:customize_hostname_check][:match_fun], 2)
  end

  @tag :tmp_dir
  test "unreadable and empty CA files fail closed", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "database-ca.pem")

    assert_raise File.Error, fn ->
      config(:prod, %{"DATABASE_SSL" => "true", "DATABASE_CA_CERT_FILE" => path})
    end

    File.write!(path, "not a certificate")

    assert_raise RuntimeError, ~r/must contain PEM certificates/, fn ->
      config(:prod, %{"DATABASE_SSL" => "true", "DATABASE_CA_CERT_FILE" => path})
    end
  end

  test "migration credentials do not replace runtime credentials" do
    repo =
      config(:prod, %{"MIGRATION_DATABASE_URL" => "ecto://migrator:secret@migrate.example.org/db"})[
        :review_project
      ][ReviewProject.Repo]

    assert repo[:url] == "ecto://user:password@db.example.org/postgres"
    assert ReviewProject.Release.migration_options(repo, nil) == []
  end

  test "migration override retains verified TLS and uses its own hostname" do
    repo = config(:prod, %{"DATABASE_SSL" => "true"})[:review_project][ReviewProject.Repo]
    url = "ecto://migrator:secret@migrate.example.org/db"
    opts = ReviewProject.Release.migration_options(repo, url)

    assert opts[:url] == url
    assert opts[:ssl] == Keyword.put(repo[:ssl], :server_name_indication, ~c"migrate.example.org")
    assert opts[:pool_size] == 2
    assert ReviewProject.Release.migration_options([ssl: false], url)[:ssl] == false

    assert_raise RuntimeError, ~r/must include a host/, fn ->
      ReviewProject.Release.migration_options(repo, "invalid")
    end
  end

  test "release migration refuses a running repository without changing configuration" do
    original = Application.fetch_env!(:review_project, ReviewProject.Repo)

    assert_raise RuntimeError, "Migrations require a stopped repository", fn ->
      ReviewProject.Release.migrate()
    end

    assert Application.fetch_env!(:review_project, ReviewProject.Repo) == original
  end

  test "production uses Resend with a configured product sender and Req" do
    runtime = config(:prod, %{})
    mailer = runtime[:review_project][ReviewProject.Mailer]
    assert mailer[:adapter] == Swoosh.Adapters.Resend
    assert mailer[:api_key] == "test-resend-key"
    base = Config.Reader.read!("config/config.exs", env: :prod, target: :host)
    assert base[:review_project][:mail_sender] == {"Review Project", "noreply@whatgrabsme.org"}
    refute Keyword.has_key?(runtime[:review_project], :mail_sender)

    prod = Config.Reader.read!("config/prod.exs", env: :prod, target: :host)
    assert prod[:swoosh][:api_client] == Swoosh.ApiClient.Req
  end

  test "production fails clearly without email configuration" do
    for value <- [nil, "", "  "] do
      assert_raise RuntimeError, ~r/RESEND_API_KEY is required/, fn ->
        config(:prod, %{"RESEND_API_KEY" => value})
      end
    end
  end

  test "email environment does not override development or test adapters and sender" do
    for env <- [:dev, :test] do
      runtime = config(env, %{"RESEND_API_KEY" => nil})
      refute Keyword.has_key?(runtime[:review_project], ReviewProject.Mailer)
      refute Keyword.has_key?(runtime[:review_project], :mail_sender)
    end

    assert Application.fetch_env!(:review_project, ReviewProject.Mailer)[:adapter] ==
             Swoosh.Adapters.Test
  end

  test "production requires an explicit public hostname" do
    assert_raise System.EnvError, fn -> config(:prod, %{"PHX_HOST" => nil}) end
  end
end
