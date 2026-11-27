import type { ComponentPropsWithoutRef } from 'react';
import styles from './Button.module.scss';

export type ButtonVariant = 'primary' | 'secondary';

export type ButtonProps = ComponentPropsWithoutRef<'button'> & {
  /** Visual style. Defaults to `primary`. */
  variant?: ButtonVariant;
};

/**
 * Button styled with an SCSS Module. Use Tailwind on the parent for layout
 * (gap, flex, margins); the module owns the button's own look.
 */
export function Button({ variant = 'primary', type = 'button', className, ...props }: ButtonProps) {
  const classes = [styles.button, styles[variant], className].filter(Boolean).join(' ');

  return <button type={type} className={classes} {...props} />;
}
