// classroom-app/server/src/notifications/focusSummary.js
/**
 * The summary someone gets after a lesson, from what was held back while they
 * were in it. Pure, so the wording is tested rather than discovered.
 *
 * Held items: { type: 'message' | 'mention', from, conversationId?, channelId? }
 */

const plural = (count, one, many) => `${count} ${count === 1 ? one : many}`;

const names = (list) => {
  if (list.length === 0) return '';
  if (list.length === 1) return list[0];
  if (list.length === 2) return `${list[0]} and ${list[1]}`;
  return `${list[0]}, ${list[1]} and ${plural(list.length - 2, 'other', 'others')}`;
};

export const summarizeHeld = (items = []) => {
  const valid = items.filter((item) => item && (item.type === 'message' || item.type === 'mention'));
  if (valid.length === 0) return null;

  const messages = valid.filter((item) => item.type === 'message');
  const mentions = valid.filter((item) => item.type === 'mention');
  const chats = new Set(valid.map((item) => item.conversationId ?? `channel:${item.channelId ?? ''}`));
  const senders = [...new Set(valid.map((item) => item.from).filter(Boolean))];
  const from = senders.length ? ` from ${names(senders)}` : '';

  const parts = [];
  if (messages.length > 0) {
    const where = chats.size > 1 ? ` in ${plural(chats.size, 'chat', 'chats')}` : '';
    parts.push(`${plural(messages.length, 'new message', 'new messages')}${where}${from}`);
    if (mentions.length > 0) parts.push(plural(mentions.length, 'mention', 'mentions'));
  } else {
    parts.push(`${plural(mentions.length, 'mention', 'mentions')}${from}`);
  }

  const onlyConversation = chats.size === 1 && valid[0].conversationId ? valid[0].conversationId : null;

  return {
    title: 'While you were in your lesson',
    body: parts.join(', '),
    url: onlyConversation ? `/messages/${onlyConversation}` : '/messages',
    count: valid.length,
    mentions: mentions.length,
  };
};

export default summarizeHeld;
