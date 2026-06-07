// GF-794 — dumb-ish visualization for an A/B compare. Renders Exhibit A/B as real span
// trees (reusing SpanTree) with lazy payload inspection (same path as the Dossier), plus
// a verdict panel and the structural differences list. All data is props — no fetching.
import { useState } from 'react';
import SpanTree from '../dossier/SpanTree';
import PayloadExhibit from '../dossier/PayloadExhibit';

// First differences entry flagged as the deviation point (span tree diffs only; config
// diffs are pre-flight context and never carry the marker — see Comparator @moduledoc).
function deviationIndex(differences) {
  return differences.findIndex(d => d.deviation_point === true);
}

function diffLabel(d) {
  if (d.type === 'config_diff') {
    return d.field + ': ' + fmtVal(d.val_a) + ' → ' + fmtVal(d.val_b);
  }
  if (d.type === 'duration_diff') {
    return d.span_name + ' · ' + d.run_a_ms + 'ms → ' + d.run_b_ms + 'ms';
  }
  // span_added / span_removed
  return d.span_name + ' · ' + d.type.replace('span_', '');
}

function fmtVal(v) {
  return v == null ? '∅' : String(v);
}

export default function CompareTrees({ summary, differences, spansA, spansB, runA, runB }) {
  // One payload panel shared by both exhibits — selecting in one clears the other.
  const [sel, setSel] = useState(null); // { col: 'a'|'b', i }

  const diffs = differences || [];
  const sumA = (summary && summary.run_a) || {};
  const sumB = (summary && summary.run_b) || {};
  const devAt = deviationIndex(diffs);
  const delta = (sumB.total_duration_ms || 0) - (sumA.total_duration_ms || 0);
  const verdict = diffs.length ? 'diverged' : 'identical';

  const selA = sel && sel.col === 'a' ? sel.i : null;
  const selB = sel && sel.col === 'b' ? sel.i : null;
  const selSpan = sel ? (sel.col === 'a' ? spansA[sel.i] : spansB[sel.i]) : null;
  const selRunId = sel ? (sel.col === 'a' ? runA : runB) : null;

  return (
    <>
      <div className="bp" style={{ marginTop: '18px' }}>
        <div className="bp-h">
          <div className="t"><b>STRUCTURAL DIFF</b> · two files, one verdict</div>
          <div className="r">{verdict}</div>
        </div>
        <div className="bp-b">
          <div className="cmp-trees">
            <div className="ct-col">
              <div className="ct-h">EXHIBIT A · <b>{runA}</b></div>
              <SpanTree spans={spansA} selected={selA} onSelect={(i) => setSel({ col: 'a', i })} />
            </div>
            <div className="ct-col">
              <div className="ct-h">EXHIBIT B · <b>{runB}</b></div>
              <SpanTree spans={spansB} selected={selB} onSelect={(i) => setSel({ col: 'b', i })} />
            </div>
          </div>
        </div>
      </div>

      <div className="verdict">
        <div className="ds"><div className="k">Spans A / B</div><div className="v">{sumA.span_count != null ? sumA.span_count : '—'} / {sumB.span_count != null ? sumB.span_count : '—'}</div></div>
        <div className="ds"><div className="k">Deviation at</div><div className="v r">{devAt >= 0 ? 'diff ' + (devAt + 1) : 'none'}</div></div>
        <div className="ds"><div className="k">Duration Δ</div><div className={'v ' + (delta > 0 ? 'r' : 'g')}>{delta > 0 ? '+' : ''}{delta}ms</div></div>
        <div className="ds"><div className="k">Verdict</div><div className="v b">{verdict}</div></div>
      </div>

      <div className="bp" style={{ marginTop: '18px' }}>
        <div className="bp-h">
          <div className="t"><b>DIFFERENCES</b> · {diffs.length} entr{diffs.length === 1 ? 'y' : 'ies'}</div>
          <div className="r">deviation ▼</div>
        </div>
        <div className="bp-b">
          {diffs.length === 0
            ? <div className="mut">No structural differences — the runs are identical.</div>
            : diffs.map((d, i) => (
                <div key={i}>
                  {i === devAt && <div className="devmark">▼ deviation · diff {i + 1}</div>}
                  <div className={'crow' + (d.deviation_point ? ' dev' : '')}>
                    <span className="cn">{diffLabel(d)}</span>
                    <span className="cd">{d.type}</span>
                  </div>
                </div>
              ))}
        </div>
      </div>

      <div className="bp" style={{ marginTop: '18px' }}>
        <div className="bp-h">
          <div className="t"><b>EXHIBIT</b> · <span className="cy">{selSpan ? 'span#' + selSpan.hash : '—'}</span></div>
          <div className="r">{sel ? (sel.col === 'a' ? 'run A' : 'run B') : 'signed entry'}</div>
        </div>
        <div className="bp-b"><PayloadExhibit runId={selRunId} span={selSpan} /></div>
      </div>
    </>
  );
}
