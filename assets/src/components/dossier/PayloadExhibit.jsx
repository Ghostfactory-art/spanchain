// GF-792a — Exhibit panel: kv summary + payload for the selected span (ported from
// selSpan render). Payload is untrusted DB content; React escapes text children, so
// rendering it as a <pre> text node (NOT dangerouslySetInnerHTML) is XSS-safe by
// construction — the React-idiomatic equivalent of the original escapeHtml-then-innerHTML.
import { useSpanPayload } from '../../hooks/useSpanPayload';

export default function PayloadExhibit({ runId, span }) {
  const { payload, pending } = useSpanPayload(runId, span);

  if (!span) return <div className="mut">Select a span to inspect its payload.</div>;

  return (
    <>
      <dl className="kv">
        <dt>span_id</dt><dd className="cy">span#{span.hash}</dd>
        <dt>parent</dt><dd>{span.parent === 'null' ? <span className="mut">null · root</span> : 'span#' + span.parent}</dd>
        <dt>class</dt><dd>{span.status}</dd>
        <dt>timestamp</dt><dd>{span.ts}</dd>
        <dt>duration</dt><dd>{span.dur ? span.dur + ' ms' : '—'}</dd>
        <dt>prev_hash</dt><dd>{span.prev && span.prev !== 'null' ? '#' + span.prev : '—'}</dd>
        <dt>sha-256</dt><dd className={span.bad ? '' : 'g'}>{span.bad ? <span style={{ color: '#ff9b8a' }}>unverifiable</span> : '#' + span.hash + '…verified ✓'}</dd>
      </dl>
      <div className="payload">
        <div className="pl-l">Payload · canonical JSON</div>
        <pre className="code">{pending ? 'loading…' : payload}</pre>
      </div>
    </>
  );
}
