// GF-792a — rubber-stamp / seal for a run status (uses STAMP/STAMPTX vocabulary).
import { STAMP, STAMPTX, normStatus } from '../../lib/format';

export default function Stamp({ status, mini }) {
  const st = normStatus(status);
  if (mini) return <span className={'seal-mini ' + STAMP[st]}>{STAMPTX[st]}</span>;
  return (
    <span className={'stamp ' + STAMP[st]}>
      {st === 'live' && <span className="d" />}
      {STAMPTX[st]}
    </span>
  );
}
