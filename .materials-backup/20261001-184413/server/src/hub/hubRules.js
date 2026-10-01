// classroom-app/server/src/hub/hubRules.js
/**
 * Community rules  (Community, part 1)
 *
 * The one place that decides what a person may see and do in a space. Pure:
 * no database, no clock of its own — the service and the tests call the same
 * functions, so the page and the server can never disagree.
 *
 *   kinds    class (a course or class) · topic (an interest) · study (small, ends)
 *   access   open     anyone in the organisation can read and join
 *            request  anyone can see the space exists; a moderator admits
 *            invite   invisible to everyone who is not a member
 *   roles    owner · moderator · member
 *
 * Part 2 adds knowledge cards (a good answer, saved), hidden solutions
 * (replies that show only when opened), a chat per space, materials (links),
 * and drop-in rooms that the space's members may enter.
 *
 * Privacy, unlike a messenger group: members never see each other's email or
 * phone. Names and roles only — and a space can hide its member list from
 * everyone but moderators. A question can be asked anonymously: other members
 * see "Anonymous"; moderators see who it was, so anonymity cannot be used to
 * harass.
 */

import { z } from 'zod';

export const KINDS = ['class', 'topic', 'study'];
export const ACCESS = ['open', 'request', 'invite'];
export const ROLES = ['owner', 'moderator', 'member'];
export const TEACHING_ROLES = new Set(['teacher', 'owner', 'admin']);
export const MAX_STUDY_GROUP = 12;

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

const emoji = z
  .string()
  .max(16)
  .refine((value) => [...value].length <= 4, 'one emoji');

export const CreateSpaceSchema = z
  .object({
    name: z.string().trim().min(2).max(80),
    description: z.string().trim().max(500).nullish(),
    kind: z.enum(KINDS).default('topic'),
    access: z.enum(ACCESS).default('open'),
    memberList: z.enum(['members', 'moderators']).default('members'),
    joinQuestion: z.string().trim().max(200).nullish(),
    endsAt: z.string().datetime({ offset: true }).nullish(),
    emoji: emoji.nullish(),
    tags: z.array(z.string().trim().toLowerCase().min(1).max(24)).max(5).default([]),
  })
  .strict()
  .superRefine((value, ctx) => {
    if (value.kind === 'study' && !value.endsAt) {
      ctx.addIssue({ code: 'custom', path: ['endsAt'], message: 'A study group needs an end date, for example the exam.' });
    }
    if (value.kind !== 'study' && value.endsAt) {
      ctx.addIssue({ code: 'custom', path: ['endsAt'], message: 'Only study groups end.' });
    }
  });

export const UpdateSpaceSchema = z
  .object({
    name: z.string().trim().min(2).max(80),
    description: z.string().trim().max(500).nullable(),
    access: z.enum(ACCESS),
    memberList: z.enum(['members', 'moderators']),
    joinQuestion: z.string().trim().max(200).nullable(),
    endsAt: z.string().datetime({ offset: true }).nullable(),
    emoji: emoji.nullable(),
    tags: z.array(z.string().trim().toLowerCase().min(1).max(24)).max(5),
  })
  .partial()
  .strict();

export const CreateThreadSchema = z
  .object({
    title: z.string().trim().min(3).max(160),
    body: z.string().trim().min(1).max(10000),
    kind: z.enum(['discussion', 'question']).default('discussion'),
    anonymous: z.boolean().default(false),
  })
  .strict()
  .refine((value) => !value.anonymous || value.kind === 'question', {
    message: 'Only questions can be asked anonymously.',
    path: ['anonymous'],
  });

export const ReplySchema = z
  .object({
    body: z.string().trim().min(1).max(10000),
    replyToId: z.string().uuid().nullish(),
    hiddenSolution: z.boolean().default(false),
  })
  .strict();

export const CardSchema = z
  .object({
    title: z.string().trim().min(3).max(160),
    body: z.string().trim().min(1).max(10000),
    postId: z.string().uuid().nullish(),
  })
  .strict();

export const UpdateCardSchema = z
  .object({ title: z.string().trim().min(3).max(160), body: z.string().trim().min(1).max(10000) })
  .partial()
  .strict();

/** Only http(s) links: no javascript:, data: or file: addresses end up clickable. */
export const safeUrl = (value) => {
  try {
    const url = new URL(String(value ?? '').trim());
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.toString() : null;
  } catch {
    return null;
  }
};

export const MaterialSchema = z
  .object({
    title: z.string().trim().min(1).max(120),
    url: z.string().trim().max(2000).refine((value) => safeUrl(value) !== null, 'a web address starting with https://'),
    note: z.string().trim().max(300).nullish(),
    pinned: z.boolean().default(false),
  })
  .strict();

