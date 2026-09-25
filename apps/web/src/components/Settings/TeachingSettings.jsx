import { Section, Toggle } from './fields.jsx';

/**
 * Teaching: how lessons you open start. Applied by the server when a lesson
 * is created with you as its host; a lesson that is already running keeps its
 * settings (change those in the lesson itself).
 */
export default function TeachingSettings({ preferences, savePreferences }) {
  const defaults = preferences.roomDefaults;
  return (
    <Section title="Your lessons start with" hint="Applies to lessons you open from now on.">
      <Toggle
        id="reactions"
        label="Emoji reactions on"
        hint="Off: only you can react until you switch reactions on in the lesson."
        checked={defaults.reactionsEnabled}
        onChange={(value) => savePreferences('roomDefaults', { reactionsEnabled: value }, 'Reactions default')}
      />
      <Toggle
        id="join-muted"
        label="Learners join with their microphone off"
        hint="They can unmute themselves. Helpful from about ten participants on."
        checked={defaults.learnersJoinMuted}
        onChange={(value) => savePreferences('roomDefaults', { learnersJoinMuted: value }, 'Join muted default')}
      />
    </Section>
  );
}
