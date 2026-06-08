/** Unix epoch nanoseconds as a string. JS number can't hold ns precision; OTLP requires string. */
export function nowNanoString(): string {
  return (BigInt(Date.now()) * 1_000_000n).toString();
}
