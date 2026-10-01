/**
 * username.routes — your username  (Sign in with a username)
 *
 * Mounted under /account/username (app.js).
 *
 *   GET  /                    my username (or null)
 *   PUT  /  { username }      set it; null or "" removes it
 *   GET  /available?name=     is it free? — also for the sign-up form, so no
 *                             sign-in needed; rate-limited per address
 */

import { Router } from 'express';
import { z } from 'zod';

import * as Usernames from '../identity/Usernames.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { route, validate, requireAuth, badRequest, conflict } from './_helpers.js';

const router = Router();

const asHttp = (error) => {
  if (error?.code === 'validation_failed') return badRequest(error.message);
  if (error?.code === 'conflict') return conflict(error.message);
  return error;
};

router.get(
  '/available',
  rateLimit({ key: 'username:available', points: 60, durationSec: 300, by: ['ip'] }),
  validate({ query: z.object({ name: z.string().max(60) }).passthrough() }),
  route((req) => Usernames.check({ name: req.query.name, userId: req.user?.id ?? null })),
);

router.get('/', requireAuth, route((req) => Usernames.getMine({ userId: req.user.id })));

router.put(
  '/',
  requireAuth,
  rateLimit({ key: 'username:set', points: 10, durationSec: 3600, by: ['user'] }),
  validate({ body: z.object({ username: z.string().max(60).nullable() }) }),
  route(async (req) => {
    try {
      return await Usernames.setMine({ userId: req.user.id, name: req.body.username });
    } catch (error) {
      throw asHttp(error);
    }
  }),
);

export default router;
