// server/src/realtime/collabServer.js
/**
 * Collaborative documents  (F1, F3)
 *
 * One registry of Yjs documents per process, keyed by name:
 *
 *   whiteboard:<roomId>     classroom/interaction/Whiteboard.js
 *   course:<courseId>       the course builder (F3)
 *
 * This module owns the documents' lifetime in memory: create on first use,
 * replace (a cleared whiteboard), release when the room or editor closes.
 * Snapshots are the owner's job — Whiteboard.js writes its board back against
 * the lesson — because only the owner knows where a document belongs.
 *
 * Not in here yet: the sync transport that carries Yjs updates between the
 * browsers and these documents (y-protocols over the /collab socket, with the
 * write check from Whiteboard.canDraw). Until it exists, documents live and
 * persist on the server, but a client's strokes do not reach them.
 *
 * `yjs` is imported on first use, so a process that never opens a document
 * (the worker, the SFU in production) does not need the package, and a missing
 * install fails the whiteboard with a clear message rather than the boot.
 */

import { logger } from '../observability/logger.js';

const log = logger.child({ component: 'collab' });

const NAME = /^[A-Za-z0-9._:-]{1,200}$/;

/** name -> Y.Doc */
const docs = new Map();

let yjs = null;

const loadYjs = async () => {
  if (yjs) return yjs;
  try {
    yjs = await import('yjs');
    return yjs;
  } catch (cause) {
    throw Object.assign(new Error('collaborative documents need the "yjs" package (npm i yjs -w @classroom/server)'), {
      code: 'dependency_missing',
      cause,
    });
  }
};

const assertName = (name) => {
  if (typeof name !== 'string' || !NAME.test(name)) {
    throw new TypeError(`collabServer: invalid document name '${name}'`);
  }
};

/**
 * The document with this name, created empty if it does not exist.
 * Idempotent: every peer opening the same board gets the same instance.
 * @param {string} name
 * @returns {Promise<import('yjs').Doc>}
 */
export const getOrCreateDoc = async (name) => {
  assertName(name);
  const existing = docs.get(name);
  if (existing) return existing;

  const { Doc } = await loadYjs();
  // Another caller may have created it while yjs was loading.
  const raced = docs.get(name);
  if (raced) return raced;

  const doc = new Doc({ gc: true });
  docs.set(name, doc);
  log.debug({ name }, 'document created');
  return doc;
};

/** The document if it is open, without creating one. */
export const getDoc = (name) => docs.get(name) ?? null;

/**
 * Swaps the document for an empty one. Used to clear a whiteboard: a CRDT
 * keeps every deleted stroke as a tombstone, so starting over is the only way
 * to shed the history.
 * @param {string} name
 * @returns {Promise<import('yjs').Doc>}
 */
export const replaceDoc = async (name) => {
  assertName(name);
  const { Doc } = await loadYjs();
  const previous = docs.get(name);
  const doc = new Doc({ gc: true });
  docs.set(name, doc);
  previous?.destroy();
  log.debug({ name, replaced: Boolean(previous) }, 'document replaced');
  return doc;
};

/**
 * Drops the document from memory. The owner snapshots it first if it wants
 * to keep it.
 * @param {string} name
 * @returns {Promise<boolean>} whether a document was open
 */
export const releaseDoc = async (name) => {
  const doc = docs.get(name);
  if (!doc) return false;
  docs.delete(name);
  doc.destroy();
  log.debug({ name }, 'document released');
  return true;
};

/** Names of the open documents, for health and debugging. */
export const listDocs = () => [...docs.keys()];

/** Shutdown: drop everything still open. */
export const releaseAll = () => {
  for (const doc of docs.values()) doc.destroy();
  const count = docs.size;
  docs.clear();
  return count;
};

export default { getOrCreateDoc, getDoc, replaceDoc, releaseDoc, listDocs, releaseAll };