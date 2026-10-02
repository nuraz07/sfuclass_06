/**
 * files.routes — uploads and the Media library  (Files and Media)
 *
 * Mounted under /files (app.js). Storage and rules: files/FileService.js.
 *
 *   POST   /uploads            { name, sizeBytes } → a signed PUT URL into storage
 *   POST   /:id/complete       after the PUT: checked, scanned, ready (or refused with the reason)
 *   GET    /?q=&kind=&sort=    my library, with usage and the accepted formats
 *                              (sort: new · old · name · size)
 *   GET    /:id/usage          the spaces where one of my files is a material
 *   PATCH  /:id  { name }      rename
 *   DELETE /:id                delete (also from every space it was a material in)
 *   GET    /:id/link           a fresh link to open the file (owner, or the spaces it is in)
 *   GET    /:id/content?t=…    the file itself — no sign-in header needed, the
 *                              link's signature is the permission (new tabs send none)
 *
 * The older /media routes are left as they are.
 */

import { Router } from 'express';
import { z } from 'zod';

import * as Files from '../files/FileService.js';
import { SORT_KEYS } from '../files/libraryRules.js';
import { viewerOf } from '../hub/HubService.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { route, validate, requireAuth, notFound, badRequest, forbidden } from './_helpers.js';

const router = Router();

const asHttp = (error) => {
  switch (error?.code) {
    case 'validation_failed':
      return badRequest(error.message);
    case 'forbidden':
      return forbidden(error.message);
    case 'not_found':
      return notFound(error.message);
    default:
      return error;
  }
};

const handle = (fn) =>
  route(async (req, res) => {
    try {
      return await fn(req, res, await viewerOf(req.user.id));
    } catch (error) {
      throw asHttp(error);
    }
  });

const idParam = z.object({ id: z.string().uuid() });

router.post(
  '/uploads',
  requireAuth,
  rateLimit({ key: 'files:upload', points: 60, durationSec: 600, by: ['user'] }),
  validate({ body: z.object({ name: z.string().trim().min(1).max(255), sizeBytes: z.number().int().min(1) }) }),
  handle(async (req, res, viewer) => {
    res.status(201);
    return Files.createUpload({ viewer, name: req.body.name, sizeBytes: req.body.sizeBytes });
  }),
);

router.post('/:id/complete', requireAuth, validate({ params: idParam }), handle((req, res, viewer) => Files.completeUpload({ viewer, fileId: req.params.id })));

router.get(
  '/',
  requireAuth,
  validate({
    query: z
      .object({ q: z.string().trim().max(80).optional(), kind: z.enum(['image', 'document', 'video', 'audio', 'text']).optional(), sort: z.enum(SORT_KEYS).optional() })
      .passthrough(),
  }),
  handle((req, res, viewer) => {
    // Express 5 makes req.query read-only; validate() puts the parsed copy here.
    const query = req.validatedQuery ?? req.query;
    return Files.list({ viewer, q: query.q || null, kind: query.kind ?? null, sort: query.sort ?? 'new' });
  }),
);

router.patch(
  '/:id',
  requireAuth,
  validate({ params: idParam, body: z.object({ name: z.string().trim().min(1).max(200) }) }),
  handle((req, res, viewer) => Files.rename({ viewer, fileId: req.params.id, name: req.body.name })),
);

router.delete('/:id', requireAuth, validate({ params: idParam }), handle((req, res, viewer) => Files.remove({ viewer, fileId: req.params.id })));

router.get('/:id/usage', requireAuth, validate({ params: idParam }), handle((req, res, viewer) => Files.usage({ viewer, fileId: req.params.id })));

router.get('/:id/link', requireAuth, validate({ params: idParam }), handle((req, res, viewer) => Files.linkFor({ viewer, fileId: req.params.id })));

/** Streams the file. Not wrapped in route(): the answer is bytes, not JSON. */
router.get('/:id/content', validate({ params: idParam }), async (req, res, next) => {
  try {
    const opened = await Files.open({ fileId: req.params.id, token: req.query.t, rangeHeader: req.get('range') });
    // The global security headers are for the app's pages; a file gets its own (fileRules.deliveryHeaders).
    res.removeHeader('Content-Security-Policy');
    res.removeHeader('Cross-Origin-Embedder-Policy');
    res.status(opened.status).set(opened.headers);
    if (!opened.body) return res.end();
    opened.body.on('error', (error) => res.destroy(error));
    req.on('close', () => opened.body.destroy?.());
    return opened.body.pipe(res);
  } catch (error) {
    if (error?.code === 'forbidden' || error?.code === 'not_found') {
      res.status(error.code === 'forbidden' ? 403 : 404).type('text/plain; charset=utf-8').send(error.message);
      return undefined;
    }
    return next(error);
  }
});

export default router;
