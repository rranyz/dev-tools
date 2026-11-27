import { expect, test } from '../fixtures/test-fixtures';

test.describe('Navigation', () => {
  test('home page links point to the expected destinations', async ({ homePage }) => {
    await homePage.goto();

    // Only the href is checked, so the tests never depend on external sites being up.
    await expect(homePage.templatesLink).toHaveAttribute(
      'href',
      /^https:\/\/vercel\.com\/templates/,
    );
    await expect(homePage.learningLink).toHaveAttribute('href', /^https:\/\/nextjs\.org\/learn/);
    await expect(homePage.deployLink).toHaveAttribute('href', /^https:\/\/vercel\.com\/new/);
    await expect(homePage.documentationLink).toHaveAttribute(
      'href',
      /^https:\/\/nextjs\.org\/docs/,
    );
  });

  test('external call-to-action links open safely in a new tab', async ({ homePage }) => {
    await homePage.goto();

    for (const link of [homePage.deployLink, homePage.documentationLink]) {
      await expect(link).toHaveAttribute('target', '_blank');
      await expect(link).toHaveAttribute('rel', /noopener/);
    }
  });

  test('unknown routes show the 404 page', async ({ page }) => {
    const response = await page.goto('/this-page-does-not-exist');

    expect(response?.status()).toBe(404);
    await expect(page.getByRole('heading', { name: '404' })).toBeVisible();
    await expect(page.getByText('This page could not be found.')).toBeVisible();
  });

  test('can navigate from the 404 page back to home', async ({ homePage, page }) => {
    await page.goto('/this-page-does-not-exist');
    await homePage.goto();
    await expect(homePage.heading).toBeVisible();

    await page.goBack();
    await expect(page).toHaveURL(/\/this-page-does-not-exist$/);

    await page.goForward();
    await expect(page).toHaveURL(/\/$/);
    await expect(homePage.heading).toBeVisible();
  });
});
