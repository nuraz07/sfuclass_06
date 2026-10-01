// classroom-app/server/src/files/FileStore.js
/**
 * Object storage for Files  (Files)
 *
 * A thin layer over S3 (MinIO locally), using the platform's existing storage
 * configuration (config/storage.config.js): the same buckets, the same
 * credentials. Two buckets matter here:
 *
 *   raw       where the browser uploads to, with a short-lived signed PUT URL.
 *             Nothing is ever served from it.
 *   delivery  where a file moves once its bytes are checked (and scanned).
 *             Served only through FileService, never directly.
 *
 * Also the ClamAV client for ANTIVIRUS_MODE=clamav: the file is streamed to
 * clamd (INSTREAM), never written to disk on the API host.
 */

import net from 'node:net';
import { buckets, s3ClientOptions } from '../config/storage.config.js';

let client = null;
const s3 = async () => {
  if (!client) {
    const { S3Client } = await import('@aws-sdk/client-s3');
    client = new S3Client(s3ClientOptions);
  }
  return client;
};
const bucketName = (alias) => buckets?.[alias] ?? alias;

/** A signed URL the browser PUTs the file to, valid for `expiresIn` seconds. */
export const presignPut = async ({ key, contentType, expiresIn = 900 }) => {
  const { PutObjectCommand } = await import('@aws-sdk/client-s3');
  const { getSignedUrl } = await import('@aws-sdk/s3-request-presigner');
  return getSignedUrl(await s3(), new PutObjectCommand({ Bucket: bucketName('raw'), Key: key, ContentType: contentType }), { expiresIn });
};

/** Size of an object, or null when it is not there. */
export const head = async ({ bucket, key }) => {
  const { HeadObjectCommand } = await import('@aws-sdk/client-s3');
  try {
    const result = await (await s3()).send(new HeadObjectCommand({ Bucket: bucketName(bucket), Key: key }));
    return { size: Number(result.ContentLength ?? 0) };
  } catch (cause) {
    if (cause?.$metadata?.httpStatusCode === 404 || cause?.name === 'NotFound' || cause?.name === 'NoSuchKey') return null;
    throw cause;
  }
};

/** The first `bytes` bytes of an object, for checking what it really is. */
export const readStart = async ({ bucket, key, bytes }) => {
  const { GetObjectCommand } = await import('@aws-sdk/client-s3');
  const result = await (await s3()).send(new GetObjectCommand({ Bucket: bucketName(bucket), Key: key, Range: `bytes=0-${bytes - 1}` }));
  return new Uint8Array(await result.Body.transformToByteArray());
};

/** A readable stream of the object, or of a byte range of it. */
export const stream = async ({ bucket, key, range = null }) => {
  const { GetObjectCommand } = await import('@aws-sdk/client-s3');
  const result = await (await s3()).send(
    new GetObjectCommand({ Bucket: bucketName(bucket), Key: key, ...(range ? { Range: `bytes=${range.start}-${range.end}` } : {}) }),
  );
  return result.Body;
};

/** raw → delivery: copy first, delete after, so a failed copy loses nothing. */
export const promote = async ({ key }) => {
  const { CopyObjectCommand, DeleteObjectCommand } = await import('@aws-sdk/client-s3');
  const c = await s3();
  await c.send(new CopyObjectCommand({ Bucket: bucketName('delivery'), Key: key, CopySource: `${bucketName('raw')}/${key.split('/').map(encodeURIComponent).join('/')}` }));
  await c.send(new DeleteObjectCommand({ Bucket: bucketName('raw'), Key: key })).catch(() => undefined);
};

export const remove = async ({ bucket, key }) => {
  const { DeleteObjectCommand } = await import('@aws-sdk/client-s3');
  await (await s3()).send(new DeleteObjectCommand({ Bucket: bucketName(bucket), Key: key })).catch(() => undefined);
};

/**
 * Streams a file to clamd. Resolves { clean: true } or { clean: false, signature }.
 * Rejects when clamd cannot be reached or answers something unexpected.
 */
export const scanWithClamd = ({ body, host, port, timeoutMs = 60_000 }) =>
  new Promise((resolve, reject) => {
    const socket = net.createConnection({ host, port: Number(port) || 3310 });
    let answer = '';
    const fail = (error) => {
      socket.destroy();
      reject(error);
    };
    socket.setTimeout(timeoutMs, () => fail(new Error('clamd timed out')));
    socket.on('error', fail);
    socket.on('data', (chunk) => {
      answer += chunk.toString('utf8');
    });
    socket.on('end', () => {
      const text = answer.replace(/\0/g, '').trim();
      if (/:\s*OK$/.test(text)) resolve({ clean: true });
      else if (/FOUND$/.test(text)) resolve({ clean: false, signature: text.replace(/^stream:\s*/, '').replace(/\s*FOUND$/, '') });
      else reject(new Error(`clamd answered: ${text || 'nothing'}`));
    });
    socket.on('connect', async () => {
      try {
        socket.write('zINSTREAM\0');
        for await (const chunk of body) {
          const size = Buffer.alloc(4);
          size.writeUInt32BE(chunk.length, 0);
          socket.write(size);
          socket.write(chunk);
        }
        socket.write(Buffer.alloc(4));
      } catch (error) {
        fail(error);
      }
    });
  });

export default { presignPut, head, readStart, stream, promote, remove, scanWithClamd };
