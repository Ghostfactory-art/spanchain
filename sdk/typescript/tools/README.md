# Tools

## eval-orchestrator.ts

Runs N evaluations against the same prompt, each associated with a given
`eval_id`. Uses the GhostFactory TypeScript SDK to emit traces via OTLP to
`/v1/traces`. `eval_id` propagates through
`resource.attributes["gf.eval_id"]` — required for EvalLive UI to group
runs correctly.

### Usage

```bash
# After `npm run build` in ../ghostfactory-ts-sdk/:
node dist/tools/eval-orchestrator.js \
  --eval-id my-eval-001 \
  --runs 3 \
  --prompt "Summarize this document" \
  --endpoint http://localhost:4000 \
  --api-key dev-secret-change-me
```

Defaults: `--runs 3`, `--endpoint http://localhost:4000`,
`--api-key ${GF_API_KEY:-dev-secret-change-me}`.
`--eval-id` and `--prompt` are required.

### View results

After all runs complete, open: `http://localhost:4001/eval/{eval-id}` (port
4001 is the Phoenix LiveView UI, not the API on 4000).

### Note

Dummy agent hookup (sleeps 100 ms per run + logs the prompt). Real agent
integration is L3 — wire your agent function inside the `gf.span("eval_run",
...)` callback in `eval-orchestrator.ts`.
