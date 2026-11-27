# SCSS Guide

This project uses **Tailwind CSS v4** and **SCSS (Sass)** together. This guide explains how they fit, where files go, and how to add new styles.

## Overview

| Tool               | Use it for                                                         |
| ------------------ | ------------------------------------------------------------------ |
| Tailwind utilities | Page layout, spacing between elements, one-off styles              |
| SCSS Modules       | Reusable components with many states (variants, hover, focus, ...) |
| Global SCSS        | A few site-wide base rules (focus outline, text wrapping, ...)     |

Next.js compiles SCSS itself (built-in Sass support). There is no extra loader or webpack plugin.

## Installation

`sass` is already in `devDependencies`. On a new machine, `npm install` is enough.

For a new project you would run:

```bash
npm install --save-dev sass
```

We use `sass` (the default). `sass-embedded` is faster on very large code bases, but it adds a native binary and isn't needed here.

## Project structure (no `src/` folder)

All folders sit at the project root:

```
app/
  globals.css            # Tailwind entry + color tokens (CSS variables). Keep it .css!
  globals.scss           # Global SCSS entry (imported after globals.css)
  layout.tsx             # Imports globals.css, then globals.scss
  scss-demo/page.tsx     # Demo page for the example components
components/
  Button/
    Button.tsx
    Button.module.scss
  Header/
    Header.tsx
    Header.module.scss
styles/
  abstracts/             # Outputs NO CSS. Variables, functions, mixins.
    _index.scss
    _variables.scss
    _functions.scss
    _mixins.scss
  base/                  # Global base rules, all inside @layer base
    _index.scss
    _layers.scss
    _typography.scss
    _global.scss
docs/
  SCSS-GUIDE.md
```

**What we left out, and why:**

- `styles/base/_reset.scss`: Tailwind's Preflight already resets browser styles. A second reset would fight it.
- `styles/components/` (`_buttons.scss`, `_forms.scss`): global `.btn` classes would duplicate the CSS Modules. Component styles belong in `components/<Name>/<Name>.module.scss`.
- `styles/utilities/`: Tailwind already provides utility classes.

## Global styles

`app/layout.tsx` imports the two global stylesheets in this order:

```tsx
import './globals.css'; // Tailwind
import './globals.scss'; // global SCSS
```

`app/globals.css` must stay a `.css` file. The Tailwind loader in `next.config.ts` only handles `*.css`, and Prettier's Tailwind plugin reads that file too.

### Cascade layers: why global SCSS never breaks Tailwind

Tailwind v4 puts its CSS into cascade layers in this order: `theme`, `base`, `components`, `utilities`. A later layer always wins, whatever the selector. But **CSS that is in no layer beats every layer**. If we wrote `h1 { font-size: 2rem; }` without a layer, it would override `text-3xl` on every page.

So every global SCSS rule goes inside `@layer base`:

```scss
// styles/base/_typography.scss
@layer base {
  h1 {
    text-wrap: balance;
  }
}
```

`styles/base/_layers.scss` repeats Tailwind's layer order, so the order stays right even if the SCSS file loads first.

## Variables, functions and mixins

Load them in any SCSS file with `@use` (never `@import`, which is deprecated):

```scss
@use '../../styles/abstracts' as *;
```

### Variables (`_variables.scss`)

