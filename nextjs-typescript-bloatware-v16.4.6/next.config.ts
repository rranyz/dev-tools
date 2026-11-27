import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  /* config options here */
  experimental: {
    agentFeedback: true,
  },
  cacheComponents: true,
  partialPrefetching: true,
  turbopack: {
    rules: {
      '*.css': {
        // Skip CSS Modules: this rule's `as: '*.css'` would otherwise turn them into
        // global CSS (empty class names). Sass output also passes through this rule.
        condition: { not: { path: /\.module\.(css|scss|sass)$/ } },
        loaders: ['@tailwindcss/turbopack'],
        as: '*.css',
      },
    },
  },
};

export default nextConfig;
