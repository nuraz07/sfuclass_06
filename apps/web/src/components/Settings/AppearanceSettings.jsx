import { Choice, Section, Toggle } from './fields.jsx';

/** Appearance: text size and motion. Applied at once and on every device you sign in on. */
export default function AppearanceSettings({ preferences, savePreferences }) {
  const appearance = preferences.appearance;
  return (
    <>
      <Section title="Reading">
        <Choice
          id="font-size"
          label="Text size"
          value={appearance.fontScale}
          options={[
            { value: 'small', title: 'Small' },
            { value: 'default', title: 'Default' },
            { value: 'large', title: 'Large' },
            { value: 'x-large', title: 'Extra large' },
          ]}
          onChange={(value) => savePreferences('appearance', { fontScale: value }, 'Text size')}
        />
        <p className="st-sample">The quick brown fox jumps over the lazy dog — this is how text reads now.</p>
      </Section>

      <Section title="Motion">
        <Toggle
          id="motion"
          label="Reduce motion"
          hint="Turns off animations and transitions, including flying reactions in a lesson."
          checked={appearance.reduceMotion}
          onChange={(value) => savePreferences('appearance', { reduceMotion: value }, 'Reduce motion')}
        />
      </Section>
    </>
  );
}
