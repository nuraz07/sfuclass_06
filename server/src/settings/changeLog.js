// classroom-app/server/src/settings/changeLog.js
/**
 * Every settings change, recorded and announced  (Settings, Phase B)
 *
 * One call after a successful change does two things:
 *
 *   audit   'settings.changed' in audit_log with the section and the names of
 *           the fields (never the values), the device and the IP. Settings →
 *           Recent changes reads it, so someone can see a change they did not
 *           make and sign that device out.
 *
 *   live    'settings:changed' to every other tab and device of the person, so
 *           a change on the laptop shows on the phone without a reload.
 *
 * Neither may fail the change that already happened.
 */

import { auditFromRequest } from '../security/auditLog.js';
import { pushToUser } from '../realtime/userEvents.js';
import { logger } from '../observability/logger.js';
import { fieldPaths } from './fieldPaths.js';

const log = logger.child({ component: 'settings-change-log' });

export const SETTINGS_CHANGED = 'settings.changed';

export const recordChange = async (req, section, patch, { action = SETTINGS_CHANGED, metadata = {} } = {}) => {
  const userId = req.user?.id;
  if (!userId) return;
  const fields = fieldPaths(patch ?? {});
  if (fields.length === 0 && action === SETTINGS_CHANGED) return;

  try {
    await auditFromRequest(req, {
      action,
      targetType: 'user',
      targetId: userId,
      metadata: { section, fields, ...metadata },
    });
  } catch (cause) {
    log.warn({ err: cause, section }, 'settings change not audited');
  }

  await pushToUser(userId, 'settings:changed', { section, fields });
};

export default recordChange;
