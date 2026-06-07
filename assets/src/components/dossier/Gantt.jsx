// GF-792a — timeline gantt (ported from d-gantt render). Bar width ∝ duration is a
// dynamic value, so an inline style is allowed here (per GF-792a conventions).
export default function Gantt({ spans }) {
  if (!spans.length) return null;
  const max = Math.max(...spans.map(s => s.dur), 1);
  return (
    <div className="gantt">
      {spans.map((s, i) => {
        const w = Math.max(2, (s.dur / max) * 100);
        const style = s.bad
          ? { width: w + '%', background: 'rgba(255,120,100,.4)', borderColor: '#ff9b8a' }
          : { width: w + '%' };
        return (
          <div className="grow2" key={i}>
            <span className="gl">{s.op.split(' · ')[0]}</span>
            <div className="gtrack"><div className="gbar" style={style}></div></div>
            <span className="gd">{s.dur ? s.dur + 'ms' : '—'}</span>
          </div>
        );
      })}
    </div>
  );
}
