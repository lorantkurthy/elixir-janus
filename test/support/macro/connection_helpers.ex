defmodule Janus.Support.Macro do
  defmacro assert_next_receive(pattern, timeout \\ 20000) do
    quote do
      receive do
        {[], {:ok, message}} ->
          assert ^unquote(pattern) = message
      after
        unquote(timeout) -> flunk("Response has not been received")
      end
    end
  end

  # macro generating test checking if event message handled by `Janus.Connection` module is passed to proper `Janus.Handler` callbacks
  # it used `FakeHandler.Payloads` mocked event messages and pass them through `Janus.Connection` which is supposed to pass them to proper `Janus.Handler` callbacks.
  # it uses `FakeHandler` callbacks to store last called callback in state, then it asserts that it was called for proper event type
  defmacro test_callback(event, index \\ 0) do
    fun = String.to_atom("handle_" <> Atom.to_string(event))

    quote do
      test "#{inspect(unquote(fun))} callback with payload nr #{unquote(index)}" do
        alias Janus.Connection
        alias Janus.Mock.Transport, as: MockTransport
        alias Janus.Support.FakeHandler
        alias Janus.Support.FakeHandler.Payloads

        state =
          state(
            transport_module: MockTransport,
            handler_module: FakeHandler,
            handler_state: %{callback: nil}
          )

        message = apply(Payloads, unquote(event), [unquote(index)])

        {:noreply, new_state} = Connection.handle_info(message, state)
        state(handler_state: %{callback: callback}) = new_state

        assert unquote(fun) == callback
      end
    end
  end
end
