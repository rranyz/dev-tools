import { expect, test } from '../../fixtures/test-fixtures';
import { LOGIN_PATH, LoginPage } from '../../pages/login.page';
import { hasEnv, requireEnv } from '../../utils/test-helpers';

/*
 * TEMPLATE — the app has no authentication yet, so these tests are skipped.
 *
 * To enable them:
 * 1. Build the login page and a protected page.
 * 2. Update LOGIN_PATH and the labels in tests/pages/login.page.ts,
 *    and PROTECTED_PATH / the logout button name below.
 * 3. Set E2E_USER_EMAIL and E2E_USER_PASSWORD for a dedicated test account
 *    (in .env.e2e locally, as repository secrets in CI). Never use production credentials.
 */
const PROTECTED_PATH = '/dashboard';

test.describe('Authentication', () => {
  test.skip(
    !hasEnv('E2E_USER_EMAIL', 'E2E_USER_PASSWORD'),
    'Template: set E2E_USER_EMAIL and E2E_USER_PASSWORD once the app has a login page.',
  );

  let loginPage: LoginPage;

  test.beforeEach(async ({ page }) => {
    loginPage = new LoginPage(page);
    await loginPage.goto();
  });

  test('shows the login form', async () => {
    await expect(loginPage.emailInput).toBeVisible();
    await expect(loginPage.passwordInput).toBeVisible();
    await expect(loginPage.submitButton).toBeEnabled();
  });

  test('requires email and password', async () => {
    await expect(loginPage.emailInput).toHaveAttribute('required', '');
    await expect(loginPage.passwordInput).toHaveAttribute('required', '');
  });

  test('rejects invalid credentials', async ({ page }) => {
    await loginPage.login('invalid-user@example.com', 'wrong-password');

    await expect(loginPage.errorMessage).toBeVisible();
    await expect(page).toHaveURL(new RegExp(LOGIN_PATH));
  });

  test('logs in, redirects to the protected page, and logs out', async ({ page }) => {
    await loginPage.login(requireEnv('E2E_USER_EMAIL'), requireEnv('E2E_USER_PASSWORD'));
    await expect(page).toHaveURL(new RegExp(`${PROTECTED_PATH}$`));

    await page.getByRole('button', { name: 'Log out' }).click();
    await page.goto(PROTECTED_PATH);
    await expect(loginPage.emailInput).toBeVisible();
  });
});
