import { test as base, expect } from '@playwright/test';
import { HomePage } from '../pages/home.page';
import { ScssDemoPage } from '../pages/scss-demo.page';

type Fixtures = {
  homePage: HomePage;
  scssDemoPage: ScssDemoPage;
  /** Uncaught errors thrown in the page. Every test fails if any occur. */
  pageErrors: Error[];
};

export const test = base.extend<Fixtures>({
  homePage: async ({ page }, use) => {
    await use(new HomePage(page));
  },

  scssDemoPage: async ({ page }, use) => {
    await use(new ScssDemoPage(page));
  },

  pageErrors: [
    async ({ page }, use) => {
      const errors: Error[] = [];
      page.on('pageerror', (error) => errors.push(error));
      await use(errors);
      expect(errors, 'uncaught errors in the page').toEqual([]);
    },
    { auto: true },
  ],
});

export { expect };
