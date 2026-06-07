// GF-794 — Evals view: pick an eval, choose two of its runs, and diff them. Pure
// state + orchestration; all visualization lives in CompareTrees.
import { useState } from 'react';
import { useEvals } from '../../hooks/useEvals';
import { useEval } from '../../hooks/useEval';
import { useEvalCompare } from '../../hooks/useEvalCompare';
import Button from '../ui/Button';
import CompareTrees from './CompareTrees';

const head = (
  <div className="phead">
    <div>
      <div className="ptag">02 — Comparison</div>
      <h1>Evals <em>— two files, one verdict</em></h1>
      <p className="sub">Same task, N agents. Lay two case files side by side; the structural diff finds the exact span where they deviate.</p>
    </div>
  </div>
);

export default function Evals() {
  const { evals, loading, error } = useEvals();
  const [selectedEval, setSelectedEval] = useState(null);
  const [runA, setRunA] = useState('');
  const [runB, setRunB] = useState('');

  const { runs, loading: runsLoading } = useEval(selectedEval);
  const { result, loading: cmpLoading, error: cmpError, compare } = useEvalCompare();

  const pickEval = (id) => {
    setSelectedEval(id);
    setRunA('');
    setRunB('');
  };

  if (loading) return <section className="view active">{head}<div className="ih">Loading evals…</div></section>;
  if (error) return <section className="view active">{head}<div className="ih" style={{ color: 'var(--stamp-red)' }}>Error: {error}</div></section>;
  if (!evals.length) return <section className="view active">{head}<div className="ih">No evals yet.</div></section>;

  return (
    <section className="view active">
      {head}
      <div className="eval-layout">
        <div className="eval-index">
          <div className="ih">Open evals</div>
          {evals.map((e) => (
            <div
              key={e.id}
              className={'eitem' + (selectedEval === e.id ? ' active' : '')}
              data-eval={e.id}
              onClick={() => pickEval(e.id)}
            >
              <div className="en">{e.name || e.id}</div>
              <div className="ed">{e.id} · {e.status}</div>
            </div>
          ))}
        </div>

        <div>
          {!selectedEval ? (
            <div className="bp"><div className="bp-b"><div className="mut">Select an eval to compare its runs.</div></div></div>
          ) : (
            <>
              <div className="bp">
                <div className="bp-h"><div className="t"><b>COMPARE</b> · pick two runs</div><div className="r">{runsLoading ? 'loading runs…' : runs.length + ' runs'}</div></div>
                <div className="bp-b">
                  <div style={{ display: 'flex', gap: '12px', flexWrap: 'wrap', alignItems: 'center' }}>
                    <select value={runA} onChange={(ev) => setRunA(ev.target.value)}>
                      <option value="">run A…</option>
                      {runs.map((r) => <option key={r.run_id} value={r.run_id}>{r.run_id}</option>)}
                    </select>
                    <select value={runB} onChange={(ev) => setRunB(ev.target.value)}>
                      <option value="">run B…</option>
                      {runs.map((r) => <option key={r.run_id} value={r.run_id}>{r.run_id}</option>)}
                    </select>
                    <Button
                      variant="stamp"
                      sm
                      disabled={!runA || !runB || cmpLoading}
                      onClick={() => compare(selectedEval, runA, runB)}
                    >
                      {cmpLoading ? 'Comparing…' : '⊛ Compare'}
                    </Button>
                  </div>
                  {cmpError && <div className="mut" style={{ color: 'var(--stamp-red)', marginTop: '12px' }}>{cmpError}</div>}
                </div>
              </div>

              {result && (
                <CompareTrees
                  summary={result.summary}
                  differences={result.differences}
                  spansA={result.spansA}
                  spansB={result.spansB}
                  runA={result.run_a}
                  runB={result.run_b}
                />
              )}
            </>
          )}
        </div>
      </div>
    </section>
  );
}
