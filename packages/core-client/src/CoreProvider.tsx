/**
 * CoreProvider  (F5)
 *
 * Owns the things that are singular per tab: the API client with its refresh
 * and trace ids, the authenticated session, the chat socket, and the room-to-
 * node resolver. Nothing below it constructs a transport of its own.
 *
 * What it deliberately does *not* own: the SfuClient.
 *
 * A tab has one HTTP client and one chat connection for its whole life. A
 * lesson does not — it starts when someone opens a room and ends when they
 * leave, and it drags in mediasoup-client, the largest dependency in the
 * product. Building it here would put mediasoup in the main bundle and make the
 * lazy route split in main.jsx meaningless. The classroom route assembles its
 * own SfuClient from the pieces below, so mediasoup loads only for people who
 * actually join a lesson.
 *
 * Three things are worth reading before changing anything here.
 *
 * Tokens. Both the access token and the refresh token live in memory. The
 * refresh token would normally sit in an httpOnly cookie, and in production it
 * should — but behind a tunnel that serves the page over https while proxying
 * to a plain-http API, browsers discard that cookie without a word: no console
 * warning, no failed request, only a 401 several steps later that looks like an
 * auth bug rather than a storage one. Asking for the token in the response body
 * with `wantsRefreshToken` — the path apps/mobile already uses, because a React
 * Native app has no cookie jar either — removes the browser's cookie policy
 * from the equation entirely.
 *
 * The cost is explicit: nothing survives a reload, so a reload signs you out.
 * That is a development trade, not a design. Restoring the cookie path means
 * dropping `wantsRefreshToken` and letting refresh read the cookie again.
 *
 * Two-step sign-in (Settings, Phase C). For an account with an authenticator
 * app or a passkey, POST /auth/login answers with a challenge instead of
 * tokens. signIn() then throws SecondFactorRequired, and the sign-in page
 * finishes with completeSignIn() (a code) or signInWithPasskey() (a passkey,
 * with or without a password first). Nothing is signed in before that.
 *
 * CSRF. middleware/csrf.js issues the cookie on the way out but validates on
 * the way in, so the very first call to a protected route can never succeed — a
 * client cannot echo a token it has not been given. Bootstrapping therefore
 * runs in two steps: GET /auth/csrf, which is an ignored method and returns the
 * token in its body, then the protected call with that token echoed back.
 */

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react';

import { ApiError, HEADERS } from '@classroom/contracts';

import { createHttpClient, type AuthProvider, type HttpClient } from './http/httpClient.js';
import { createSocketClient, type SocketClient } from './socket/socketClient.js';
import { createNodeResolver, type NodeResolver } from './rtc/nodeResolver.js';

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

export interface Session {
  userId: string;
  displayName: string;
  avatarUrl: string | null;
  /** Tenant role, not the room role — a teacher is still a learner elsewhere. */
  role: 'owner' | 'teacher' | 'learner';
  tenantId: string;
}

export type AuthStatus = 'restoring' | 'authenticated' | 'anonymous';

/** What auth.routes.js `issue()` puts in the body. */
export interface TokenResponse {
  accessToken: string;
  expiresIn: number;
  tokenType: 'Bearer';
  user: Session;
  /** Present only when the request asked for it. */
  refreshToken?: string;
  sessionId?: string;
}

/** POST /auth/login for an account with two-step sign-in. */
interface ChallengeResponse {
  secondFactorRequired: true;
  challengeId: string;
  methods: Array<'totp' | 'recovery' | 'passkey'>;
  expiresInSec?: number;
}

/**
 * Thrown by signIn() when the password was right and a second step is needed.
 * Not an ApiError: nothing failed.
 */
export class SecondFactorRequired extends Error {
  readonly secondFactorRequired = true;
  readonly challengeId: string;
  readonly methods: ChallengeResponse['methods'];
  readonly expiresInSec: number;

  constructor(challenge: ChallengeResponse) {
    super('A second step is needed to sign in.');
    this.name = 'SecondFactorRequired';
    this.challengeId = challenge.challengeId;
    this.methods = challenge.methods ?? [];
    this.expiresInSec = challenge.expiresInSec ?? 300;
  }
}

