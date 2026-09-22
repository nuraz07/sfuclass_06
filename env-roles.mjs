const { envVariables } = await import('./server/src/config/env.js');
const keys = [
  'SFU_NODE_ID', 'ANNOUNCED_IP', 'MEDIASOUP_MIN_PORT', 'MEDIASOUP_MAX_PORT', 'MEDIASOUP_WORKERS',
  'SFU_MAX_ROOMS_PER_NODE', 'SFU_HTTP_PORT', 'SFU_DRAIN_TIMEOUT_SEC',
  'SCREENSHARE_MAX_PRESENTERS', 'SCREENSHARE_MAX_BITRATE_KBPS', 'SCREENSHARE_MAX_FRAMERATE',
  'SOCKET_PING_INTERVAL_MS', 'SOCKET_PING_TIMEOUT_MS', 'SOCKET_MAX_EVENTS_PER_MIN', 'PRESENCE_TTL_SEC',
  'MEDIASOUP_RTC_PORT_BASE', 'MEDIA_PUBLIC_IPV4', 'MEDIA_PUBLIC_ADDRESS_SOURCE', 'MEDIA_REGION', 'REALTIME_PORT',
];
for (const key of keys) {
  const def = envVariables[key];
  console.log(key.padEnd(30), def ? `declared for: ${def.roles.join(', ')}` : 'NOT DECLARED in env.js');
}
process.exit(0);
