// GF-792a — span tree list (ported from d-tree render); click selects a span.
// GF-794 — real hierarchy: depth is computed from each span's own `span_id` (GF-793)
// and its `parent` link, then rendered as the mockup's monospace tree prefix (.tw).

// span_id → depth lookup. Roots (parent 'null' or missing parent) are depth 0; each
// child is parent depth + 1. Memoized recursion — fine for normal traces (tens–hundreds
// of spans). Spans arrive in hash-chain order (parent before child) so no cycles.
function buildDepthMap(spans) {
  const depthMap = new Map();
  const spanById = new Map(spans.map(s => [s.span_id, s]));

  function getDepth(span) {
    if (!span || span.span_id == null) return 0;
    if (depthMap.has(span.span_id)) return depthMap.get(span.span_id);
    const parent = span.parent && span.parent !== 'null' ? spanById.get(span.parent) : null;
    const depth = parent ? getDepth(parent) + 1 : 0;
    depthMap.set(span.span_id, depth);
    return depth;
  }

  spans.forEach(getDepth);
  return depthMap;
}

export default function SpanTree({ spans, selected, onSelect }) {
  if (!spans?.length) return <div className="mut">No spans.</div>;
  // GF-797: surface legacy data (no span_id projection) instead of silently degrading
  // to a flat list. Empty/nullish spans already returned above, so spans is non-empty
  // here; optional chaining keeps the check crash-proof regardless.
  const hasHierarchy = spans?.some(s => s.span_id != null);
  const depthMap = buildDepthMap(spans);
  return (
    <div className="spantree">
      {!hasHierarchy && (
        <div
          className="legacy-banner"
          style={{
            fontFamily: 'var(--font-mono)', fontSize: '10px', letterSpacing: '.04em',
            color: 'var(--amber)', border: '1px solid var(--amber)',
            borderRadius: '2px', padding: '8px 10px', marginBottom: '12px'
          }}
        >
          ⚠ Span hierarchy unavailable — legacy data format (span_id missing)
        </div>
      )}
      {spans.map((s, i) => {
        const depth = depthMap.get(s.span_id) || 0;
        const tw = '│  '.repeat(depth) + (depth ? '└ ' : '');
        return (
          <div
            key={i}
            className={'snode' + (s.bad ? ' broken' : '') + (selected === i ? ' sel' : '')}
            data-span={s.hash}
            onClick={() => onSelect(i)}
          >
            <div className="nm"><span className="tw">{tw}</span><span className="lv">{s.lv}</span><span className="op">{s.op}</span></div>
            <div className="rt"><span className="dur">{s.dur ? s.dur + 'ms' : '—'}</span><span className="h">#{s.hash}</span></div>
          </div>
        );
      })}
    </div>
  );
}
