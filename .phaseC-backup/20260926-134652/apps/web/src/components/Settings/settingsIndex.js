/**
 * Everything the settings search can find. `anchor` is the id of the element
 * on the tab (`setting-<anchor>`); keywords are the words people actually type.
 */
export const SETTINGS_INDEX = [
  { tab: 'profile', anchor: 'display-name', label: 'Display name', keywords: 'name full name rename' },
  { tab: 'profile', anchor: 'handle', label: 'Handle for @mentions', keywords: 'username handle mention @' },
  { tab: 'profile', anchor: 'headline', label: 'Headline', keywords: 'title tagline headline' },
  { tab: 'profile', anchor: 'bio', label: 'About me', keywords: 'bio about description' },
  { tab: 'profile', anchor: 'links', label: 'Links', keywords: 'website link url portfolio' },
  { tab: 'profile', anchor: 'view-as', label: 'View your profile as someone else', keywords: 'preview view as how others see' },
  { tab: 'privacy', anchor: 'checkup', label: 'Privacy check-up', keywords: 'overview summary privacy' },
  { tab: 'privacy', anchor: 'dm', label: 'Who can send you private messages', keywords: 'dm direct message private chat receive messages' },
  { tab: 'privacy', anchor: 'visibility', label: 'Who can see your profile', keywords: 'visibility profile hidden private' },
  { tab: 'privacy', anchor: 'presence', label: 'Show when I am online', keywords: 'online status presence' },
  { tab: 'privacy', anchor: 'receipts', label: 'Read receipts', keywords: 'read seen receipts' },
  { tab: 'privacy', anchor: 'blocked', label: 'Blocked people', keywords: 'block unblock blocked' },
  { tab: 'region', anchor: 'language', label: 'Language', keywords: 'language locale' },
  { tab: 'region', anchor: 'timezone', label: 'Time zone', keywords: 'time zone timezone clock' },
  { tab: 'region', anchor: 'date-format', label: 'Date format', keywords: 'date format day month year' },
  { tab: 'region', anchor: 'time-format', label: 'Time format', keywords: 'time 24 12 hour am pm' },
  { tab: 'lessons', anchor: 'join', label: 'Microphone and camera when joining', keywords: 'join muted mic microphone camera video start' },
  { tab: 'lessons', anchor: 'audio', label: 'Noise suppression and echo cancellation', keywords: 'noise echo audio sound' },
  { tab: 'lessons', anchor: 'data-saver', label: 'Data saver', keywords: 'data saver bandwidth mobile quality' },
  { tab: 'lessons', anchor: 'devices', label: 'Camera, microphone and speaker test', keywords: 'device test camera webcam microphone mic speaker headset sound' },
  { tab: 'appearance', anchor: 'font-size', label: 'Text size', keywords: 'font text size bigger smaller zoom' },
  { tab: 'appearance', anchor: 'motion', label: 'Reduce motion', keywords: 'motion animation reduce' },
  { tab: 'teaching', anchor: 'reactions', label: 'Reactions in your lessons', keywords: 'emoji reactions lesson default' },
  { tab: 'teaching', anchor: 'join-muted', label: 'Learners join muted', keywords: 'muted join learners microphone default' },
  { tab: 'notifications', anchor: 'matrix', label: 'What you are notified about', keywords: 'notifications types channels email push in app messages mentions chatroom community courses' },
  { tab: 'notifications', anchor: 'push', label: 'Push on this device', keywords: 'push browser device notifications enable permission' },
  { tab: 'notifications', anchor: 'test', label: 'Send a test notification', keywords: 'test notification check email push' },
  { tab: 'notifications', anchor: 'quiet', label: 'Quiet hours', keywords: 'quiet hours night do not disturb sleep silent' },
  { tab: 'notifications', anchor: 'focus', label: 'Focus during lessons', keywords: 'focus lesson class summary interrupt' },
  { tab: 'notifications', anchor: 'previews', label: 'Show message text in push and email', keywords: 'preview message text lock screen privacy' },
  { tab: 'notifications', anchor: 'digest', label: 'Community digest', keywords: 'digest email daily weekly summary community' },
  { tab: 'notifications', anchor: 'muted', label: 'Muted chats', keywords: 'mute muted unmute chats silence' },
  { tab: 'security', anchor: 'sessions', label: 'Where you are signed in', keywords: 'devices sessions signed in logged in browsers phone computer' },
  { tab: 'security', anchor: 'sign-out-others', label: 'Sign out everywhere else', keywords: 'sign out log out everywhere other devices' },
  { tab: 'security', anchor: 'login-history', label: 'Sign-in history', keywords: 'login sign in history failed attempts security' },
  { tab: 'activity', anchor: 'changes', label: 'Recent changes', keywords: 'history changes activity log audit' },
];

export const searchSettings = (query, tabs) => {
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0) return [];
  const allowed = new Set(tabs.map((t) => t.id));
  return SETTINGS_INDEX.filter(
    (entry) =>
      allowed.has(entry.tab) &&
      words.every((word) => `${entry.label} ${entry.keywords}`.toLowerCase().includes(word)),
  );
};
