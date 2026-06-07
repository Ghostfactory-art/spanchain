import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// GF-792a / GF-801 — Vite build for the Span Chain UI. Builds into Phoenix's
// priv/static with deterministic filenames (app.js / app.css).
//
// GF-801: the build entry is assets/index.html (Vite default — no rollupOptions.input
// override). Vite processes it, rewrites <script type="module" src="/src/main.jsx"> to
// the built /app.js, and injects the /app.css <link> (main.jsx imports app.css +
// tokens.css, so tokens are bundled into app.css). Output index.html lands in
// priv/static (gitignored, GF-796/801). emptyOutDir:false preserves the still-tracked
// priv/static/tokens.css (and anything else non-build) from being wiped.
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: '../priv/static',
    emptyOutDir: false,
    rollupOptions: {
      output: {
        entryFileNames: 'app.js',
        chunkFileNames: 'app-[name].js',
        assetFileNames: 'app.[ext]'   // → app.css
      }
    }
  },
  assetsInlineLimit: 0,  // tokens.css nesmí být inlinován jako data URI
  server: {
    port: 5173,
    proxy: {
      '/api': 'http://localhost:4001',
      '/health': 'http://localhost:4001'
    }
  },
  // GF-795 — Vitest. node env is enough: client.test.js stubs localStorage + fetch
  // via vi.stubGlobal, so no jsdom dependency. Test helpers imported from 'vitest'.
  test: {
    environment: 'node'
  }
})
