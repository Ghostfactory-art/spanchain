// GF-792a — one run as a register (table) row (7-col grid, ported from renderTrail).
import { runStatus, fmtTime } from '../../lib/format';

export default function RegisterRow({ run, index, total, onOpen }) {
  const st = runStatus(run);
  const id = run.run_id || '—';
  const spans = run.span_count != null ? run.span_count : '—';
  const no = String(total - index).padStart(3, '0');
  return (
    <div className="reg-row" data-run={id} onClick={() => onOpen(id)}>
      <span className="no">{no}</span>
      <span className="rid">{id} <span className="dim">· {run.model || '—'}</span></span>
      <span className="seal"><span className={'seal-mini ' + (st === 'bad' ? 'brk' : st === 'live' ? 'live' : 'ver')}>{st === 'bad' ? 'Chain broken' : st === 'live' ? 'In session' : 'Verified'}</span></span>
      <span className="num">{spans}</span>
      <span className="num dim">—</span>
      <span className="dim">—</span>
      <span className="num dim">{fmtTime(run.inserted_at)}</span>
    </div>
  );
}
