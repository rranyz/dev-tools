/** True when every named environment variable is set and not empty. */
export function hasEnv(...names: string[]): boolean {
  return names.every((name) => !!process.env[name]);
}

/** Read an environment variable or fail with a clear message. Never logs the value. */
export function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing environment variable ${name}. See docs/E2E-TESTING.md.`);
  }
  return value;
}
