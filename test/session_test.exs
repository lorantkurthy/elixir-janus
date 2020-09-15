defmodule Janus.SessionTest do
  use ExUnit.Case
  alias Janus.{Session, Connection}
  alias Janus.HandlerTest.FakeHandler

  @timeout 100
  @session_id 1

  @request_response_pairs [
    {
      %{
        janus: :create
      },
      %{
        "janus" => "success",
        "data" => %{"id" => @session_id}
      }
    },
    {
      %{
        janus: :test,
        session_id: @session_id
      },
      %{
        "janus" => "success",
        "session_id" => @session_id,
        "data" => %{"session_id" => @session_id}
      }
    },
    {
      %{
        janus: :keepalive,
        session_id: @session_id
      },
      %{
        "janus" => "ack"
      }
    }
  ]

  setup do
    {:ok, connection} =
      Connection.start(Janus.MockTransport, @request_response_pairs, FakeHandler, {})

    %{connection: connection}
  end

  describe "Session should" do
    test "be created without error", %{connection: conn} do
      assert {:ok, session} = Session.start_link(conn, @timeout)
    end

    test "apply session_id to executed request", %{connection: conn} do
      {:ok, session} = Session.start_link(conn, @timeout)

      assert {:ok, %{"session_id" => @session_id}} =
               Session.execute_request(session, %{janus: :test})
    end

    test "send keep-alive message via connection after keep-alive interval given by connection module",
         %{
           connection: conn
         } do

      Application.put_env(:elixir_janus, Janus.MockTransport, [keepalive_interval: 100])

      {:ok, _session} = Session.start_link(conn, @timeout)

      interval = Janus.MockTransport.keepalive_interval()
      :erlang.trace(conn, true, [:receive])

      assert_receive {:trace, ^conn, :receive, %{"janus" => "ack"}}, 2 * interval
    end

    @tag :capture_log
    test "stop on connection exit", %{connection: conn} do
      {:ok, session} = Session.start(conn, @timeout)
      Process.monitor(session)
      Process.exit(conn, :kill)

      assert_receive {:DOWN, _ref, :process, ^session, {:connection, :killed}}, 5000
    end
  end
end
