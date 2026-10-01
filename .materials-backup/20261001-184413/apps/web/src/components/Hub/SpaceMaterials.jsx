import { useCallback, useEffect, useState } from 'react';
import { normalizeUrl } from './hubModel.js';

/**
 * Materials  (Community, part 2)
 *
 * The links a space keeps at hand: worksheets, videos, reading lists,
 * websites. Pinned ones first. Moderators add and pin them; links always
 * open in a new tab, and only web addresses are accepted.
 */
export default function SpaceMaterials({ hub, space }) {
  const [data, setData] = useState(null);
  const [adding, setAdding] = useState(false);
  const [form, setForm] = useState({ title: '', url: '', note: '', pinned: false });
  const [error, setError] = useState(null);

  const load = useCallback(async () => {
    try {
      setData(await hub.materials(space.spaceId));
    } catch {
      setData({ items: [], canCurate: false });
    }
  }, [hub, space.spaceId]);

  useEffect(() => {
    load();
  }, [load]);

  const url = normalizeUrl(form.url);

  const add = async (event) => {
    event.preventDefault();
    if (!form.title.trim() || !url) return;
    setError(null);
    try {
      await hub.addMaterial(space.spaceId, { title: form.title.trim(), url, note: form.note.trim() || null, pinned: form.pinned });
      setForm({ title: '', url: '', note: '', pinned: false });
      setAdding(false);
      await load();
    } catch (cause) {
      setError(cause?.detail ?? 'Not added.');
    }
  };

  const act = async (fn) => {
    await fn().catch(() => undefined);
    await load();
  };

  return (
    <div>
      {data?.canCurate ? (
        adding ? (
          <form className="hb-composer" onSubmit={add}>
            <div className="hb-row2 hb-row2--even">
              <input className="hb-input" placeholder="Title, e.g. Worksheet 4" maxLength={120} value={form.title} onChange={(event) => setForm({ ...form, title: event.target.value })} autoFocus />
              <input className="hb-input" placeholder="Link, e.g. example.com/worksheet.pdf" maxLength={2000} value={form.url} onChange={(event) => setForm({ ...form, url: event.target.value })} aria-invalid={Boolean(form.url && !url)} />
            </div>
            {form.url && !url ? <p className="hb-error">That is not a web address.</p> : null}
            <input className="hb-input" placeholder="A short note (optional)" maxLength={300} value={form.note} onChange={(event) => setForm({ ...form, note: event.target.value })} />
            <label className="hb-check">
              <input type="checkbox" checked={form.pinned} onChange={(event) => setForm({ ...form, pinned: event.target.checked })} />
              <span className="hb-label">Pin to the top</span>
            </label>
            {error ? <p className="hb-error">{error}</p> : null}
            <div className="hb-inline">
              <button type="submit" className="btn btn--primary" disabled={!form.title.trim() || !url}>
                Add
              </button>
              <button type="button" className="hb-link" onClick={() => setAdding(false)}>
                Cancel
              </button>
            </div>
          </form>
        ) : (
          <div className="hb-toolbar">
            <span className="hb-muted">Links everyone in the space can open.</span>
            <button type="button" className="btn" onClick={() => setAdding(true)}>
              Add material
            </button>
          </div>
        )
      ) : null}
      {data === null ? <p className="hb-muted">Loading…</p> : null}
      {data?.items.length === 0 ? <p className="hb-muted">No materials yet.</p> : null}
      <ul className="hb-materials">
        {(data?.items ?? []).map((material) => (
          <li key={material.materialId} className={material.pinned ? 'hb-material is-pinned' : 'hb-material'}>
            <a className="hb-material__link" href={material.url} target="_blank" rel="noopener noreferrer">
              <span className="hb-material__icon" aria-hidden="true">
                {material.pinned ? '📌' : '🔗'}
              </span>
              <span className="hb-material__text">
                <span className="hb-material__title">{material.title}</span>
                <span className="hb-muted">
                  {material.host}
                  {material.note ? `: ${material.note}` : ''}
                </span>
              </span>
            </a>
            {data.canCurate ? (
              <span className="hb-inline">
                <button type="button" className="hb-link" onClick={() => act(() => hub.pinMaterial(material.materialId, !material.pinned))}>
                  {material.pinned ? 'Unpin' : 'Pin'}
                </button>
                <button type="button" className="hb-link hb-link--danger" onClick={() => window.confirm('Remove this material?') && act(() => hub.removeMaterial(material.materialId))}>
                  Remove
                </button>
              </span>
            ) : null}
          </li>
        ))}
      </ul>
    </div>
  );
}
