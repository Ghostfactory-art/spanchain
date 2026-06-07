// GF-792a — button vocabulary wrapper (.btn variants from app.css).
export default function Button({ variant = 'ghost', sm, className = '', children, ...rest }) {
  const cls = [
    'btn',
    variant === 'ink' && 'btn-ink',
    variant === 'ghost' && 'btn-ghost',
    variant === 'stamp' && 'btn-stamp',
    variant === 'blue' && 'btn-blue',
    sm && 'sm',
    className
  ].filter(Boolean).join(' ');
  return <button className={cls} {...rest}>{children}</button>;
}
