defmodule Janus.Connection.Transaction do
  @moduledoc false
  alias Janus.DateTimeUtils

  @transaction_length 32
  @insert_tries 5

  @type call_type :: :keep_alive | :async_request | :sync_request

  require Logger
  # We use duplicate_bag as we ensure key uniqueness by ourselves and it is faster.
  # See https://www.phoenixframework.org/blog/the-road-to-2-million-websocket-connections
  @spec init_transaction_call_table(atom()) :: :ets.tab()
  def init_transaction_call_table(pending_calls_table \\ :pending_calls) do
    :ets.new(pending_calls_table, [:duplicate_bag, :private])
  end

  @spec insert_transaction(
          :ets.tab(),
          GenServer.from(),
          integer,
          call_type,
          DateTime.t(),
          integer,
          (non_neg_integer -> binary)
        ) :: binary

  def insert_transaction(
        pending_calls_table,
        from,
        timeout,
        type,
        timestamp \\ DateTimeUtils.utc_now(),
        tries \\ @insert_tries,
        transaction_generator \\ &:crypto.strong_rand_bytes/1
      )

  def insert_transaction(
        pending_calls_table,
        from,
        timeout,
        type,
        timestamp,
        tries,
        transaction_generator
      )
      when tries > 0 do
    transaction = generate_transaction!(transaction_generator)
    expires = expires_at(timestamp, timeout)

    if :ets.insert_new(pending_calls_table, {transaction, from, expires, type}) do
      transaction
    else
      "[#{__MODULE__} #{inspect(self())}] Generated already existing transaction: #{transaction}"
      |> Loggern.warning()

      insert_transaction(
        pending_calls_table,
        from,
        timeout,
        type,
        timestamp,
        tries - 1,
        transaction_generator
      )
    end
  end

  def insert_transaction(_pending_calls_table, _from, _timeout, _type, _timestamp, 0, _generator),
    do: raise("Could not insert transaction")

  defp expires_at(timestamp, timeout) do
    timestamp
    |> DateTime.add(timeout, :millisecond)
    |> DateTime.to_unix(:millisecond)
  end

  # Generates a transaction ID for the payload and ensures that it is unused
  @spec generate_transaction!((non_neg_integer -> binary)) :: binary
  defp generate_transaction!(transaction_generator) do
    transaction_generator.(@transaction_length) |> Base.encode64()
  end

  @spec transaction_status(:ets.tab(), binary, DateTime.t()) ::
          {:error, :outdated | :unknown_transaction} | {:ok, {GenServer.from(), call_type}}
  def transaction_status(pending_calls_table, transaction, timestamp \\ DateTimeUtils.utc_now()) do
    case :ets.lookup(pending_calls_table, transaction) do
      [{_transaction, from, expires_at, type}] ->
        if timestamp |> DateTime.to_unix(:millisecond) > expires_at do
          {:error, :outdated}
        else
          {:ok, {from, type}}
        end

      [] ->
        {:error, :unknown_transaction}
    end
  end

  @spec cleanup_old_transactions(:ets.tab(), DateTime.t()) :: boolean
  def cleanup_old_transactions(pending_calls_table, timestamp \\ DateTimeUtils.utc_now()) do
    require Ex2ms
    timestamp = timestamp |> DateTime.to_unix(:millisecond)

    match_spec =
      Ex2ms.fun do
        {_transaction, _from, expires_at, _type} -> expires_at < ^timestamp
      end

    case :ets.select_delete(pending_calls_table, match_spec) do
      0 ->
        Logger.debug("[#{__MODULE__} #{inspect(self())}] Cleanup: no outdated transactions found")
        false

      count ->
        "[#{__MODULE__} #{inspect(self())}] Cleanup: cleaned up #{count} outdated transaction(s)"
        |> Loggern.warning()

        true
    end
  end

  @spec handle_transaction({:ok, any} | {:error, any}, binary, :ets.tab()) :: :ok
  def handle_transaction(
        response,
        transaction,
        pending_calls_table,
        timestamp \\ DateTimeUtils.utc_now()
      ) do
    transaction_status = transaction_status(pending_calls_table, transaction, timestamp)

    case transaction_status do
      {:ok, {from, type}} ->
        if should_delete?(response, type) do
          GenServer.reply(from, response)
          :ets.delete(pending_calls_table, transaction)

          "Deleting transaction"
          |> build_log_message(transaction, response)
          |> Logger.debug()
        else
          "Keeping transaction, awaiting another response"
          |> build_log_message(transaction, response)
          |> Logger.debug()
        end

      {:error, :outdated} ->
        :ets.delete(pending_calls_table, transaction)

        "Deleting outdated transaction"
        |> build_log_message(transaction, response)
        |> Loggern.warning()

      {:error, :unknown_transaction} ->
        "Ignoring unknown transaction"
        |> build_log_message(transaction, response)
        |> Loggern.warning()
    end

    :ok
  end

  defp build_log_message(message, transaction, data) do
    "[#{__MODULE__} #{inspect(self())}] #{message}. id = #{inspect(transaction)}, received data = #{
      inspect(data)
    }"
  end

  defp should_delete?(response, type)
  defp should_delete?({:ok, %{"janus" => "ack"}}, :async_request), do: false
  defp should_delete?(_, _), do: true
end
