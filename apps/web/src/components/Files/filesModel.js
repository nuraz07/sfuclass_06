/**
 * Pure helpers for files  (Files and Media)
 * Tested in __checks__/filesModel.check.mjs. The server decides; these only
 * check early (so nobody waits for an upload that will be refused) and word
 * things.
 */

export const DEFAULT_ACCEPT = ['pdf', 'png', 'jpg', 'gif', 'webp', 'txt', 'csv', 'docx', 'xlsx', 'pptx', 'doc', 'xls', 'ppt', 'mp4', 'm4a', 'mp3', 'wav'];

export const KIND_FILTERS = [
  { value: '', label: 'All' },
  { value: 'image', label: 'Images' },
  { value: 'document', label: 'Documents' },
  { value: 'video', label: 'Video' },
  { value: 'audio', label: 'Audio' },
  { value: 'text', label: 'Text' },
];

export const extensionOf = (name) => {
  const match = /\.([a-z0-9]{1,5})$/i.exec(String(name ?? ''));
  return match ? match[1].toLowerCase() : null;
};

/** "2.4 MB", "830 KB", "12 bytes". */
export const formatBytes = (bytes) => {
  const value = Number(bytes) || 0;
  if (value < 1024) return `${value} ${value === 1 ? 'byte' : 'bytes'}`;
  if (value < 1024 * 1024) return `${Math.round(value / 1024)} KB`;
  if (value < 1024 ** 3) return `${(value / 1024 / 1024).toFixed(value < 10 * 1024 * 1024 ? 1 : 0)} MB`;
  return `${(value / 1024 ** 3).toFixed(1)} GB`;
};

/** The `accept` attribute for a file input: ".pdf,.png,…" (plus .jpeg). */
export const acceptAttribute = (extensions = DEFAULT_ACCEPT) =>
  [...extensions, ...(extensions.includes('jpg') ? ['jpeg'] : [])].map((ext) => `.${ext}`).join(',');

/** The same check the server makes first: a reason, or null. */
export const fileProblem = (file, { accept = DEFAULT_ACCEPT, maxBytes = 50 * 1024 * 1024 } = {}) => {
  const ext = extensionOf(file?.name);
  const allowed = [...accept, ...(accept.includes('jpg') ? ['jpeg'] : [])];
  if (!ext || !allowed.includes(ext)) return `${file?.name ?? 'This file'}: this format is not accepted.`;
  if (!file.size) return `${file.name} is empty.`;
  if (file.size > maxBytes) return `${file.name} is larger than ${Math.round(maxBytes / 1024 / 1024)} MB.`;
  return null;
};

/** A small emoji per kind, for lists without a preview. */
export const iconFor = (kind) => ({ image: '🖼️', document: '📄', video: '🎬', audio: '🎧', text: '📝' })[kind] ?? '📎';

/** "PDF, 1.2 MB" */
export const fileMeta = ({ ext, sizeBytes }) => [ext ? ext.toUpperCase() : null, sizeBytes ? formatBytes(sizeBytes) : null].filter(Boolean).join(', ');

/** 0–100 for a usage bar. */
export const usagePercent = ({ usedBytes, quotaBytes }) => (quotaBytes > 0 ? Math.min(100, Math.round((usedBytes / quotaBytes) * 100)) : 0);

/**
 * In development MinIO listens on localhost:9000, which a browser outside the
 * machine (a Codespace, a phone on the network) cannot reach. Signed URLs for
 * such hosts go through the dev server instead (/s3 → MinIO, vite.config).
 * Real storage URLs are left alone.
 */
const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '0.0.0.0', 'minio', 'host.docker.internal']);
export const reachableUploadUrl = (url, pageOrigin) => {
  try {
    const target = new URL(url);
    if (!LOCAL_HOSTS.has(target.hostname)) return url;
    return `${pageOrigin ?? ''}/s3${target.pathname}${target.search}`;
  } catch {
    return url;
  }
};

/** The API base the browser uses ('/api' in development), plus a path from the API. */
export const apiHref = (path, base = '/api') => (path ? `${String(base).replace(/\/$/, '')}${path}` : null);
