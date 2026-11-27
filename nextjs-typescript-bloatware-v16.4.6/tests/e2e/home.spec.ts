import { expect, test } from '../fixtures/test-fixtures';

test.describe('Home page', () => {
  test('loads successfully', async ({ homePage }) => {
    const response = await homePage.goto();

    expect(response?.ok()).toBe(true);
  });

  test('has the expected page title', async ({ homePage, page }) => {
    await homePage.goto();

    await expect(page).toHaveTitle('Create Next App');
  });

  test('shows the main heading', async ({ homePage }) => {
    await homePage.goto();

    await expect(homePage.heading).toHaveText('To get started, edit the page.tsx file.');
  });

  test('shows the logo and introduction text', async ({ homePage, page }) => {
    await homePage.goto();

    await expect(homePage.logo).toBeVisible();
    await expect(
      page.getByText('Looking for a starting point or more instructions?'),
    ).toBeVisible();
  });
});
