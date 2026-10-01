import { apiHref, reachableUploadUrl } from '../components/Files/filesModel.js';

/**
 * Uploading a file  (Files and Media)
 *
 * startUpload → PUT the bytes to the signed URL (with progress) → completeUpload.
 * Returns the ready file; throws an Error whose message says why not.
 */

export const API_BASE = (import.meta.env?.VITE_API_URL || '/api').replace(/\/$/, '');

/** An absolute-enough href for a path the API returned (openUrl). */
export const fileHref = (path) => apiHref(path, API_BASE);

const put = (url, file, headers, onProgress, signal) =>
  new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('PUT', url);
    for (const [name, value] of Object.entries(headers ?? {})) xhr.setRequestHeader(name, value);
    xhr.upload.onprogress = (event) => event.lengthComputable && onProgress?.(event.loaded / event.total);
    xhr.onload = () => (xhr.status >= 200 && xhr.status < 300 ? resolve() : reject(new Error(`The upload was refused by storage (${xhr.status}).`)));
    xhr.onerror = () => reject(new Error('The upload could not reach the storage. Check your connection.'));
    xhr.onabort = () => reject(new Error('Upload cancelled.'));
    signal?.addEventListener('abort', () => xhr.abort());
    xhr.send(file);
  });

export const uploadFile = async ({ files, file, onProgress, onPhase, signal }) => {
  try {
    onPhase?.('starting');
    const ticket = await files.startUpload({ name: file.name, sizeBytes: file.size });
    onPhase?.('uploading');
    await put(reachableUploadUrl(ticket.uploadUrl, window.location.origin), file, ticket.uploadHeaders, onProgress, signal);
    onPhase?.('checking');
    return await files.completeUpload(ticket.fileId);
  } catch (cause) {
    throw new Error(cause?.detail ?? cause?.message ?? 'The upload did not work.');
  }
};
