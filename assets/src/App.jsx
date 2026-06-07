// GF-792a — top-level shell: view + curRun state, masthead nav, and the Verify Ledger
// toast. GF-808 — App now owns `view`/`setView` and provides the 401 handler via
// OnUnauthorizedContext; Bureau holds the rest (it consumes the context through its hooks,
// so it must render *below* the Provider — App's own hooks couldn't read a Provider in
// their own JSX).
import { useState, useRef, useCallback } from 'react';
import Masthead from './components/masthead/Masthead';
import Trail from './components/trail/Trail';
import Dossier from './components/dossier/Dossier';
import Evals from './components/evals/Evals';
import Cassettes from './components/cassettes/Cassettes';
import System from './components/system/System';
import Connect from './components/connect/Connect';
import Toast from './components/ui/Toast';
import { useVerify } from './hooks/useVerify';
import { useCassettes } from './hooks/useCassettes';
import { useRuns } from './hooks/useRuns';
import { useEvals } from './hooks/useEvals';
import { deriveBadgeCount } from './hooks/deriveBadgeCount';
import { OnUnauthorizedContext } from './context/OnUnauthorizedContext';

const VIEWS = { trail: Trail, dossier: Dossier, evals: Evals, cassettes: Cassettes, system: System, connect: Connect };

export default function App() {
  const [view, setView] = useState(
    () => localStorage.getItem('gf_token') ? 'trail' : 'connect'
  );

  // GF-808 — the 401 handler (was the GF-806 module-slot body). Any apiFetch 401 below
  // the Provider clears the token and routes back to Connect, no page refresh. Stable
  // identity (empty deps) so consuming hooks' useCallbacks don't churn.
  const onUnauthorized = useCallback(() => {
    localStorage.removeItem('gf_token');
    setView('connect');
  }, []);

  return (
    <OnUnauthorizedContext.Provider value={onUnauthorized}>
      <Bureau view={view} setView={setView} />
    </OnUnauthorizedContext.Provider>
  );
}

function Bureau({ view, setView }) {
  const [curRun, setCurRun] = useState(null);
  const [toast, setToast] = useState('');
  const timer = useRef(null);
  const verify = useVerify();
  // Nav-badge data sources. Each tab keeps its own hook call (GF-792a: no shared store),
  // so these are separate instances from the views' own calls — the duplicate GET is
  // intentional. GF-814: cassettes; GF-816: trail (runs) + evals.
  const { total: cTotal, loading: cLoading, error: cError, retry: cRetry } = useCassettes();
  const { runs, loading: rLoading, error: rError, retry: rRetry } = useRuns();
  const { evals, loading: eLoading, error: eError, retry: eRetry } = useEvals();

  // GF-822 — surface a single retry control in the Masthead while any nav-badge source
  // is errored. error clears on each hook's next successful load (see loadRuns etc.), so
  // the false-outage amber chip disappears the moment the API actually recovers. `retrying`
  // disables the button during the in-flight refetch so repeat-clicks can't spam the API.
  const hasError = !!rError || !!eError || !!cError;
  const retrying = rLoading || eLoading || cLoading;
  const onRetry = useCallback(() => { rRetry(); eRetry(); cRetry(); }, [rRetry, eRetry, cRetry]);

  const showToast = useCallback((msg) => {
    setToast(msg);
    clearTimeout(timer.current);
    timer.current = setTimeout(() => setToast(''), 2600);
  }, []);

  const onRunSelect = (id) => { setCurRun(id); setView('dossier'); };
  const handleTokenSave = () => setView('trail');
  const onVerify = useCallback(async () => showToast(await verify(curRun)), [showToast, verify, curRun]);

  const View = VIEWS[view] || Trail;

  return (
    <>
      <Masthead
        view={view}
        onNav={setView}
        trailCount={deriveBadgeCount(runs, rLoading, !!rError)}
        evalCount={deriveBadgeCount(evals, eLoading, !!eError)}
        cassetteCount={cLoading ? null : cError ? 'error' : cTotal}
        hasError={hasError}
        retrying={retrying}
        onRetry={onRetry}
      />
      <main className="wrap page">
        <View curRun={curRun} onRunSelect={onRunSelect} onNav={setView} onVerify={onVerify} onTokenSave={handleTokenSave} />
      </main>
      <Toast message={toast} />
    </>
  );
}
