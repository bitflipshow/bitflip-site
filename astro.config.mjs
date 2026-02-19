// @ts-check
import { defineConfig } from 'astro/config';

// https://astro.build/config
export default defineConfig({
  site: "https://bitflip.show",
  vite: {
    server: {
      allowedHosts: ['magrathea.ktz.ts.net'],
      host: true,
    },
    build: {
      rollupOptions: {
        external: ['/pagefind/pagefind.js']
      }
    }
  },
});