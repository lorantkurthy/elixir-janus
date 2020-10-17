defmodule Janus.MockSession do
  use GenServer

  @impl true
  def init(pairs) do
    {:ok, %{pairs: pairs}}
  end

  @impl true
  def handle_call(
        {:execute_message, message, _timeout, _call_type},
        _from,
        %{pairs: pairs} = state
      ) do
    response = get_response(message, pairs)

    {:reply, response, state}
  end

  def handle_call(:get_session_id, _from, %{session_id: session_id} = state) do
    {:reply, session_id, state}
  end

  @impl true
  def handle_info(:keep_alive, state) do
    {:noreply, state}
  end

  defp get_response(payload, pairs) do
    case List.keytake(pairs, payload, 0) do
      nil ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}: payload's corresponding response has not been found, got: #{
                inspect(payload)
              }"

      {{_, response}, pairs} ->
        {response, pairs}
    end
  end
end
