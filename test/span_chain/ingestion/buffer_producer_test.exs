defmodule SpanChain.Ingestion.BufferProducerTest do
  use ExUnit.Case, async: true

  alias SpanChain.Ingestion.BufferProducer

  defp fake_entry(i),
    do: %{run_id: "test", epoch_id: 0, seq: i, event_type: "x", payload: %{"i" => i}}

  defp start_isolated_buffer do
    name = String.to_atom("buf_test_#{System.unique_integer([:positive])}")
    {:ok, pid} = BufferProducer.start_link(name: name)
    on_exit_stop(pid)
    {pid, name}
  end

  defp on_exit_stop(pid) do
    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid), do: GenStage.stop(pid, :normal)
    end)
  end

  # The GenStage process state is wrapped in a %GenStage{state: my_state} wrapper —
  # extract our internal state map.
  defp my_state(pid), do: :sys.get_state(pid).state

  test "enqueue puts messages into the internal queue (without a consumer)" do
    {pid, name} = start_isolated_buffer()

    :ok = BufferProducer.enqueue(name, [fake_entry(1), fake_entry(2), fake_entry(3)])

    state = my_state(pid)
    assert :queue.len(state.queue) == 3
    assert state.demand == 0
  end

  test "FIFO — queue.out returns items in insertion order across multiple enqueue calls" do
    {pid, name} = start_isolated_buffer()

    :ok = BufferProducer.enqueue(name, [fake_entry(1)])
    :ok = BufferProducer.enqueue(name, [fake_entry(2), fake_entry(3)])
    :ok = BufferProducer.enqueue(name, [fake_entry(4)])

    state = my_state(pid)
    assert :queue.len(state.queue) == 4

    {seqs, _} =
      Enum.reduce(1..4, {[], state.queue}, fn _, {acc, q} ->
        {{:value, msg}, rest} = :queue.out(q)
        {acc ++ [msg.data.seq], rest}
      end)

    assert seqs == [1, 2, 3, 4]
  end

  test "messages are wrapped in a Broadway.Message with NoopAcknowledger" do
    {pid, name} = start_isolated_buffer()

    :ok = BufferProducer.enqueue(name, [fake_entry(99)])

    state = my_state(pid)
    {{:value, msg}, _rest} = :queue.out(state.queue)

    assert %Broadway.Message{} = msg
    assert msg.data.seq == 99
    # NoopAcknowledger requires the canonical {Mod, nil, nil} tuple — ack/3 fails
    # on a non-nil ack_ref. The init function returns the correct format.
    assert {Broadway.NoopAcknowledger, nil, nil} = msg.acknowledger
  end
end
