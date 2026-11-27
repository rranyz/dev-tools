import type { Metadata } from 'next';
import { Button } from '@/components/Button/Button';
import { Header } from '@/components/Header/Header';

export const metadata: Metadata = {
  title: 'SCSS demo',
  description: 'Example components styled with SCSS Modules next to Tailwind CSS.',
};

const links = [
  { href: '/', label: 'Home' },
  { href: '/scss-demo', label: 'SCSS demo' },
];

export default function ScssDemoPage() {
  return (
    <div className="flex flex-1 flex-col">
      <Header title="dev-tools" links={links} />
      {/* Tailwind handles the page layout; the SCSS Modules handle the components. */}
      <main className="mx-auto flex w-full max-w-3xl flex-1 flex-col gap-8 px-6 py-16">
        <div className="flex flex-col gap-4">
          <h1 className="text-3xl font-semibold tracking-tight">SCSS Modules with Tailwind</h1>
          <p className="max-w-xl text-lg leading-8 text-secondary">
            The header and buttons on this page are styled with SCSS Modules. The layout around them
            uses Tailwind utilities.
          </p>
        </div>
        <div className="flex flex-col gap-4 sm:flex-row">
          <Button>Primary action</Button>
          <Button variant="secondary">Secondary action</Button>
          <Button disabled>Disabled</Button>
        </div>
      </main>
    </div>
  );
}