export const ChatMessageSchema = z.object({ body: z.string().trim().min(1).max(2000) }).strict();

/** How long a drop-in room stays open, and how many can start at once in one space. */
export const DROP_IN_MINUTES = 60;

/** Members start drop-in rooms; cards and materials are curated by moderators. */
export const canCurate = (membership) => isModerator(membership);

/** Who may remove a chat message: its author, or a moderator. */
export const canRemoveMessage = ({ authorId, viewerId, membership }) => authorId === viewerId || isModerator(membership);

/** A hidden solution is shown folded to everyone but its author. */
export const solutionFolded = ({ hiddenSolution, authorId, viewerId }) => Boolean(hiddenSolution) && authorId !== viewerId;

export const ReportSchema = z
  .object({
    targetType: z.enum(['thread', 'post', 'user']),
    targetId: z.string().uuid(),
    reason: z.enum(['spam', 'harassment', 'hate', 'inappropriate', 'off-topic', 'other']),
    note: z.string().trim().max(500).nullish(),
  })
  .strict();

// ---------------------------------------------------------------------------
// Decisions
// ---------------------------------------------------------------------------

export const isModerator = (membership) => membership?.role === 'owner' || membership?.role === 'moderator';

/** A study group whose end date has passed is read-only. */
export const hasEnded = (space, now = Date.now()) =>
  Boolean(space.archivedAt) || (space.endsAt ? new Date(space.endsAt).getTime() <= now : false);

/**
 * What someone sees of a space.
 *   'full'    everything (members; everyone in the organisation for open spaces)
 *   'preview' name, description and numbers, to decide whether to ask to join
 *   'hidden'  nothing: the space does not exist for them
 */
export const viewOf = (space, membership) => {
  if (membership) return 'full';
  if (space.access === 'open') return 'full';
  if (space.access === 'request') return 'preview';
  return 'hidden';
};

/** May this person write in the space right now? Returns a reason when not. */
export const postingBlockedBecause = (space, membership, now = Date.now()) => {
  if (!membership) return 'Join the space to write in it.';
  if (hasEnded(space, now)) return 'This space has ended and is read-only.';
  if (membership.timeoutUntil && new Date(membership.timeoutUntil).getTime() > now) {
    return 'A moderator paused your posting here for a while.';
  }
  return null;
};

export const canCreateKind = (kind, userRole) => kind !== 'class' || TEACHING_ROLES.has(userRole);

/** Members see each other unless the space shows its list to moderators only. */
export const memberListVisible = (space, membership) =>
  isModerator(membership) || ((Boolean(membership) || space.access === 'open') && space.memberList !== 'moderators');

/**
 * How an author is shown to a viewer. An anonymous question's author (and
 * that person's replies in the same thread) is "Anonymous" to everyone except
 * the author and the space's moderators.
 */
export const authorView = ({ authorId, displayName, anonymous, viewerId, viewerIsModerator }) => {
  const you = authorId === viewerId;
  if (!anonymous) return { userId: authorId, displayName, anonymous: false, you };
  if (you) return { userId: authorId, displayName, anonymous: true, you, hiddenFromOthers: true };
  if (viewerIsModerator) return { userId: authorId, displayName, anonymous: true, you: false, revealedToModerator: true };
  return { userId: null, displayName: 'Anonymous', anonymous: true, you: false };
};

/** Who may mark an answer: the person who asked, or a moderator. */
export const canMarkAnswer = ({ thread, viewerId, membership }) =>
  thread.kind === 'question' && (thread.authorId === viewerId || isModerator(membership));

/** Who may delete a post or thread: its author, or a moderator. */
export const canRemove = ({ authorId, viewerId, membership }) => authorId === viewerId || isModerator(membership);

/** Study groups stay small, so they stay a group. */
export const roomForMember = (space, memberCount) => space.kind !== 'study' || memberCount < MAX_STUDY_GROUP;

/** A short excerpt for lists, without markdown noise. */
export const excerpt = (text, length = 180) => {
  const clean = String(text ?? '')
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/[#>*_`~\[\]()]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  return clean.length > length ? `${clean.slice(0, length - 1).trimEnd()}…` : clean;
};

export default {
  KINDS, ACCESS, ROLES, CreateSpaceSchema, UpdateSpaceSchema, CreateThreadSchema, ReplySchema, ReportSchema,
  CardSchema, UpdateCardSchema, MaterialSchema, ChatMessageSchema, safeUrl, canCurate, canRemoveMessage, solutionFolded,
  isModerator, hasEnded, viewOf, postingBlockedBecause, canCreateKind, memberListVisible, authorView,
  canMarkAnswer, canRemove, roomForMember, excerpt,
};
