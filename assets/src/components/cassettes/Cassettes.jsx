// GF-794 — Cassettes view: a tape library on the left, a replay station on the right.
// Replay POSTs through the pipeline under a fresh run_id and prints a receipt. There is
// no cassette-detail endpoint, so selected metadata comes from the already-loaded list
// and "Inspect payload" shows a local note rather than inventing a fetch.
import { useState } from 'react';
import { useCassettes } from '../../hooks/useCassettes';
import { useReplay } from '../../hooks/useReplay';
import Button from '../ui/Button';

const head = (
  <div className="phead">
    <div>
      <div className="ptag">03 — Deterministic replay</div>
      <h1>Cassettes <em>— replay the tape for $0</em></h1>
      <p className="sub">Snapshot a run's payload stream onto a cassette, then play it back through the same pipeline under a fresh run_id.</p>
    </div>
  </div>
);

export default function Cassettes() {
  const { cassettes, loading, error } = useCassettes();
  // GF-803: async replay state machine (idle→starting→polling→success|error).
  const { phase, result, error: replayError, startReplay, abort } = useReplay();
  const [selected, setSelected] = useState(null);
  const [playedId, setPlayedId] = useState(null);
  const [inspectNote, setInspectNote] = useState(false);

  const replaying = phase === 'starting' || phase === 'polling';

  const pick = (cas) => { setSelected(cas); setInspectNote(false); };

  const doReplay = (id) => { setPlayedId(id); startReplay(id); };

  if (loading) return <section className="view active">{head}<div className="ih">Loading cassettes…</div></section>;
  if (error) return <section className="view active">{head}<div className="ih" style={{ color: 'var(--stamp-red)' }}>Error: {error}</div></section>;
  if (!cassettes.length) return <section className="view active">{head}<div className="ih">No cassettes yet.</div></section>;

  const forSelected = selected && playedId === selected.id;
  const showReceipt = result && phase === 'success' && forSelected;

  return (
    <section className="view active">
      {head}
      <div className="cas-grid">
        <div className="tapes">
          {cassettes.map((c) => (
            <div
              key={c.id}
              className={'tape' + (selected && selected.id === c.id ? ' sel' : '')}
              data-cas={c.id}
              onClick={() => pick(c)}
            >
              <div className="label">
                <div className="nm">{c.name || c.id}</div>
                <div className="id">{c.id} · src {c.run_id}</div>
              </div>
              <div className="reels">
                <div className="reel"></div>
                <div className="win"></div>
                <div className="reel"></div>
              </div>
              <div className="meta">
                <span>{c.run_id}</span>
                <span>rec <b>{c.recorded_at || '—'}</b></span>
              </div>
            </div>
          ))}
        </div>

        <div className="station">
          <div className="tab">Replay station</div>
          {!selected ? (
            <p className="cdesc">Select a cassette to load it into the deck.</p>
          ) : (
            <>
              <h3>{(selected.name || selected.id) + ' · ' + selected.id}</h3>
              <p className="cdesc">Plays <b>{selected.run_id}</b> back through <b>SessionGenServer → Pipeline → Ledger</b> under a new run_id, then diffs the rebuilt tree against the source.</p>
              <div style={{ display: 'flex', gap: '10px', flexWrap: 'wrap' }}>
                <Button variant="stamp" sm disabled={replaying} onClick={() => doReplay(selected.id)}>
                  {phase === 'starting' ? '▶ Starting…' : phase === 'polling' ? '▶ Playing…' : '▶ Play cassette'}
                </Button>
                {replaying && (
                  <Button variant="ghost" sm onClick={abort}>Zrušit</Button>
                )}
                <Button variant="ghost" sm onClick={() => setInspectNote(true)}>Inspect payload</Button>
              </div>

              {inspectNote && (
                <p className="cdesc" style={{ marginTop: '12px' }}>Payload detail not available — no <code>GET /cassettes/:id</code> endpoint.</p>
              )}

              {replaying && forSelected && (
                <div className="receipt show">
                  <div className="rl">
                    <b>202 Accepted</b> · POST /cassettes/{selected.id}/replay<br />
                    {phase === 'starting' ? 'Starting replay…' : 'Replay in progress… (polling job)'}
                  </div>
                </div>
              )}

              {replayError && forSelected && (
                <div className="receipt show">
                  <div className="rl">
                    <b>{replayError.type === 'polling_timeout' ? 'timeout' : 'error'}</b> · POST /cassettes/{selected.id}/replay<br />
                    {replayError.message}
                  </div>
                </div>
              )}

              {showReceipt && (
                <div className="receipt show">
                  <div className="rl">
                    <b>completed ✓</b> · POST /cassettes/{selected.id}/replay<br />
                    run_id: <b>{result.run_id}</b><br />
                    span_count: <b>{result.span_count}</b> · hash_valid: <span className={result.hash_valid ? 'ok' : 'z'}>{result.hash_valid ? 'true ✓' : 'false ✗'}</span> · diff: <b>[{(result.diff || []).length}]</b><br />
                    cost: <span className="z">$0.00</span> — replayed from ledger, no LLM calls
                  </div>
                </div>
              )}
            </>
          )}
        </div>
      </div>
    </section>
  );
}
