// GF-792a — Trail (run registry): file cards / register table with filter + search.
import { useState } from 'react';
import { useRuns } from '../../hooks/useRuns';
import { runStatus } from '../../lib/format';
import Button from '../ui/Button';
import FileCard from './FileCard';
import RegisterRow from './RegisterRow';

const CHIPS = [
  { key: 'all', label: 'All' },
  { key: 'ok', label: 'Verified' },
  { key: 'bad', label: 'Broken' },
  { key: 'live', label: 'Live' }
];

export default function Trail({ onRunSelect, onNav }) {
  const { runs, loading, error } = useRuns();
  const [filter, setFilter] = useState('all');
  const [mode, setMode] = useState('files');
  const [q, setQ] = useState('');

  const list = runs.filter(r => {
    if (filter !== 'all' && runStatus(r) !== filter) return false;
    if (q) {
      const hay = ((r.run_id || '') + ' ' + (r.model || '')).toLowerCase();
      return hay.includes(q.toLowerCase());
    }
    return true;
  });

  const count = (st) => runs.filter(r => runStatus(r) === st).length;
  const chipCount = (k) => (k === 'all' ? runs.length : count(k));

  return (
    <section className="view active" id="view-trail">
      <div className="phead">
        <div>
          <div className="ptag">01 — The trail</div>
          <h1>Register of <em>runs</em></h1>
          <p className="sub">Every agent run is filed as a signed dossier. Pull any file to read its span tree and verify the chain.</p>
        </div>
        <div className="acts">
          <Button sm variant="ghost" onClick={() => onNav && onNav('connect')}>File a record</Button>
        </div>
      </div>

      <div className="stats">
        <div className="stat b"><div className="k">Runs · total</div><div className="v">{runs.length}</div><div className="d">filed</div></div>
        <div className="stat g"><div className="k">Sealed / verified</div><div className="v">{count('ok')}</div><div className="d">chain intact</div></div>
        <div className="stat r"><div className="k">Chain broken</div><div className="v">{count('bad')}</div><div className="d">needs review</div></div>
        <div className="stat"><div className="k">Live</div><div className="v">{count('live')}</div><div className="d">in session</div></div>
      </div>

      <div className="slip">
        <span className="lab">Request slip</span>
        <div className="search">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="var(--mute-2)" strokeWidth="2"><circle cx="11" cy="11" r="7" /><path d="M21 21l-4-4" /></svg>
          <input value={q} onChange={e => setQ(e.target.value)} placeholder="run_id, model…" />
        </div>
        {CHIPS.map(c => (
          <button key={c.key} className={'chip' + (filter === c.key ? ' active' : '')} onClick={() => setFilter(c.key)}>
            {c.label} <span className="n">{chipCount(c.key)}</span>
          </button>
        ))}
        <div className="viewtog">
          <button className={mode === 'files' ? 'active' : ''} onClick={() => setMode('files')}>Files</button>
          <button className={mode === 'register' ? 'active' : ''} onClick={() => setMode('register')}>Register</button>
        </div>
      </div>

      {loading && <div className="ih">Loading runs…</div>}
      {error && <div className="ih" style={{ color: 'var(--stamp-red)' }}>Error: {error}</div>}
      {!loading && !error && (
        list.length === 0
          ? <div className="ih">No runs on file.</div>
          : mode === 'files'
            ? <div className="files">{list.map(r => <FileCard key={r.run_id} run={r} onOpen={onRunSelect} />)}</div>
            : <div className="register">
                <div className="reg-row head">
                  <span className="no">Nº</span><span>Entry</span><span>Seal</span><span>Spans</span><span>Dur</span><span>Last hash</span><span className="num">Filed</span>
                </div>
                {list.map((r, i) => <RegisterRow key={r.run_id} run={r} index={i} total={list.length} onOpen={onRunSelect} />)}
              </div>
      )}
    </section>
  );
}
