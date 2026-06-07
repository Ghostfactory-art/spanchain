// GF-792a — ghost portrait mark used inside file-card / dossier portraits (GF-791).
export default function Ghost() {
  return (
    <svg viewBox="0 0 80 80" aria-hidden="true">
      <path
        d="M 12 70 L 12 37 A 28 28 0 0 1 68 37 L 68 70 L 61 64 L 54 70 L 47 64 L 40 70 L 33 64 L 26 70 L 19 64 L 12 70 Z"
        fill="#f6f1e3"
      />
      <rect x="27.5" y="30" width="5" height="12" rx="2.5" fill="#1d1a17" />
      <rect x="47.5" y="30" width="5" height="12" rx="2.5" fill="#1d1a17" />
    </svg>
  );
}