| Variable                                      | Value                                               |
| --------------------------------------------- | --------------------------------------------------- |
| `$color-background`, `$color-foreground`      | `var(--background)`, `var(--foreground)`            |
| `$color-primary`, `$color-primary-foreground` | `var(--primary)`, `var(--primary-foreground)`       |
| `$color-primary-hover`, `$color-secondary`    | `var(--primary-hover)`, `var(--secondary)`          |
| `$color-border`, `$color-surface-hover`       | `var(--border)`, `var(--surface-hover)`             |
| `$font-sans`, `$font-mono`                    | Geist fonts from `next/font`                        |
| `$font-size-sm/base/lg`, `$font-weight-*`     | Same as Tailwind `text-sm`, `font-medium`, ...      |
| `$spacing-unit`                               | `0.25rem` (Tailwind's spacing step)                 |
| `$radius-sm/md/lg/full`                       | Same as Tailwind `rounded-*`                        |
| `$breakpoints`                                | `sm 40rem, md 48rem, lg 64rem, xl 80rem, 2xl 96rem` |

### Functions (`_functions.scss`)

```scss
padding: spacing(4); // 1rem, like Tailwind p-4
min-width: rem(158px); // 9.875rem
```

### Mixins (`_mixins.scss`)

| Mixin                                      | What it does                                          |
| ------------------------------------------ | ----------------------------------------------------- |
| `breakpoint-up(md)`                        | `@media (width >= 48rem)`, like Tailwind `md:`        |
| `breakpoint-down(md)`                      | `@media (width < 48rem)`, like `max-md:`              |
| `flex($direction, $align, $justify, $gap)` | Flexbox shorthand                                     |
| `center`                                   | Flex centering                                        |
| `hover-capable`                            | `@media (hover: hover)`, so no sticky hover on phones |
| `reduced-motion`                           | `@media (prefers-reduced-motion: reduce)`             |
| `dark`                                     | `@media (prefers-color-scheme: dark)`                 |
| `focus-ring`                               | Visible keyboard focus outline                        |

An unknown breakpoint name stops the build with a clear error.

## CSS Modules

A file named `*.module.scss` is a CSS Module. Its class names are renamed at build time (for example `.button` becomes `gW1A4G_button`), so they can't clash with other components.

```tsx
import styles from './Button.module.scss';

<button className={styles.button}>Click me</button>;
```

TypeScript needs nothing extra. Next.js already declares `*.module.scss` in `next/types/global.d.ts`.

> **Note:** `next.config.ts` keeps CSS Modules out of the Tailwind loader rule (`condition: { not: { path: /\.module\.(css|scss|sass)$/ } }`). Without that condition the rule turns CSS Modules into global CSS and the class names come out empty. So CSS Modules can't use Tailwind-only syntax such as `@apply` or `@reference`. Use the SCSS variables and mixins instead.

## Tailwind and SCSS together

**Who does what:**

- Tailwind on the **outside** of a component: layout, gaps, margins, page sections.
- The SCSS Module on the **inside**: the component's own look and states.

```tsx
<div className="flex flex-col gap-4 sm:flex-row">
  <Button>Primary action</Button>
  <Button variant="secondary">Secondary action</Button>
</div>
```

**One rule to remember:** CSS Module styles are not in a layer, so they beat Tailwind utilities. Don't put a utility on a module-styled element that sets the **same property** as the module (for example `className="h-10"` on `<Button>`, which already sets `height`). A utility for something the module doesn't set (for example `mt-4`) is fine.

**Design tokens have one source.** Colors are CSS variables in `app/globals.css`:

```
app/globals.css  :root { --primary: #171717 }       (dark mode values below it)
      │
      ├── @theme inline { --color-primary: var(--primary) }  → Tailwind: bg-primary, text-primary
      │
      └── styles/abstracts/_variables.scss  $color-primary: var(--primary)  → SCSS
```

To change or add a color, edit `app/globals.css` (both `:root` and the dark block), add it to `@theme inline`, and add a `$color-…` variable that points to it.

Breakpoints, spacing and radius are **copies** of Tailwind's default values, because media queries can't use `var()`. If you ever customize these in Tailwind's `@theme`, update `_variables.scss` too.

## Naming conventions

| Thing                        | Convention                                       | Example                        |
| ---------------------------- | ------------------------------------------------ | ------------------------------ |
| Partial (no own file output) | Leading underscore                               | `_mixins.scss`                 |
| Component styles             | `<Component>.module.scss`, next to the component | `Button/Button.module.scss`    |
| Module class names           | camelCase (works as `styles.x`)                  | `.button`, `.primaryLarge`     |
| Sass variables               | kebab-case with a group prefix                   | `$color-primary`, `$radius-md` |
| Mixins and functions         | kebab-case                                       | `breakpoint-up`, `spacing()`   |
| CSS variables                | kebab-case, set in `globals.css`                 | `--surface-hover`              |

## Examples

### Button (`components/Button/`)

- Props: all normal `<button>` props, plus `variant?: 'primary' | 'secondary'`. `type` defaults to `"button"`.
- States: hover only on devices that can really hover, a `:focus-visible` ring, and `:disabled`.
- Responsive: full width on phones, auto width (at least 158px) from `md` up.

```scss
.button {
  @include center;

  height: spacing(12);
  border-radius: $radius-full;

  @include breakpoint-up(md) {
    width: auto;
    min-width: rem(158px);
  }

  &:focus-visible {
    @include focus-ring;
  }
}

.primary {
  background-color: $color-primary;

  @include hover-capable {
    &:hover:not(:disabled) {
      background-color: $color-primary-hover;
    }
  }
}
```

### Header (`components/Header/`)

- Props: `title` and `links: { href, label }[]`. Renders `<header>` with a `<nav aria-label="Main">` that uses `next/link`.
- Stacked on phones, one row from `sm` up.

See both in action at http://localhost:3000/scss-demo.

## Adding a new component

1. Create `components/Card/Card.tsx` and `components/Card/Card.module.scss`.
2. Start the SCSS file with `@use '../../styles/abstracts' as *;`.
3. Import the styles in the component with `import styles from './Card.module.scss';`.
4. Use Tailwind for the layout around `<Card>` where you use it.

## Best practices

- Use `@use` and `@forward` only. Never use `@import`.
- Keep nesting shallow, at most 3 levels. Prefer one `&:hover` / `&:focus-visible` level.
- Use variables, not hard-coded colors. Colors come from `var(--…)`, so dark mode works by itself.
- Put global rules only in `styles/base/`, always inside `@layer base`. Keep them few.
- Don't create global component classes. Use a CSS Module.
- Check the final CSS order with `npm run build`. The dev server can order CSS differently.
- After changing styles, run `npm run format:check`, `npm run lint`, `npx tsc --noEmit`, `npm run build` and `npm run test:e2e`. `tests/e2e/scss.spec.ts` checks the demo components and that Tailwind still wins over global SCSS.
