/**
 * "I signed out on purpose"  (Design)
 *
 * SessionWatch (AppLayout) sends anyone who loses their session to the
 * sign-in page with a notice. Someone who chose "Sign out" in the profile menu
 * should land on the homepage instead. The menu marks the intent here just
 * before signing out; SessionWatch reads it once.
 */

let intendedAt = 0;

export const markSignOutIntent = () => {
  intendedAt = Date.now();
};

/** true once, within a few seconds of markSignOutIntent(). */
export const consumeSignOutIntent = () => {
  const recent = Date.now() - intendedAt < 5_000;
  intendedAt = 0;
  return recent;
};
