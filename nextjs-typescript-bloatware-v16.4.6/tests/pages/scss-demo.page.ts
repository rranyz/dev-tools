import type { Locator, Page, Response } from '@playwright/test';

/** Page object for the SCSS demo page (`app/scss-demo/page.tsx`). */
export class ScssDemoPage {
  readonly header: Locator;
  readonly nav: Locator;
  readonly homeLink: Locator;
  readonly heading: Locator;
  readonly primaryButton: Locator;
  readonly secondaryButton: Locator;
  readonly disabledButton: Locator;

  constructor(readonly page: Page) {
    this.header = page.getByRole('banner');
    this.nav = page.getByRole('navigation', { name: 'Main' });
    this.homeLink = this.nav.getByRole('link', { name: 'Home' });
    this.heading = page.getByRole('heading', { level: 1 });
    this.primaryButton = page.getByRole('button', { name: 'Primary action' });
    this.secondaryButton = page.getByRole('button', { name: 'Secondary action' });
    this.disabledButton = page.getByRole('button', { name: 'Disabled' });
  }

  async goto(): Promise<Response | null> {
    return this.page.goto('/scss-demo');
  }
}
