// server/src/rtc/RegionHint.js
//
// Turns the client's region hint into a trusted region, or null.
//
// The hint comes from packages/core-client/src/rtc/ConnectivityProbe.ts, which measures the time to
// gather a server-reflexive candidate against each region's STUN endpoint (≈ RTT). It is sent with
// room.join / POST /rtc/ice-servers in one of these shapes:
//
//   "eu-central-1"
//   { "region": "eu-central-1", "rttMs": 23 }
//   [ { "region": "eu-central-1", "rttMs": 23 }, { "region": "us-east-1", "rttMs": 98 } ]
//
// The hint is untrusted input. It is only ever used to choose among regions the platform has enabled,
// the tenant allows and that have live TURN capacity; it can never widen what is allowed. Anything
// malformed is ignored (null), never an error — the hint is an optimisation, not a requirement.
//
// Owner: F8 Real-Time Connectivity. Used by IceServerService.js (and RoomPlacementService.js for new rooms).

import { z } from 'zod';

const REGION_PATTERN = /^[a-z]{2}(-[a-z]+)+-\d{1,2}$/;
const MAX_ENTRIES = 16;

const entrySchema = z.object({
  region: z.string().regex(REGION_PATTERN),
  rttMs: z.number().finite().nonnegative().optional(),
});
const hintSchema = z.union([
  z.string().regex(REGION_PATTERN).transform((region) => [{ region }]),
  entrySchema.transform((entry) => [entry]),
  z.array(entrySchema).min(1).max(MAX_ENTRIES),
]);

export class RegionHint {
  /**
   * @param {object} options
   * @param {import('./TurnPoolRegistry.js').TurnPoolRegistry} options.registry
   * @param {string[]} options.enabledRegions   media regions from config/ice.config.js
   * @param {number} [options.maxRttMs=5000]    larger values are treated as measurement errors
   */
  constructor({ registry, enabledRegions, maxRttMs = 5_000 }) {
    if (!registry) throw new TypeError('RegionHint: registry is required');
    if (!Array.isArray(enabledRegions) || enabledRegions.length === 0) {
      throw new TypeError('RegionHint: enabledRegions must be a non-empty array');
    }
    this.#registry = registry;
    this.#enabled = Object.freeze([...new Set(enabledRegions)]);
    this.#maxRttMs = maxRttMs;
  }

  #registry;
  #enabled;
  #maxRttMs;

  /**
   * @param {{ hint: unknown, allowedRegions?: readonly string[] | null }} input
   * @returns {Promise<string | null>} the lowest-RTT live, allowed region the client named
   */
  async resolve({ hint, allowedRegions = null }) {
    if (hint === undefined || hint === null) return null;
    const parsed = hintSchema.safeParse(hint);
    if (!parsed.success) return null;

    const permitted = new Set(
      this.#enabled.filter((r) => allowedRegions === null || allowedRegions.includes(r)),
    );
    const candidates = parsed.data.filter(
      (e) => permitted.has(e.region) && (e.rttMs === undefined || e.rttMs <= this.#maxRttMs),
    );
    if (candidates.length === 0) return null;

    const live = new Set(await this.#registry.liveRegions(candidates.map((c) => c.region)));
    const ranked = candidates
      .filter((c) => live.has(c.region))
      // Measured entries first, by RTT; unmeasured entries keep the client's order after them.
      .sort((a, b) => (a.rttMs ?? Number.POSITIVE_INFINITY) - (b.rttMs ?? Number.POSITIVE_INFINITY));
    return ranked[0]?.region ?? null;
  }
}