import { hueOf, initials } from './messengerModel.js';

/** A round picture, or initials on a colour that is always the same for the same person. */
export default function Avatar({ name, url = null, seed, size = 40, className = '' }) {
  const style = { width: size, height: size, fontSize: Math.round(size * 0.38), '--mx-hue': hueOf(seed ?? name) };
  return (
    <span className={`mx-avatar ${className}`.trim()} style={style} aria-hidden="true">
      {url ? <img src={url} alt="" /> : initials(name)}
    </span>
  );
}
