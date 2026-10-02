import { fileMeta, iconFor } from '../Files/filesModel.js';
import { fileHref } from '../../lib/files.js';
import { formatDate } from '../../lib/preferences.js';
import { usedInLabel } from './libraryModel.js';

/**
 * One file in the library  (Media)
 *
 * A tile in the grid, a row in the list. Pictures show themselves (lazily,
 * through the file's signed link); everything else shows its kind. Selecting
 * opens the preview panel; the whole item is one button, so it works with the
 * keyboard as well.
 */
export default function LibraryItem({ file, view, selected, onSelect }) {
  const thumb = file.kind === 'image' && file.openUrl ? fileHref(file.openUrl) : null;
  const usedIn = file.usedIn ?? 0;

  return (
    <li className={`lb-item lb-item--${view}${selected ? ' is-selected' : ''}`}>
      <button type="button" className="lb-item__button" aria-pressed={selected} onClick={() => onSelect(file.fileId)}>
        <span className={`lb-item__thumb lb-kind--${file.kind}`} aria-hidden="true">
          {thumb ? <img src={thumb} alt="" loading="lazy" decoding="async" draggable="false" /> : <span className="lb-item__icon">{iconFor(file.kind)}</span>}
          {view === 'grid' ? <span className="lb-item__ext">{file.ext.toUpperCase()}</span> : null}
        </span>
        <span className="lb-item__text">
          <span className="lb-item__name" title={file.name}>
            {file.name}
          </span>
          <span className="lb-item__meta">
            {fileMeta(file)}
            {view === 'list' && file.createdAt ? ` · ${formatDate(file.createdAt)}` : ''}
          </span>
        </span>
        {usedIn > 0 ? (
          <span className="lb-item__used" title={usedInLabel(usedIn)}>
            <span aria-hidden="true">◎</span> {usedIn}
            <span className="lb-sr"> {usedIn === 1 ? 'space' : 'spaces'}</span>
          </span>
        ) : null}
      </button>
    </li>
  );
}
