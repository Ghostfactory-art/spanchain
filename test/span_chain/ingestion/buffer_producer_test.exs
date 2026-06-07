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

  # GenStage process state je obalen v %GenStage{state: my_state} wrapperu —
  # extrahuj naše interní state mapa.
  defp my_state(pid), do: :sys.get_state(pid).state

  test "enqueue puts messages do interní fronty (bez konzumenta)" do
    {pid, name} = start_isolated_buffer()

    :ok = BufferProducer.enqueue(name, [fake_entry(1), fake_entry(2), fake_entry(3)])

    state = my_state(pid)
    assert :queue.len(state.queue) == 3
    assert state.demand == 0
  end

  test "FIFO — queue.out vrací items v insertion order napříč více enqueue call" do
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

  test "messages jsou obaleny do Broadway.Message s NoopAcknowledger" do
    {pid, name} = start_isolated_buffer()

    :ok = BufferProducer.enqueue(name, [fake_entry(99)])

    state = my_state(pid)
    {{:value, msg}, _rest} = :queue.out(state.queue)

    assert %Broadway.Message{} = msg
    assert msg.data.seq == 99
    # NoopAcknowledger vyžaduje canonical {Mod, nil, nil} tuple — ack/3 selže
    # na non-nil ack_ref. Init function vrací správný format.
    assert {Broadway.NoopAcknowledger, nil, nil} = msg.acknowledger
  end
end
