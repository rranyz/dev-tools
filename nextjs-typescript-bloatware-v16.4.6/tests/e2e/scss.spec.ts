import { expect, test } from '../fixtures/test-fixtures';

test.describe('SCSS demo page', () => {
  test('loads with the header, heading and buttons', async ({ scssDemoPage, page }) => {
    const response = await scssDemoPage.goto();

    expect(response?.ok()).toBe(true);
    await expect(page).toHaveTitle('SCSS demo');
    await expect(scssDemoPage.header).toBeVisible();
    await expect(scssDemoPage.nav).toBeVisible();
    await expect(scssDemoPage.heading).toHaveText('SCSS Modules with Tailwind');
    await expect(scssDemoPage.primaryButton).toBeVisible();
    await expect(scssDemoPage.secondaryButton).toBeVisible();
    await expect(scssDemoPage.disabledButton).toBeDisabled();
  });

  test('header link navigates to the home page', async ({ scssDemoPage, homePage, page }) => {
    await scssDemoPage.goto();
    await scssDemoPage.homeLink.click();

    await expect(page).toHaveURL(/\/$/);
    await expect(homePage.heading).toBeVisible();
  });

  test('button styles come from the scoped CSS Module', async ({ scssDemoPage, page }) => {
    await scssDemoPage.goto();
    const button = scssDemoPage.primaryButton;

    // CSS Modules rename classes, so the plain name `button` must not appear as-is.
    const classNames = ((await button.getAttribute('class')) ?? '').split(/\s+/);
    expect(classNames.length).toBeGreaterThanOrEqual(2);
    expect(classNames).not.toContain('button');
    expect(classNames).not.toContain('primary');

    // Background is the --primary token from app/globals.css.
    const primary = await page.evaluate(() => {
      const probe = document.createElement('div');
      probe.style.backgroundColor = 'var(--primary)';
      document.body.append(probe);
      const color = getComputedStyle(probe).backgroundColor;
      probe.remove();
      return color;
    });
    await expect(button).toHaveCSS('background-color', primary);
    await expect(button).toHaveCSS('border-top-left-radius', '9999px');
  });

  test('primary button changes color on hover', async ({ scssDemoPage }) => {
    await scssDemoPage.goto();
    const button = scssDemoPage.primaryButton;
    const before = await button.evaluate((el) => getComputedStyle(el).backgroundColor);

    await button.hover();

    await expect(button).not.toHaveCSS('background-color', before);
  });

  test('buttons show a focus outline for keyboard users', async ({ scssDemoPage, page }) => {
    await scssDemoPage.goto();
    const button = scssDemoPage.primaryButton;

    // Tab through the header links until the button has focus.
    for (let i = 0; i < 10; i++) {
      await page.keyboard.press('Tab');
      if (await button.evaluate((el) => el === document.activeElement)) break;
    }

    await expect(button).toBeFocused();
    await expect(button).not.toHaveCSS('outline-style', 'none');
  });

  test('buttons are full width on mobile and auto width on desktop', async ({
    scssDemoPage,
    page,
  }) => {
    await page.setViewportSize({ width: 375, height: 800 });
    await scssDemoPage.goto();
    const button = scssDemoPage.primaryButton;
    const row = button.locator('..');

    const mobileButton = await button.boundingBox();
    const mobileRow = await row.boundingBox();
    expect(mobileButton?.width).toBeCloseTo(mobileRow?.width ?? 0, 0);

    await page.setViewportSize({ width: 1280, height: 800 });
    await expect
      .poll(async () => (await button.boundingBox())?.width ?? 0)
      .toBeLessThan((mobileRow?.width ?? 0) - 1);
    const desktopButton = await button.boundingBox();
    expect(desktopButton?.width).toBeGreaterThanOrEqual(158);
    expect(desktopButton?.width).toBeLessThan(300);
  });
});

test.describe('Tailwind and global SCSS together', () => {
  test('Tailwind utilities still win over global SCSS base styles', async ({ homePage }) => {
    await homePage.goto();

    // `text-3xl` (1.875rem = 30px) is in @layer utilities; global SCSS is in @layer base.
    await expect(homePage.heading).toHaveCSS('font-size', '30px');
    // The SCSS base layer is loaded (text-wrap: balance on headings).
    await expect(homePage.heading).toHaveCSS('text-wrap-style', 'balance');
  });
});
