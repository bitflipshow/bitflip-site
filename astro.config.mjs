// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// https://astro.build/config
export default defineConfig({
  site: "https://bitflip.show",
  integrations: [sitemap()],
  vite: {
    server: {
      allowedHosts: ['magrathea.ktz.ts.net'],
      host: true,
    },
  },
});