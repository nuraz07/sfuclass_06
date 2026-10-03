import { useCallback, useEffect, useMemo, useState } from 'react';
import { useLocation, useParams } from 'react-router-dom';
import { createHubApi, useCore } from '@classroom/core-client';

import SpaceRail from '../components/Hub/SpaceRail.jsx';
import HubHome from '../components/Hub/HubHome.jsx';
import HubQuestions from '../components/Hub/HubQuestions.jsx';
import HubDiscover from '../components/Hub/HubDiscover.jsx';
import NewSpaceForm from '../components/Hub/NewSpaceForm.jsx';
import SpaceView from '../components/Hub/SpaceView.jsx';
import HubThread from '../components/Hub/HubThread.jsx';
import HubPartners from '../components/Hub/HubPartners.jsx';
import { tabFrom } from '../components/Hub/hubModel.js';
import { onUserEvent } from '../lib/userEvents.js';
import '../components/Hub/hub.css';

/**
 * Community  (Community, part 1)
 *
 *   /community                    Home: what is new in your spaces
 *   /community?tab=questions      Questions across all your spaces
 *   /community?tab=discover       Spaces you are not in yet
 *   /community?tab=new            Create a space
 *   /community?tab=partners       Study partners                      (part 3)
 *   /community/spaces/:spaceId    One space (?tab=members|about|requests|reports)
 *   /community/threads/:threadId  One thread
 *
 * The same three routes main.jsx already had; the rest is query strings, so
 * nothing outside this page changes. Data comes from /hub (hubApi).
 */

const TEACHING = new Set(['teacher', 'owner', 'admin']);

export default function CommunityPage() {
  const core = useCore();
  const { http, session } = core;
  const hub = useMemo(() => createHubApi(http), [http]);
  const { spaceId, threadId } = useParams();
  const location = useLocation();

  const [home, setHome] = useState(null);
  const [scheduled, setScheduled] = useState([]);
  const [partnerRequests, setPartnerRequests] = useState(0);
  const [version, setVersion] = useState(0);
  const bump = useCallback(() => setVersion((value) => value + 1), []);

  useEffect(() => {
    const controller = new AbortController();
    hub
      .home(controller.signal)
      .then(setHome)
      .catch(() => !controller.signal.aborted && setHome({ spaces: [], recent: [], myThreads: [], openQuestions: 0 }));
    hub.scheduled(controller.signal).then((result) => setScheduled(result.items)).catch(() => undefined);
    hub.partners(controller.signal).then((result) => setPartnerRequests(result.incoming.length)).catch(() => undefined);
    return () => controller.abort();
  }, [hub, version]);

  // A reply, an answer or an admission arrives as a notification: refresh.
  useEffect(
    () =>
      onUserEvent(core, 'notification:new', (payload) => {
        const kind = String(payload?.notification?.kind ?? '');
        if (kind.startsWith('thread.') || kind.startsWith('space.') || kind.startsWith('study.')) bump();
      }),
    [core, bump],
  );

  // Back from another tab or window: catch up.
  useEffect(() => {
    const onFocus = () => bump();
    window.addEventListener('focus', onFocus);
    return () => window.removeEventListener('focus', onFocus);
  }, [bump]);

  const tab = tabFrom(location.search, ['home', 'questions', 'discover', 'new', 'partners'], 'home');
  const canCreateClass = TEACHING.has(session?.role);

  let main;
  if (threadId) main = <HubThread key={threadId} hub={hub} threadId={threadId} bump={bump} />;
  else if (spaceId) main = <SpaceView key={spaceId} hub={hub} spaceId={spaceId} version={version} bump={bump} />;
  else if (tab === 'questions') main = <HubQuestions hub={hub} />;
  else if (tab === 'discover') main = <HubDiscover hub={hub} onChanged={bump} />;
  else if (tab === 'new') main = <NewSpaceForm hub={hub} canCreateClass={canCreateClass} onCreated={bump} />;
  else if (tab === 'partners') main = <HubPartners hub={hub} />;
  else main = <HubHome home={home} displayName={session?.displayName} hub={hub} scheduled={scheduled} onChanged={bump} />;

  return (
    <section className="page hb">
      <SpaceRail spaces={home?.spaces ?? null} openQuestions={home?.openQuestions ?? 0} partnerRequests={partnerRequests} />
      <div className="hb-main" key={`${location.pathname}${location.search}`}>
        {main}
      </div>
    </section>
  );
}
