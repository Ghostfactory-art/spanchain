import { evalScope, flush, init, shutdown } from "./client.js";
import { span, trace } from "./tracer.js";

export { init, evalScope, flush, shutdown, span, trace };
export type { GfConfig, SpanAttrs } from "./types.js";

// GF-735: OTel GenAI semantic convention constants for token cost tracking.
// Usage: import gf, { attrs } from "@ghostfactory/sdk";
//        gf.span("llm_call", { [attrs.GEN_AI_USAGE_INPUT_TOKENS]: 128 }, ...)
export * as attrs from "./attrs.js";

const gf = { init, evalScope, flush, shutdown, span, trace };
export default gf;
