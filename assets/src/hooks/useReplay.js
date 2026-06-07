// GF-803 — async replay polling hook. POST /api/cassettes/:id/replay returns
// 202 {job_id, status:"running"} (GF-798); we poll GET /api/cassettes/replay_jobs/:job_id
// via a recursive, self-rescheduling setTimeout (avoids fixed-interval stale closures) until
// the job flips to "completed" (→ result) or "failed" (→ error), with a timeout guard.
// GF-804 — adaptive backoff (see getInterval): the interval widens with attempt count so the
// MAX_ATTEMPTS cap stretches to ~2.6 min for long agent replays without extra chattiness.
//
// State machine: idle → starting → polling → success | error.
import { useState, useRef, useCallback, useEffect, useContext } from 'react';
import { apiFetch, UnauthorizedError } from '../api/client';
import { OnUnauthorizedContext } from '../context/OnUnauthorizedContext';

const MAX_ATTEMPTS = 40; // adaptive backoff (getInterval) ⇒ total cap ~2.6 min

// GF-804 — adaptive backoff: fast feedback for short replays, slower polling for long jobs.
// Tiers across MAX_ATTEMPTS=40 ⇒ total cap ~2.6 min (5×1500 + 10×3000 + 24×5000).
export const getInterval = (attempt) => {
  if (attempt < 5) return 1500;
  if (attempt < 15) return 3000;
  return 5000;
};

const INITIAL = { phase: 'idle', jobId: null, result: null, error: null, attempts: 0 };

export function useReplay() {
  const [state, setState] = useState(INITIAL);
  const onUnauthorized = useContext(OnUnauthorizedContext); // GF-808 — forwarded to every apiFetch below
  const timerRef = useRef(null);
  // Generation counter: bumped on every startReplay and on unmount. Any in-flight poll
  // whose `gen` no longer matches bails before touching state — so a stale poll (user
  // replays another cassette mid-poll, or the component unmounts) can't clobber the
  // current run or setState after unmount.
  const genRef = useRef(0);
  // Last enqueued job id — read by abort() without a stale closure (GF-823).
  const jobIdRef = useRef(null);

  useEffect(() => {
    return () => {
      genRef.current += 1;
      if (timerRef.current) clearTimeout(timerRef.current);
    };
  }, []);

  const poll = useCallback(async (jobId, attempt, gen) => {
    if (gen !== genRef.current) return;

    if (attempt >= MAX_ATTEMPTS) {
      setState((s) => ({
        ...s,
        phase: 'error',
        error: { type: 'polling_timeout', message: 'Replay timed out after ~2.6 min' }
      }));
      return;
    }

    try {
      const data = await apiFetch('/cassettes/replay_jobs/' + encodeURIComponent(jobId), { onUnauthorized });
      if (gen !== genRef.current) return;

      if (data.status === 'completed') {
        setState((s) => ({ ...s, phase: 'success', result: data.result, attempts: attempt }));
      } else if (data.status === 'failed') {
        setState((s) => ({
          ...s,
          phase: 'error',
          error: { type: 'replay_failed', message: (data.result && data.result.error) || 'Replay failed' },
          attempts: attempt
        }));
      } else if (data.status === 'cancelled') {
        // GF-823: cancelled (by abort() here or externally) — stop polling, not an error.
        jobIdRef.current = null;
        setState((s) => ({ ...s, phase: 'idle', attempts: attempt }));
      } else {
        // still running — schedule the next tick
        setState((s) => ({ ...s, attempts: attempt }));
        timerRef.current = setTimeout(() => poll(jobId, attempt + 1, gen), getInterval(attempt));
      }
    } catch (e) {
      if (gen !== genRef.current) return;
      if (e instanceof UnauthorizedError) return; // onUnauthorized already fired → Connect gate (GF-806/808/820)
      setState((s) => ({ ...s, phase: 'error', error: { type: 'server_error', message: e.message } }));
    }
  }, [onUnauthorized]);

  const startReplay = useCallback(
    async (cassetteId) => {
      if (!cassetteId) return;
      if (timerRef.current) clearTimeout(timerRef.current);
      jobIdRef.current = null;

      const gen = genRef.current + 1;
      genRef.current = gen;
      setState({ phase: 'starting', jobId: null, result: null, error: null, attempts: 0 });

      try {
        const data = await apiFetch(
          '/cassettes/' + encodeURIComponent(cassetteId) + '/replay',
          { method: 'POST', onUnauthorized }
        );
        if (gen !== genRef.current) return;
        jobIdRef.current = data.job_id;
        setState((s) => ({ ...s, phase: 'polling', jobId: data.job_id }));
        poll(data.job_id, 0, gen);
      } catch (e) {
        if (gen !== genRef.current) return;
        if (e instanceof UnauthorizedError) return; // onUnauthorized already fired → Connect gate (GF-806/808/820)
        setState((s) => ({ ...s, phase: 'error', error: { type: 'server_error', message: e.message } }));
      }
    },
    [poll, onUnauthorized]
  );

  // GF-823: stop polling, reset, and tell the backend to cancel the job. Best-effort DELETE
  // (404/409 terminal-race are fine; 401 routes to Connect via onUnauthorized, GF-808).
  const abort = useCallback(() => {
    if (timerRef.current) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
    genRef.current += 1; // invalidate any in-flight poll
    const id = jobIdRef.current;
    jobIdRef.current = null;
    setState(INITIAL);
    if (id) {
      apiFetch('/cassettes/replay_jobs/' + encodeURIComponent(id), { method: 'DELETE', onUnauthorized }).catch(() => {});
    }
  }, [onUnauthorized]);

  return {
    phase: state.phase,
    jobId: state.jobId,
    result: state.result,
    error: state.error,
    startReplay,
    abort
  };
}
