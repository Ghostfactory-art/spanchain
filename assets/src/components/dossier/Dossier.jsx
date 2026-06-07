// GF-792a — Dossier (run detail): consumes useRun, orchestrates the sub-panels and
// handles loading / error / empty states explicitly (ported from openRun, GF-791).
import { useEffect, useState } from 'react';
import { useRun } from '../../hooks/useRun';
import { replayBannerMessage } from '../../hooks/bannerUtils';
import Button from '../ui/Button';
import Ghost from '../ui/Ghost';
import HashChain from './HashChain';
import SpanTree from './SpanTree';
import Gantt from './Gantt';
import PayloadExhibit from './PayloadExhibit';

export default function Dossier({ curRun, onNav, onVerify }) {
  const { runData, loading, error, loadRun } = useRun();
  const [selected, setSelected] = useState(null);

  useEffect(() => { if (curRun) loadRun(curRun); }, [curRun, loadRun]);
  // Auto-select the last span once data arrives (matches GF-791 openRun behaviour).
  useEffect(() => {
    setSelected(runData && runData.spans.length ? runData.spans.length - 1 : null);
  }, [runData]);

  const head = (
    <div className="phead">
      <div>
        <div className="ptag">01 — The trail / opened file</div>
        <h1 style={{ fontSize: '30px' }}>Case <em>file</em></h1>
      </div>
      <div className="acts">
        <Button sm variant="ghost" onClick={() => onNav && onNav('trail')}>← Back to register</Button>
        <Button sm variant="stamp" onClick={() => onVerify && onVerify()}>⊛ Verify ledger</Button>
      </div>
    </div>
  );

  if (loading) return <section className="view active">{head}<div className="ih">Loading dossier…</div></section>;
  if (error) return <section className="view active">{head}<div className="ih" style={{ color: 'var(--stamp-red)' }}>Error: {error}</div></section>;
  if (!runData) return <section className="view active">{head}<div className="ih">Select a run from the Trail to open its dossier.</div></section>;

  const { id, started, spans, total, pass, verifiedCount, replayJob } = runData;
  if (!spans.length) return <section className="view active">{head}<div className="ih">No spans recorded for this run.</div></section>;

  const vcount = verifiedCount != null ? verifiedCount : spans.length;
  const selSpan = selected != null ? spans[selected] : null;

  return (
    <section className="view active">
      {head}
      <article className="dossier">
        <div className="d-tab">CASE FILE · run {String(id).slice(-4)}</div>
        <div className="filecopy">FILE COPY · DO NOT REMOVE</div>
        <div className={'d-stamp ' + (pass ? 'ver' : 'brk')}>
          <span className="sm">verify_ledger</span>
          <span className="big">{pass ? 'VERIFIED' : 'CHAIN BROKEN'}</span>
          <span className="sm">{pass ? vcount + '/' + vcount + ' sealed' : 'island attack'}</span>
        </div>
        <div className="d-head">
          <div className="d-portrait"><span className="c tl">04</span><span className="c br">L</span><div className="ph"><Ghost /></div></div>
          <div className="d-id">
            <div className="rn">{id}</div>
            <dl>
              <dt>Run</dt><dd>{id}</dd>
              <dt>Opened</dt><dd>{started}</dd>
              <dt>Spans</dt><dd>{spans.length} · {total} ms</dd>
              <dt>Verify</dt><dd>{vcount} checked</dd>
              <dt>Status</dt><dd className={pass ? 'g' : 'r'}>{pass ? 'sealed ✓' : 'chain broken ⊘'}</dd>
            </dl>
          </div>
        </div>
        <p className={'d-abstract' + (pass ? '' : ' bad')}>
          Run observed across <b>{spans.length} spans</b> in {total} ms. {pass
            ? <><code>verify_ledger</code> PASS — chain integrity intact, every span signed and linked to its predecessor.</>
            : <><code>verify_ledger</code> returns <code>{'{:error, :chain_broken}'}</code> — a middle epoch was deleted (Island Attack). Because prev_hash survives epoch rollover (GF-666) the gap is detectable.</>}
        </p>
        <div className="d-sig">
          <div className="s"><div className="ink">{pass ? 'verify_ledger ✓' : '⊘ unsealed'}</div><small>{pass ? 'hash-chain validated · self-hosted' : 'chain integrity failed'}</small></div>
          <div className="datestamp">Built<br /><b>BY YOU</b><br />MIT · 2026</div>
        </div>
      </article>

      <div className="bp" style={{ marginBottom: '18px' }}>
        <div className="bp-h">
          <div className="t"><b>HASH CHAIN</b> · exploded view</div>
          <div className="r">{pass ? 'SHA-256 · append-only' : 'CHAIN BROKEN'}</div>
        </div>
        <div className="bp-b"><HashChain spans={spans} /></div>
      </div>

      {(replayJob?.status === 'cancelled' || replayJob?.status === 'failed') && (
        <div
          className="run-cancelled-banner"
          style={{
            fontFamily: 'var(--font-mono)', fontSize: '10px', letterSpacing: '.04em',
            color: 'var(--amber)', border: '1px solid var(--amber)',
            borderRadius: '2px', padding: '8px 10px', marginBottom: '12px'
          }}
        >
          ⚠ Tento run pochází ze {replayBannerMessage(replayJob?.status)} replay jobu — data mohou být neúplná.
        </div>
      )}

      <div className="detail-grid">
        <div className="bp">
          <div className="bp-h"><div className="t"><b>SPAN TREE</b> · hierarchy</div><div className="r">tap a span →</div></div>
          <div className="bp-b">
            <SpanTree spans={spans} selected={selected} onSelect={setSelected} />
            <div style={{ marginTop: '16px', borderTop: '1px solid var(--print-rule-2)', paddingTop: '14px' }}>
              <div style={{ fontFamily: 'var(--font-mono)', fontSize: '9px', letterSpacing: '.14em', color: 'var(--print-mute)', marginBottom: '8px' }}>TIMELINE · relative duration</div>
              <Gantt spans={spans} />
            </div>
          </div>
        </div>
        <div className="bp">
          <div className="bp-h"><div className="t"><b>EXHIBIT</b> · <span className="cy">{selSpan ? 'span#' + selSpan.hash : '—'}</span></div><div className="r">signed entry</div></div>
          <div className="bp-b"><PayloadExhibit runId={id} span={selSpan} /></div>
        </div>
      </div>
    </section>
  );
}
