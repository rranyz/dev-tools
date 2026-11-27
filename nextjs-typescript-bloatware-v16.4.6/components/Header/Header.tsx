import Link from 'next/link';
import styles from './Header.module.scss';

export type HeaderLink = {
  href: string;
  label: string;
};

export type HeaderProps = {
  title: string;
  links: HeaderLink[];
};

/** Site header styled with an SCSS Module. Stacks on mobile, one row from `sm` up. */
export function Header({ title, links }: HeaderProps) {
  return (
    <header className={styles.header}>
      <div className={styles.inner}>
        <span className={styles.brand}>{title}</span>
        <nav aria-label="Main" className={styles.nav}>
          {links.map((link) => (
            <Link key={link.href} href={link.href} className={styles.link}>
              {link.label}
            </Link>
          ))}
        </nav>
      </div>
    </header>
  );
}
