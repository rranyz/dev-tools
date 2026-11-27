# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Next.js version

This project runs Next.js 16.4.6 with React 19.3.0, and its APIs and conventions differ from older Next.js releases. Before writing Next.js code, read the matching guide in `node_modules/next/dist/docs/` (`01-app/`, `03-architecture/`, `04-glossary.md`) and follow its deprecation notices.

`next dev` manages `AGENTS.md` (see `node_modules/next/dist/server/lib/generate-agent-files.js`) and writes the blocks between the `<!-- BEGIN:... -->` / `<!-- END:... -->` markers again if they are removed. Don't hand-edit those blocks.

## Commands

The project uses npm (`package-lock.json`).

- Dev server: `npm run dev` (http://localhost:3000)
- Production build / serve: `npm run build`, `npm run start`
- Lint all: `npm run lint` (ESLint 9 flat config)
- Lint one file: `npx eslint --fix app/page.tsx`
- Type check: `npx tsc --noEmit` (no script for it)
- Format: `npm run format` (writes) / `npm run format:check`. One file: `npx prettier --write app/page.tsx`

- E2E tests (Playwright): `npm run test:e2e` (starts `npm run dev` itself, or reuses a running one). One file: `npx playwright test tests/e2e/home.spec.ts`. One test: `npx playwright test -g "404"`. UI mode: `npm run test:e2e:ui`. Report: `npm run test:e2e:report`.
- Production-server E2E run (what CI does): `npm run build && CI=1 npm run test:e2e`

There are no unit tests.

## E2E tests

- `playwright.config.ts`: Chromium only by default. `E2E_ALL_BROWSERS=1` adds Firefox and WebKit. `PLAYWRIGHT_BASE_URL` targets an already running app and skips the web server. `.env.e2e` (git-ignored, see `.env.e2e.example`) is loaded if present.
- Specs import `test`/`expect` from `tests/fixtures/test-fixtures.ts`, not `@playwright/test`. It provides page objects (`tests/pages/`) as fixtures and an automatic fixture that fails a test on uncaught page errors.
- `tests/e2e/auth/` is a skipped template, because the app has no auth. It runs only when `E2E_USER_EMAIL`/`E2E_USER_PASSWORD` are set.
- `eslint.config.mjs` turns off `react-hooks/rules-of-hooks` for `tests/**`, because the Playwright fixture `use()` callback isn't a React hook.
- `.github/workflows/e2e.yml` runs format, lint, tsc, build and E2E. It is inert while this folder is a subdirectory of the `dev-tools/` repo. Full guide: `docs/E2E-TESTING.md`.

## Non-default configuration

- `next.config.ts` sets:
  - `cacheComponents: true`. Caching and rendering follow the Cache Components model. See `docs/01-app/01-getting-started/08-caching.md` and `docs/01-app/02-guides/migrating-to-cache-components.md`.
  - `partialPrefetching: true`. See `docs/01-app/02-guides/adopting-partial-prefetching.md`.
  - `experimental.agentFeedback: true`. `next dev` adds an agent-feedback block to `AGENTS.md`.
- Tailwind CSS v4 is loaded through a Turbopack loader rule on `*.css` (`@tailwindcss/turbopack` in `next.config.ts`), not through PostCSS. The project has no `postcss.config` or `tailwind.config`. `app/globals.css` does `@import "tailwindcss"` and defines theme tokens under `@theme inline`, with light and dark values in CSS variables. Keep it a `.css` file.
  - The rule has `condition: { not: { path: /\.module\.(css|scss|sass)$/ } }`. Without it, its `as: '*.css'` turns CSS Modules into global CSS (empty class names). So CSS Modules can't use `@apply`/`@reference`.
- SCSS uses Next's built-in Sass support (`sass` devDependency, no `sassOptions`). `app/globals.scss` is imported after `globals.css` in `app/layout.tsx`, and every global SCSS rule must sit in `@layer base` so Tailwind utilities still win. Use `@use`/`@forward`, never `@import`. Color tokens live only in `app/globals.css`; `styles/abstracts/_variables.scss` points at them with `var(...)`. Full guide: `docs/SCSS-GUIDE.md`.
- ESLint (`eslint.config.mjs`) combines `eslint-config-next/core-web-vitals`, `eslint-config-next/typescript` and `eslint-config-prettier`. `eslint-config-prettier` must stay after the Next configs. ESLint handles code quality and Prettier handles formatting.
- Prettier (`.prettierrc.json`) uses single quotes, semicolons, `printWidth` 100 and trailing commas. `prettier-plugin-tailwindcss` sorts class names and reads the Tailwind v4 setup from `app/globals.css` (`tailwindStylesheet`). `AGENTS.md` is in `.prettierignore` because `next dev` rewrites it.
- `.lintstagedrc.mjs` runs `eslint --fix` on staged JS/TS files, but lint-staged and husky aren't installed yet, so it does nothing for now.
- TypeScript is strict. The `@/*` path alias maps to the project root. Route props use Next's generated global types, such as `LayoutProps<"/">` in `app/layout.tsx`.

## Structure

App Router only, no `src/`: `app/layout.tsx` (root layout, Geist fonts via `next/font/google`), `app/page.tsx`, `app/globals.css`, `app/globals.scss`, and `app/scss-demo/page.tsx` (demo of the SCSS components). Components live in `components/<Name>/<Name>.tsx` with a `<Name>.module.scss` next to them. `styles/abstracts/` holds Sass variables, functions and mixins (no CSS output), and `styles/base/` holds the global base rules. Static assets live in `public/`.
