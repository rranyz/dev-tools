import { existsSync } from 'node:fs';
import { loadEnvFile } from 'node:process';
import { defineConfig, devices, type Project } from '@playwright/test';

/**
 * Optional local overrides (test accounts, base URL, ...).
 * Copy `.env.e2e.example` to `.env.e2e`; the real file is git-ignored.
 */
if (existsSync('.env.e2e')) {
  loadEnvFile('.env.e2e');
}

const isCI = !!process.env.CI;

/** Point tests at an already running app (e.g. a preview deployment) instead of starting one. */
const externalBaseURL = process.env.PLAYWRIGHT_BASE_URL;
const baseURL = externalBaseURL ?? 'http://localhost:3000';

/** Chromium always runs. Set E2E_ALL_BROWSERS=1 to add Firefox and WebKit. */
const projects: Project[] = [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }];
if (process.env.E2E_ALL_BROWSERS === '1') {
  projects.push(
    { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
  );
}

/** See https://playwright.dev/docs/test-configuration. */
export default defineConfig({
  testDir: './tests/e2e',
  timeout: 30_000,
  expect: { timeout: 5_000 },
  fullyParallel: true,
  /* Fail the CI build if test.only was left in the source. */
  forbidOnly: isCI,
  retries: isCI ? 2 : 0,
  workers: isCI ? 1 : undefined,
  reporter: isCI
    ? [['list'], ['github'], ['html', { open: 'never' }]]
    : [['list'], ['html', { open: 'on-failure' }]],
  use: {
    baseURL,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  projects,
  /*
   * CI: serve the production build (the workflow runs `npm run build` first).
   * Local: use the dev server, reusing one that is already running.
   */
  webServer: externalBaseURL
    ? undefined
    : {
        command: isCI ? 'npm run start' : 'npm run dev',
        url: baseURL,
        reuseExistingServer: !isCI,
        timeout: 120_000,
      },
});
