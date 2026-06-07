// GF-792a — one run rendered as a Records Bureau file card (ported from renderTrail).
import { runStatus, fmtTime } from '../../lib/format';
import Stamp from '../ui/Stamp';
import Ghost from '../ui/Ghost';

export default function FileCard({ run, onOpen }) {
  const st = runStatus(run);
  const id = run.run_id || '—';
  const spans = run.span_count != null ? run.span_count : '—';
  const broken = st === 'bad';
  return (
    <div className="filecard" onClick={() => onOpen(id)}>
      <div className="fc-tab">FILE Nº {String(id).slice(-4)}</div>
      <div className="fc-stamp"><Stamp status={st} /></div>
      <div className="fc-head">
        <div className="portrait"><div className="ph"><Ghost /></div></div>
        <div className="fc-id">
          <div className="rn">{id}</div>
          <div className="rm">{run.model || '—'}</div>
        </div>
      </div>
      <div className="fc-meta"><dl>
        <dt>Spans</dt><dd>{spans}</dd>
        <dt>Duration</dt><dd>—</dd>
        <dt>Last hash</dt><dd className="mut">—</dd>
        <dt>Filed</dt><dd>{fmtTime(run.inserted_at)}</dd>
      </dl></div>
      <div className="fc-foot">
        <div className="sig">{broken ? '⊘ broken' : 'verify_ledger'}<small>{broken ? 'chain not sealed' : 'hash-chain sealed'}</small></div>
        <div className="ds">FILED<br /><b>{fmtTime(run.inserted_at)}</b></div>
      </div>
    </div>
  );
}