/** WebAuthn options as the server sends them (JSON, base64url). */
export interface PasskeyOptions {
  optionsId: string;
  options: Record<string, unknown>;
}

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

export interface CoreContextValue {
  http: HttpClient;
  nodeResolver: NodeResolver;
  /** The `/chat` connection. Null until there is a session to authenticate it. */
  chatSocket: SocketClient | null;
  session: Session | null;
  status: AuthStatus;
  release: string;
  apiUrl: string;
  wsUrl: string;
  /** Handed to SfuClient and to any socket the classroom route opens. */
  getAccessToken(): string | null;
  /** Throws SecondFactorRequired when the account has two-step sign-in. */
  signIn(credentials: { email: string; password: string }): Promise<Session>;
  /** The second step with a code from the authenticator app or a recovery code. */
  completeSignIn(input: { challengeId: string; code: string }): Promise<Session>;
  /** Options for a passkey: the second step (with a challengeId) or a sign-in on its own. */
  passkeyOptions(input?: { challengeId?: string | null }): Promise<PasskeyOptions>;
  /** Finishes a passkey sign-in with the browser's answer. */
  signInWithPasskey(input: {
    challengeId?: string | null;
    optionsId: string;
    response: Record<string, unknown>;
  }): Promise<Session>;
  signOut(): Promise<void>;
}

const CoreContext = createContext<CoreContextValue | null>(null);

export const useCore = (): CoreContextValue => {
  const value = useContext(CoreContext);
  if (!value) throw new Error('useCore must be used inside <CoreProvider>');
  return value;
};

/** Convenience accessors, so a component that needs one thing imports one thing. */
export const useHttp = (): HttpClient => useCore().http;
export const useSession = (): Session | null => useCore().session;

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

export interface CoreProviderProps {
  apiUrl: string;
  wsUrl: string;
  release: string;
  children: ReactNode;
  /** Where to send someone whose session expired. Defaults to no redirect. */
  onSessionExpired?(): void;
}

