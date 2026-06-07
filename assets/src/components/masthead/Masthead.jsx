// GF-792a — letterhead masthead: archive strip + brandlock + folder-tab navigation.
// Mirrors the GF-791 markup; the ghost-link mark and meta are static for this scaffold.
import Button from '../ui/Button';

// GF-814 + GF-816: Trail/Evals/Cassettes badges are all live (from each tab's API count
// via the *Count props below) — no hardcoded scaffold placeholders. System/Connect have no badge.
const TABS = [
  { view: 'trail', no: '01', name: 'Trail' },
  { view: 'evals', no: '02', name: 'Evals' },
  { view: 'cassettes', no: '03', name: 'Cassettes' },
  { view: 'system', no: '04', name: 'System' },
  { view: 'connect', no: '05', name: 'Connect' }
];

export default function Masthead({ view, onNav, trailCount, evalCount, cassetteCount, hasError, retrying, onRetry }) {
  // Detail/dossier shares the Trail tab's active state (as go() did in GF-791).
  const tabFor = view === 'dossier' ? 'trail' : view;
  // Per-view live badge counts; null/undefined (loading or no prop) → no badge.
  const counts = { trail: trailCount, evals: evalCount, cassettes: cassetteCount };
  return (
    <header className="masthead">
      <div className="mh-strip">
        <div className="wrap">
          <div className="l"><b>SPAN CHAIN</b> · GhostFactory Records Bureau</div>
          <div className="r">
            <span>MIT LICENSE</span><span>OTLP NATIVE</span><span>SELF-HOSTED</span><span>v0.24</span>
          </div>
        </div>
      </div>
      <div className="wrap mh-main">
        <div className="mh-row">
          <div className="brandlock">
            <svg className="mk" viewBox="0 0 80 80" aria-hidden="true">
              <defs>
                <mask id="mhm0"><rect width="80" height="80" fill="white" /><circle cx="14" cy="61" r="2.8" fill="black" /></mask>
                <mask id="mhm1"><rect width="80" height="80" fill="white" /><circle cx="42" cy="46" r="2.8" fill="black" /></mask>
                <mask id="mhm2"><rect width="80" height="80" fill="white" /><circle cx="36" cy="31" r="2.8" fill="black" /></mask>
                <mask id="mhm3"><rect width="80" height="80" fill="white" /><circle cx="64" cy="16" r="2.8" fill="black" /></mask>
              </defs>
              <rect x="6" y="56" width="46" height="10" rx="5" fill="#1d1a17" mask="url(#mhm0)" />
              <rect x="28" y="41" width="46" height="10" rx="5" fill="#1d1a17" mask="url(#mhm1)" />
              <rect x="6" y="26" width="46" height="10" rx="5" fill="#1d1a17" mask="url(#mhm2)" />
              <rect x="28" y="11" width="46" height="10" rx="5" fill="#1d1a17" mask="url(#mhm3)" />
            </svg>
            <div className="bt">
              <div className="ey">GHOSTFACTORY</div>
              <div className="nm">Span Chain <em>· records bureau</em></div>
            </div>
          </div>
          <div className="mh-meta">
            <div className="f"><div className="k">Filing date</div><div className="v">2026-05-29</div></div>
            <div className="f"><div className="k">Clerk</div><div className="v">jonesjiri</div></div>
            <div className="f"><div className="k">Ledger</div><div className="v">postgres:4000</div></div>
            <div className="f"><div className="k">Stream</div><div className="v live">● LIVE</div></div>
          </div>
        </div>
        <nav className="ftabs">
          {TABS.map(t => {
            const ct = counts[t.view];
            return (
              <button
                key={t.view}
                className={'ftab' + (t.view === tabFor ? ' active' : '')}
                data-view={t.view}
                onClick={() => onNav(t.view)}
              >
                <span className="no">{t.no}</span>{t.name}{typeof ct === 'number' && <span className="ct">{ct}</span>}{ct === 'error' && <span className="ct badge--error" title="API error">!</span>}
              </button>
            );
          })}
          {/* GF-822 — recover from a false-outage badge without a page refresh. Sits beside the
              amber chips (sibling of the tab buttons, never nested). disabled while a retry is
              in flight so repeat-clicks can't spam the API during a persistent outage. */}
          {hasError && (
            <Button variant="ghost" sm disabled={retrying} onClick={onRetry} title="Obnovit data po výpadku API">
              Zkusit znovu
            </Button>
          )}
        </nav>
      </div>
    </header>
  );
}
