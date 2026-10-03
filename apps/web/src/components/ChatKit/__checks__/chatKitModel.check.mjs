// node --test apps/web/src/components/ChatKit/__checks__/chatKitModel.check.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { attachProblem, formatDuration, recorderFormat, reactionTitle, toggleAction, splitFiles, filesLabel, QUICK_REACTIONS, EMOJI_GROUPS, MAX_FILES } from '../chatKitModel.js';

test('what can be attached', () => {
  assert.equal(attachProblem({ name: 'a.pdf', size: 10 }), null);
  assert.equal(attachProblem({ name: 'voice.webm', size: 10 }), null);
  assert.match(attachProblem({ name: 'x.exe', size: 10 }), /cannot be sent/);
  assert.match(attachProblem({ name: 'a.pdf', size: 0 }), /empty/);
  assert.match(attachProblem({ name: 'a.pdf', size: 60 * 1024 * 1024 }), /larger than 50 MB/);
  assert.match(attachProblem({ name: 'a.pdf', size: 1 }, { staged: MAX_FILES }), /Up to 10/);
});

test('durations', () => {
  assert.equal(formatDuration(0), '0:00');
  assert.equal(formatDuration(7400), '0:07');
  assert.equal(formatDuration(65_000), '1:05');
  assert.equal(formatDuration(-3), '0:00');
});

test('recording formats per browser', () => {
  assert.deepEqual(recorderFormat((t) => t === 'audio/webm;codecs=opus'), { mimeType: 'audio/webm;codecs=opus', ext: 'webm' });
  assert.deepEqual(recorderFormat((t) => t === 'audio/ogg;codecs=opus'), { mimeType: 'audio/ogg;codecs=opus', ext: 'ogg' });
  assert.deepEqual(recorderFormat((t) => t === 'audio/mp4'), { mimeType: 'audio/mp4', ext: 'm4a' });
  assert.equal(recorderFormat(() => false), null);
  assert.equal(recorderFormat(() => { throw new Error('x'); }), null);
  assert.equal(recorderFormat(undefined), null);
});

test('reactions: tooltip and toggle', () => {
  assert.equal(reactionTitle({ emoji: '👍', count: 2, names: ['Ann', 'You'] }), 'Ann and You reacted with 👍');
  assert.equal(reactionTitle({ emoji: '👍', count: 5, names: ['Ann', 'Ben'] }), 'Ann, Ben and 3 others reacted with 👍');
  assert.equal(reactionTitle({ emoji: '👍', count: 1, names: [] }), '1 reacted with 👍');
  assert.equal(toggleAction([{ emoji: '👍', reacted: true }], '👍'), 'remove');
  assert.equal(toggleAction([{ emoji: '👍', reacted: false }], '👍'), 'add');
  assert.equal(toggleAction([], '❤️'), 'add');
  assert.equal(QUICK_REACTIONS.length, 6);
  assert.ok(EMOJI_GROUPS.every((g) => g.emoji.length >= 10));
});

test('files: grouping and labels', () => {
  const files = [{ kind: 'image', name: 'a.png' }, { kind: 'document', name: 'b.pdf' }, { kind: 'video', name: 'c.mp4' }];
  const parts = splitFiles(files);
  assert.deepEqual([parts.visual.length, parts.other.length, parts.voice.length], [2, 1, 0]);
  assert.equal(filesLabel([{ voice: true, durationMs: 5000 }]), '🎤 Voice message (0:05)');
  assert.equal(filesLabel([{ kind: 'image', name: 'a.png' }]), '🖼 a.png');
  assert.equal(filesLabel(files), '📎 3 files');
  assert.equal(filesLabel([]), '');
});
