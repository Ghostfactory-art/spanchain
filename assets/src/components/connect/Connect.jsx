// GF-802 — Connect view: token entry gate. Keeps the GF-792a shell (section/phead/
// connect-grid); the .intake card is now a live token input and the .bp panel mirrors
// the connection state. Token entry is a <form> so Enter submits (onSubmit → handleConnect,
// preventDefault); "Připojit" is type="submit", the reveal toggle is type="button".
import { useState } from 'react';
import Button from '../ui/Button';

export default function Connect({ onTokenSave }) {
  const [tokenSet, setTokenSet] = useState(() => !!localStorage.getItem('gf_token'));
  const [inputVal, setInputVal] = useState('');
  const [revealed, setRevealed] = useState(false);

  const handleConnect = () => {
    if (inputVal.length < 1 || inputVal.length > 256) return;
    localStorage.setItem('gf_token', inputVal);
    setTokenSet(true);
    onTokenSave();
  };

  const handleDisconnect = () => {
    localStorage.removeItem('gf_token');
    setTokenSet(false);
    setInputVal('');
  };

  return (
    <section className="view active">
      <div className="phead">
        <div>
          <div className="ptag">05 — Setup</div>
          <h1>Connect <em>— submit records to the bureau</em></h1>
          <p className="sub">OTLP native, no SDK lock-in. Send via internal JSON <code>/ingest</code> or OpenTelemetry <code>/v1/traces</code>.</p>
        </div>
      </div>
      <div className="connect-grid">
        <div>
          <div className="intake">
            <div className="tab">Credentials</div>
            <h3>API token</h3>
            <p className="cdesc">Sent as <code>Authorization: Bearer &lt;token&gt;</code> on every ingest + domain route.</p>
            <div className="credcard">
              {tokenSet ? (
                <>
                  <span className="lbl" style={{ color: 'var(--green)' }}>●</span>
                  <span style={{ flex: 1 }}>Token nastaven</span>
                  <Button sm variant="ghost" onClick={handleDisconnect}>Odpojit</Button>
                </>
              ) : (
                <form
                  onSubmit={e => { e.preventDefault(); handleConnect(); }}
                  style={{ display: 'flex', alignItems: 'center', gap: '12px', flex: 1 }}
                >
                  <input
                    type={revealed ? 'text' : 'password'}
                    placeholder="Bearer token"
                    value={inputVal}
                    onChange={e => setInputVal(e.target.value)}
                    style={{ flex: 1, background: 'var(--paper)', border: 'none',
                             fontFamily: 'var(--font-mono)', fontSize: '0.85rem' }}
                  />
                  <Button sm variant="ghost" type="button" onClick={() => setRevealed(r => !r)}
                          title={revealed ? 'Skrýt' : 'Zobrazit'}>
                    {revealed ? '🙈' : '👁'}
                  </Button>
                  <Button sm variant="stamp" type="submit"
                          disabled={inputVal.length < 1 || inputVal.length > 256}>
                    Připojit
                  </Button>
                </form>
              )}
            </div>
          </div>
        </div>
        <div className="bp">
          <div className="bp-h">
            <div className="t">
              <b>{tokenSet ? 'CONNECTED' : 'SETUP'}</b>
              {' · '}{tokenSet ? 'bureau accepting records' : 'enter token to begin'}
            </div>
          </div>
          <div className="bp-b">
            {tokenSet ? (
              <div className="mut">
                Spans se odesílají na <code>/ingest</code> nebo <code>/v1/traces</code>.
                Přejdi na <strong>Trail</strong> pro přehled runů.
              </div>
            ) : (
              <div className="mut">
                Token najdeš v konfiguraci backendu (<code>GF_API_KEY</code> env var)
                nebo v <code>config/runtime.exs</code> pro dev.
              </div>
            )}
          </div>
        </div>
      </div>
    </section>
  );
}
