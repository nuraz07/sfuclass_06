import { useState } from 'react';

/**
 * Recovery codes, shown exactly once  (Settings, Phase C)
 *
 * The server keeps only hashes, so this is the one moment they can be saved.
 * Copy, download and print; the list stays until "I saved them" is pressed.
 */
export default function RecoveryCodes({ codes, onDone }) {
  const [copied, setCopied] = useState(false);
  const text = `Classroom recovery codes\nEach code works once.\n\n${codes.join('\n')}\n`;

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  };

  const download = () => {
    const url = URL.createObjectURL(new Blob([text], { type: 'text/plain' }));
    const link = document.createElement('a');
    link.href = url;
    link.download = 'classroom-recovery-codes.txt';
    link.click();
    URL.revokeObjectURL(url);
  };

  return (
    <div className="st-codes" role="region" aria-label="Recovery codes">
      <p className="st-label">Save these recovery codes now</p>
      <p className="st-hint">
        If you lose your phone or your passkeys, each code signs you in once. They are not shown again.
      </p>
      <ol className="st-codes__list">
        {codes.map((code) => (
          <li key={code}>
            <code>{code}</code>
          </li>
        ))}
      </ol>
      <div className="st-inline">
        <button type="button" className="btn btn--tiny" onClick={copy}>
          {copied ? 'Copied' : 'Copy'}
        </button>
        <button type="button" className="btn btn--tiny" onClick={download}>
          Download
        </button>
        <button type="button" className="btn" onClick={onDone}>
          I saved them
        </button>
      </div>
    </div>
  );
}
