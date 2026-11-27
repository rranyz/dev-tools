import type { Locator, Page, Response } from '@playwright/test';

/** Page object for the home page (`app/page.tsx`). */
export class HomePage {
  readonly heading: Locator;
  readonly logo: Locator;
  readonly templatesLink: Locator;
  readonly learningLink: Locator;
  readonly deployLink: Locator;
  readonly documentationLink: Locator;

  constructor(readonly page: Page) {
    this.heading = page.getByRole('heading', { level: 1 });
    this.logo = page.getByRole('img', { name: 'Next.js logo' });
    this.templatesLink = page.getByRole('link', { name: 'Templates' });
    this.learningLink = page.getByRole('link', { name: 'Learning' });
    this.deployLink = page.getByRole('link', { name: 'Deploy Now' });
    this.documentationLink = page.getByRole('link', { name: 'Documentation' });
  }

  async goto(): Promise<Response | null> {
    return this.page.goto('/');
  }
}
