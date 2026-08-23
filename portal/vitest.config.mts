import { defineConfig } from 'vitest/config'
import { fileURLToPath } from 'node:url'

// No @vitejs/plugin-react here on purpose: its current release pulls a
// @babel/core 8 peer that conflicts with the Babel 7 tree shadcn already
// brings in, and esbuild's automatic JSX runtime covers everything these
// tests need. Adding the plugin means resolving that conflict for no gain.
export default defineConfig({
  esbuild: { jsx: 'automatic' },
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./', import.meta.url)),
    },
  },
  test: {
    environment: 'jsdom',
    include: ['**/*.test.{ts,tsx}'],
    exclude: ['node_modules/**', '.next/**'],
    setupFiles: ['./vitest.setup.ts'],
  },
})
