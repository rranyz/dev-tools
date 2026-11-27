# E2E Testing with Playwright

End-to-end (E2E) tests open the app in a real browser and check what a user sees and does. This project uses [Playwright](https://playwright.dev).

## Installation

Playwright is already installed. You don't need to run `npm init playwright` again.

- Package: `@playwright/test` (in `devDependencies`)
- Config: `playwright.config.ts`
- Browsers: Chromium, Firefox and WebKit, stored in `~/.cache/ms-playwright`

On a new machine, run `npm install` and then download the browsers once:

```bash
npx playwright install --with-deps chromium   # just Chromium, the default
npx playwright install --with-deps            # Chromium, Firefox and WebKit
```

`--with-deps` also installs the Linux system libraries the browsers need, and asks for `sudo`. If those libraries are already installed, leave it out.

## Folder structure

```
tests/
  e2e/                    # Test files (*.spec.ts). Playwright only looks here.
    home.spec.ts          # Home page: loads, title, heading, content
    navigation.spec.ts    # Links, the 404 page, back/forward
    scss.spec.ts          # SCSS demo page: CSS Modules, hover/focus, responsive, Tailwind vs. SCSS
    auth/login.spec.ts    # TEMPLATE: skipped until the app has a login page
  fixtures/
    test-fixtures.ts      # Our `test` and `expect` (adds homePage, scssDemoPage and the page-error check)
  pages/
    home.page.ts          # Page object for the home page
    scss-demo.page.ts     # Page object for the SCSS demo page
    login.page.ts         # TEMPLATE page object for a login page
  utils/
    test-helpers.ts       # hasEnv() / requireEnv() for environment variables
playwright.config.ts
.env.e2e.example          # Copy to .env.e2e for local settings
```

## Running tests

| Command                     | What it does                                               |
| --------------------------- | ---------------------------------------------------------- |
| `npm run test:e2e`          | Runs all tests in headless Chromium                        |
| `npm run test:e2e:chromium` | Runs only the Chromium project                             |
| `npm run test:e2e:ui`       | Opens UI mode, where you can watch, pick and re-run tests  |
| `npm run test:e2e:headed`   | Runs with a visible browser window                         |
| `npm run test:e2e:debug`    | Opens the Playwright Inspector to step through each action |
| `npm run test:e2e:report`   | Opens the HTML report from the last run                    |

You don't need to start the app yourself. Playwright runs `npm run dev` and waits for http://localhost:3000. If a dev server is already running, it reuses that one.

Useful variations:

```bash
npx playwright test tests/e2e/home.spec.ts      # one file
npx playwright test -g "404"                    # tests whose name contains "404"
E2E_ALL_BROWSERS=1 npm run test:e2e             # also run Firefox and WebKit
E2E_ALL_BROWSERS=1 npx playwright test --project=firefox
```

### Optional: run Playwright directly with npx

If you'd rather not use the npm scripts in `package.json`, you can call Playwright directly. Run these from the project folder. They use the same `playwright.config.ts`, so Playwright still starts the dev server for you.

| Command                                        | What it does                                                       | npm script equivalent       |
| ---------------------------------------------- | ------------------------------------------------------------------ | --------------------------- |
| `npx playwright test`                          | Runs the end-to-end tests                                          | `npm run test:e2e`          |
| `npx playwright test --ui`                     | Starts the interactive UI mode                                     | `npm run test:e2e:ui`       |
| `npx playwright test --project=chromium`       | Runs the tests only on Desktop Chrome                              | `npm run test:e2e:chromium` |
| `npx playwright test home.spec`                | Runs the tests in a specific file (`home.spec.ts`)                 | —                           |
| `npx playwright test --debug`                  | Runs the tests in debug mode                                       | `npm run test:e2e:debug`    |
| `npx playwright codegen http://localhost:3000` | Opens a browser and generates test code from your clicks (Codegen) | —                           |

**File filters:** the filter is matched against the full file path, so pick a word that only appears in the file name. `home.spec` works, but a plain `home` would also match `/home/<user>/...` in the folder path and run every test.

**Codegen:** start the app first with `npm run dev`. Codegen doesn't start the server for you. Copy the generated code into a new `*.spec.ts` file in `tests/e2e/`. Then change its import to `import { expect, test } from '../fixtures/test-fixtures';`, and replace any CSS selectors it produced with `getByRole()` / `getByLabel()`.

To get started, run:

```bash
npx playwright test
```

Then look at these files:

- `tests/e2e/home.spec.ts`: an example end-to-end test
- `playwright.config.ts`: the Playwright Test configuration

### Testing the production build

The CI workflow tests the production build. You can do the same locally:

```bash
npm run build
CI=1 npm run test:e2e   # uses `npm run start`, adds retries and fails on test.only
```

## Debugging

- **UI mode** (`npm run test:e2e:ui`) shows every step with a DOM snapshot. Start here.
- **Inspector** (`npm run test:e2e:debug`) pauses before each action. You can also put `await page.pause()` in a test to stop at that line.
- **Failed runs** keep a screenshot and a video in `test-results/`. On CI retries Playwright also records a trace. Open it with:

  ```bash
  npx playwright show-trace test-results/<test-folder>/trace.zip
  ```

## HTML report

Each run writes `playwright-report/index.html`. Open it with `npm run test:e2e:report`. Locally the report opens by itself when a test fails.

## Writing a new test

1. Create a file in `tests/e2e/`, ending in `.spec.ts`.
2. Import `test` and `expect` from the fixtures file, not from `@playwright/test`. That way the file gets the shared fixtures and the page-error check.

```ts
import { expect, test } from '../fixtures/test-fixtures';

test.describe('About page', () => {
  test('shows the team section', async ({ page }) => {
    await page.goto('/about'); // relative to baseURL

    await expect(page.getByRole('heading', { name: 'Our team' })).toBeVisible();
  });
});
```

Guidelines:

- **Find elements the way a user would**: `getByRole()`, `getByLabel()` and `getByText()`. Use `getByTestId()` only when nothing else fits, and add a `data-testid` to the component for it. Avoid CSS selectors and XPath.
- **Don't add fixed waits.** `expect(...).toBeVisible()`, `toHaveURL()` and other assertions already retry until they pass or time out. Never use `page.waitForTimeout()`.
- **Keep tests independent.** Each test gets a fresh browser context (its own cookies and storage), so don't depend on what another test did.
- **Don't depend on external sites.** For external links, check the `href` instead of clicking.
- **Clean up** any data a test creates, for example in `test.afterEach`.

Every test also fails automatically if the page throws an uncaught JavaScript error (the `pageErrors` fixture).

## Page Object Model

A page object keeps a page's locators and actions in one class. When the UI changes, you update one file instead of every test.

```ts
// tests/pages/home.page.ts
export class HomePage {
  readonly heading: Locator;
  constructor(readonly page: Page) {
    this.heading = page.getByRole('heading', { level: 1 });
  }
  async goto() {
    return this.page.goto('/');
  }
}
```

It's exposed as a fixture in `tests/fixtures/test-fixtures.ts`, so tests ask for it by name:

```ts
test('shows the main heading', async ({ homePage }) => {
  await homePage.goto();
  await expect(homePage.heading).toBeVisible();
});
```

Create a page object when several tests use the same page. For a one-off check, use `page` directly.

## Environment variables

| Variable                               | Purpose                                                                                           |
| -------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `PLAYWRIGHT_BASE_URL`                  | Test an app that is already running (for example a preview URL). Playwright won't start a server. |
| `E2E_ALL_BROWSERS=1`                   | Add Firefox and WebKit projects                                                                   |
| `E2E_USER_EMAIL` / `E2E_USER_PASSWORD` | Dedicated test account for the auth tests                                                         |
| `CI`                                   | Set by GitHub Actions. Enables retries and the production server.                                 |

For local settings, copy the example file. The real `.env.e2e` is git-ignored, and `playwright.config.ts` loads it automatically:

```bash
cp .env.e2e.example .env.e2e
```

**Only use dedicated test accounts. Never use production credentials.**

## Authentication tests (template)

The app has no login yet, so `tests/e2e/auth/login.spec.ts` is a template. It's skipped until `E2E_USER_EMAIL` and `E2E_USER_PASSWORD` are set. Skipped tests show as `-` in the output and aren't counted as passed.

When the app has a login page:

1. In `tests/pages/login.page.ts`, set `LOGIN_PATH` and the field labels and button name.
2. In `login.spec.ts`, set `PROTECTED_PATH` and the logout button name.
3. Set the two variables in `.env.e2e`, and run `npm run test:e2e -- tests/e2e/auth`.

## GitHub Actions

`.github/workflows/e2e.yml` runs on pushes and pull requests to `main`. It:

1. Installs dependencies with `npm ci` (and caches npm).
2. Installs Chromium (and caches the browser between runs).
3. Runs `format:check`, `lint` and `tsc --noEmit`.
4. Runs `npm run build`, then `npm run test:e2e` against `npm run start`.
5. Uploads `playwright-report/` on every run, and `test-results/` (screenshots, videos, traces) when tests fail.

Download the report from the workflow run's **Artifacts** section, unzip it, and run `npx playwright show-report <folder>`.

For the auth tests in CI, add `E2E_USER_EMAIL` and `E2E_USER_PASSWORD` as repository secrets and uncomment the `env` lines in the workflow.

> **Note:** GitHub only runs workflows from `.github/workflows/` at the **root of the repository**. This project currently sits in a subfolder of a larger repository (`dev-tools/`), so the workflow doesn't run yet. It runs as-is once this folder is its own repository. To run it from the parent repository instead, move the file to `dev-tools/.github/workflows/`, add `defaults.run.working-directory: nextjs-typescript-bloatware-v16.4.6`, set `cache-dependency-path` for npm, and prefix the upload paths with the folder name.
