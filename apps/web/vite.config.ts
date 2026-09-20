/**
 * apps/web/vite.config.ts
 *
 * Vite build for the SPA.  (F5, F7)
 *
 * v6 -> v7 correction: v6 said "source maps to Sentry-free", which is not a
 * setting and not a decision. The rule here is explicit:
 *
 *   - `sourcemap: 'hidden'` generates full maps but emits NO
 *     //# sourceMappingURL comment, so a browser never fetches them and the
 *     public bundle gives nothing away.
 *   - deploy-web.yml uploads *.map to a private bucket (never to the CDN
 *     origin) and deletes them from dist/ before the S3 sync.
 *   - hashed assets are immutable for a year; index.html is never cached.
 *     Cache headers are set by deploy-web.yml and cdn.tf — this file only
 *     guarantees that every asset filename contains a content hash, which is
 *     what makes an immutable header safe.
 */

import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';
import { resolve } from 'node:path';

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), ['VITE_', 'RELEASE_']);
  const isProduction = mode === 'production';

  return {
    plugins: [react()],

    /**
     * Assets are served from the CDN domain, index.html from the same
     * distribution. An absolute base means a cached index.html loaded from
     * any path still resolves its chunks correctly.
     */
    base: env.VITE_CDN_BASE || '/',

    resolve: {
      alias: {
        '@': resolve(__dirname, 'src'),
        '@contracts': resolve(__dirname, '../../packages/contracts/src'),
        '@core-client': resolve(__dirname, '../../packages/core-client/src'),
        '@ui-tokens': resolve(__dirname, '../../packages/ui-tokens/src'),
      },
    },

    define: {
      __RELEASE_SHA__: JSON.stringify(env.RELEASE_SHA ?? 'dev'),
      __BUILD_TIME__: JSON.stringify(new Date().toISOString()),
    },

    build: {
      target: 'es2022',
      outDir: 'dist',
      assetsDir: 'assets',
      emptyOutDir: true,

      // See the header: full maps, no public reference.
      sourcemap: isProduction ? 'hidden' : true,

      // Fail the build rather than ship a 4 MB entry chunk unnoticed.
      chunkSizeWarningLimit: 900,
      reportCompressedSize: false, // saves ~30 s in CI on a bundle this size

      rollupOptions: {
        output: {
          // Every emitted file carries a content hash. This is the precondition
          // for `Cache-Control: max-age=31536000, immutable` on /assets/*.
          entryFileNames: 'assets/[name].[hash].js',
          chunkFileNames: 'assets/[name].[hash].js',
          assetFileNames: 'assets/[name].[hash][extname]',

          /**
           * Split the heavy, rarely-changing dependencies out of the app
           * chunk. mediasoup-client in particular is large and changes on its
           * own schedule; keeping it separate means a normal UI release does
           * not invalidate it in every learner's cache.
           */
          manualChunks(id) {
            if (!id.includes('node_modules')) return undefined;
            if (id.includes('mediasoup-client')) return 'vendor-rtc';
            if (id.includes('yjs') || id.includes('y-protocols') || id.includes('y-websocket')) {
              return 'vendor-collab';
            }
            if (id.includes('react') || id.includes('scheduler')) return 'vendor-react';
            if (id.includes('socket.io-client') || id.includes('engine.io-client')) {
              return 'vendor-socket';
            }
            return 'vendor';
          },
        },
      },
    },

    esbuild: {
      // Strip debug noise from production, keep console.error and warn: the
      // ErrorBoundary and ConnectionBanner rely on them for the trace id.
      drop: isProduction ? ['debugger'] : [],
      pure: isProduction ? ['console.log', 'console.debug'] : [],
      legalComments: 'none',
    },

    server: {
      port: 5173,
      strictPort: true,
      proxy: {
        // Dev only. In every deployed environment the SPA talks to api. and
        // ws. directly; there is no proxy in front of it.
        '/api': { target: 'http://localhost:8080', changeOrigin: true },
        '/socket.io': { target: 'http://localhost:8081', ws: true, changeOrigin: true },
      },
    },

    preview: { port: 4173, strictPort: true },

    test: {
      environment: 'jsdom',
      setupFiles: ['./src/test/setup.ts'],
      globals: true,
    },
  };
});