export function CoreProvider({
  apiUrl,
  wsUrl,
  release,
  children,
  onSessionExpired,
}: CoreProviderProps) {
  // Refs, not state: all four are read inside callbacks that must not go stale
  // between renders, and changing any of them should never trigger one.
  const accessTokenRef = useRef<string | null>(null);
  const csrfTokenRef = useRef<string | null>(null);
  const refreshTokenRef = useRef<string | null>(null);
  const sessionIdRef = useRef<string | null>(null);

  const [session, setSession] = useState<Session | null>(null);
  // Nothing persists across a reload, so there is no session to restore and no
  // reason to start in 'restoring' and make everyone wait for a call that
  // cannot succeed.
  const [status, setStatus] = useState<AuthStatus>('anonymous');

  const sessionExpiredRef = useRef(onSessionExpired);
  sessionExpiredRef.current = onSessionExpired;

  // -------------------------------------------------------------------------
  // HTTP
  // -------------------------------------------------------------------------

  const http = useMemo<HttpClient>(() => {
    const auth: AuthProvider = {
      getAccessToken: () => accessTokenRef.current,

      /**
       * httpClient serialises concurrent callers onto one call, so a burst of
       * 401s produces one refresh — which matters because the refresh token
       * rotates on every use and a second concurrent call would present an
       * already-rotated token. AuthService treats that as theft and revokes the
       * whole session family.
       */
      async refresh() {
        // No token in memory means there is nothing to refresh. Saying so here
        // is better than asking the server to tell us the same thing with a
        // 401 that then looks like a failure.
        if (!refreshTokenRef.current || !sessionIdRef.current) return null;

        try {
          // A plain client, because using the outer one would recurse: its own
          // 401 handling would call this method again.
          const bare = createHttpClient({ baseUrl: apiUrl, credentials: 'include' });

          const result = (await bare.post(
            '/auth/refresh',
            {
              refreshToken: refreshTokenRef.current,
              sessionId: sessionIdRef.current,
            },
            { anonymous: true, headers: await csrfHeaders(bare) },
          )) as TokenResponse;

          accessTokenRef.current = result.accessToken;
          // Rotation: the old token is spent, and presenting it again would
          // look like theft.
          if (result.refreshToken) refreshTokenRef.current = result.refreshToken;
          if (result.sessionId) sessionIdRef.current = result.sessionId;

          setSession(result.user);
          setStatus('authenticated');
          return result.accessToken;
        } catch {
          return null;
        }
      },

      onSessionExpired() {
        accessTokenRef.current = null;
        refreshTokenRef.current = null;
        sessionIdRef.current = null;
        setSession(null);
        setStatus('anonymous');
        sessionExpiredRef.current?.();
      },

      // Used by httpClient for every non-GET request that is not anonymous.
      getCsrfToken: () => csrfTokenRef.current,
    };

    return createHttpClient({
      baseUrl: apiUrl,
      auth,
      // Still 'include' so the CSRF cookie round-trips; the refresh token no
      // longer depends on it.
      credentials: 'include',
      defaultHeaders: { 'x-client-release': release },
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [apiUrl, release]);

  /**
   * Ensures a CSRF token exists and returns it as a header pair.
   *
   * Login, refresh and logout are sent with `anonymous: true` — otherwise
   * httpClient would attach a bearer token they do not need and, worse, would
   * run its refresh-on-401 logic against the refresh route itself. Anonymous
   * requests skip httpClient's automatic CSRF header, so these three set it by
   * hand.
   */
  const csrfHeaders = useCallback(
    async (client: HttpClient = http): Promise<Record<string, string>> => {
      if (!csrfTokenRef.current) {
        try {
          const { csrfToken } = (await client.get('/auth/csrf')) as { csrfToken: string };
          csrfTokenRef.current = csrfToken;
        } catch {
          // Let the request proceed and fail on its own terms; a 403 with a
          // clear message beats a silent no-op here.
          return {};
        }
      }
      return { [HEADERS.csrfToken]: csrfTokenRef.current as string };
    },
    [http],
  );

  // -------------------------------------------------------------------------
  // Room to node resolution (F1)
  // -------------------------------------------------------------------------

  // Lives here rather than in the classroom route so its cache survives leaving
  // and rejoining a lesson.
  const nodeResolver = useMemo(() => createNodeResolver({ http }), [http]);

  // -------------------------------------------------------------------------
  // Chat socket (F6)
  // -------------------------------------------------------------------------

  const [chatSocket, setChatSocket] = useState<SocketClient | null>(null);

  useEffect(() => {
    if (status !== 'authenticated') return undefined;

    const socket = createSocketClient({
      namespace: '/chat',
      getAccessToken: () => accessTokenRef.current,
    });

    let cancelled = false;
    void socket
      .connect(wsUrl, {})
      .then(() => {
        if (!cancelled) setChatSocket(socket);
      })
      .catch(() => {
        // A chat socket that will not open must not take the app down with it.
        // Everything else keeps working; the dock shows itself as offline.
      });

    return () => {
      cancelled = true;
      socket.disconnect();
      setChatSocket(null);
    };
  }, [status, wsUrl]);

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  /** Takes the tokens of any successful sign-in: password, second step or passkey. */
  const adopt = useCallback((result: TokenResponse): Session => {
    accessTokenRef.current = result.accessToken;
    refreshTokenRef.current = result.refreshToken ?? null;
    sessionIdRef.current = result.sessionId ?? null;

    setSession(result.user);
    setStatus('authenticated');
    return result.user;
  }, []);

  const signIn = useCallback<CoreContextValue['signIn']>(
    async (credentials) => {
      const headers = await csrfHeaders();

      const result = (await http.post(
        '/auth/login',
        {
          ...credentials,
          device: { platform: 'web' },
          // The whole reason this works behind the tunnel: the token comes back
          // in the body instead of in a cookie the browser may silently drop.
          wantsRefreshToken: true,
        },
        { anonymous: true, headers },
      )) as TokenResponse | ChallengeResponse;

      if ('secondFactorRequired' in result && result.secondFactorRequired) {
        throw new SecondFactorRequired(result);
      }
      return adopt(result as TokenResponse);
    },
    [http, csrfHeaders, adopt],
  );

  const completeSignIn = useCallback<CoreContextValue['completeSignIn']>(
    async ({ challengeId, code }) => {
      const headers = await csrfHeaders();
      const result = (await http.post(
        '/auth/login/second-factor',
        { challengeId, code, device: { platform: 'web' }, wantsRefreshToken: true },
        // Not retried: a code is single-use, a replay would be refused anyway.
        { anonymous: true, headers, retry: { attempts: 1 } },
      )) as TokenResponse;
      return adopt(result);
    },
    [http, csrfHeaders, adopt],
  );

  const passkeyOptions = useCallback<CoreContextValue['passkeyOptions']>(
    async ({ challengeId = null } = {}) => {
      const headers = await csrfHeaders();
      return (await http.post(
        challengeId ? '/auth/login/second-factor/passkey/options' : '/auth/passkey/options',
        challengeId ? { challengeId } : {},
        { anonymous: true, headers, retry: { attempts: 1 } },
      )) as PasskeyOptions;
    },
    [http, csrfHeaders],
  );

  const signInWithPasskey = useCallback<CoreContextValue['signInWithPasskey']>(
    async ({ challengeId = null, optionsId, response }) => {
      const headers = await csrfHeaders();
      const body = { optionsId, response, device: { platform: 'web' }, wantsRefreshToken: true };
      const result = (await http.post(
        challengeId ? '/auth/login/second-factor/passkey' : '/auth/passkey',
        challengeId ? { ...body, challengeId } : body,
        { anonymous: true, headers, retry: { attempts: 1 } },
      )) as TokenResponse;
      return adopt(result);
    },
    [http, csrfHeaders, adopt],
  );

  const signOut = useCallback<CoreContextValue['signOut']>(async () => {
    try {
      const headers = await csrfHeaders();
      await http.post(
        '/auth/logout',
        { refreshToken: refreshTokenRef.current, sessionId: sessionIdRef.current },
        { headers },
      );
    } catch (cause) {
      // A logout that fails server-side still has to clear the client, or the
      // user stays signed in on a machine they just tried to leave.
      if (!ApiError.is(cause)) throw cause;
    } finally {
      accessTokenRef.current = null;
      refreshTokenRef.current = null;
      sessionIdRef.current = null;
      // The old token is bound to the session that just ended.
      csrfTokenRef.current = null;
      nodeResolver.clear();
      setSession(null);
      setStatus('anonymous');
    }
  }, [http, csrfHeaders, nodeResolver]);

  /**
   * Stable across renders, deliberately.
   *
   * An inline arrow here is a new function every time the context value is
   * rebuilt — which is on every session, status and socket change. Anything
   * memoised against it downstream rebuilds too, and useSfuClient memoises the
   * whole SfuClient against exactly this. The result was a client torn down and
   * recreated on unrelated state changes, which the server sees as the peer
   * leaving and a new one arriving.
   *
   * It reads a ref, so it never needs to change.
   */
  const getAccessToken = useCallback(() => accessTokenRef.current, []);

  const value = useMemo<CoreContextValue>(
    () => ({
      http,
      nodeResolver,
      chatSocket,
      session,
      status,
      release,
      apiUrl,
      wsUrl,
      getAccessToken,
      signIn,
      completeSignIn,
      passkeyOptions,
      signInWithPasskey,
      signOut,
    }),
    [
      http,
      nodeResolver,
      chatSocket,
      session,
      status,
      release,
      apiUrl,
      wsUrl,
      getAccessToken,
      signIn,
      completeSignIn,
      passkeyOptions,
      signInWithPasskey,
      signOut,
    ],
  );

  return <CoreContext.Provider value={value}>{children}</CoreContext.Provider>;
}

export default CoreProvider;
