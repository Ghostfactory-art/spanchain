// GF-792a — horizontal hash-chain visualization (ported from d-hchain render).
// A link/arrow is flagged broken when its span has status === error.
import { Fragment } from 'react';

export default function HashChain({ spans }) {
  if (!spans.length) return <div className="mut">No chain.</div>;
  return (
    <div className="hchain">
      {spans.map((s, i) => {
        const next = spans[i + 1];
        return (
          <Fragment key={i}>
            <div className={'hbox' + (s.bad ? ' bad' : '')}>
              <div className="l">{s.lv} · {s.eventType}</div>
              <div className="hh">#{s.hash}</div>
              <div className="p">prev: {s.prev}</div>
            </div>
            {next && <div className={'harr' + (next.bad || s.bad ? ' bad' : '')}>{next.bad ? '⚠' : '→'}</div>}
          </Fragment>
        );
      })}
    </div>
  );
}
