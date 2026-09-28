import { useId, useState } from 'react';

/**
 * Questions people ask before signing up  (Landing)
 * An accordion: one answer open at a time, animated open and closed.
 */

export const QUESTIONS = [
  {
    q: 'Do I or my learners need to install anything?',
    a: 'No. Classroom runs in current versions of Chrome, Edge, Firefox and Safari, on computers, tablets and phones. Learners open the link and are in the lobby.',
  },
  {
    q: 'How do the doors work?',
    a: 'Every room has a start and an end. The doors open 3 to 10 minutes before the start — you choose. Until then the link shows a countdown and a camera check. You and your co-hosts can come in 30 minutes early to prepare.',
  },
  {
    q: 'What happens when a room is full?',
    a: 'People can join a waiting list from the lobby. When someone leaves, the next person is told at once and the seat is held for them for two minutes. Hosts and co-hosts always get in.',
  },
  {
    q: 'Can I decide who comes in?',
    a: 'Yes. A room can be for invited people only, or for anyone in your organisation with the link. With “let people in myself”, everyone knocks in the lobby and you admit them one by one or all at once.',
  },
  {
    q: 'Who can send me private messages?',
    a: 'You decide: anyone in your organisation, only people you share a course, space or lesson with, or nobody. Teachers can always reach their learners. A block stops everyone, teachers included.',
  },
  {
    q: 'How is my account protected?',
    a: 'With two-step sign-in (an authenticator app or a passkey), a list of every device that is signed in, a history of sign-ins and changes, and an email whenever something important changes.',
  },
  {
    q: 'Can I take my data with me, or delete my account?',
    a: 'Yes. Settings has a download of everything we keep about you, as one file. Deleting your account gives you 14 days to change your mind; after that your personal data is removed.',
  },
  {
    q: 'Can people outside my organisation join a lesson?',
    a: 'Anyone with the link reaches the lobby and can create an account there. Whether they may enter depends on the room: invited people only, anyone in the organisation with the link, and whether you let people in yourself.',
  },
];

export default function Faq() {
  const [open, setOpen] = useState(0);
  const base = useId();

  return (
    <div className="lp-faq">
      {QUESTIONS.map((entry, index) => {
        const expanded = open === index;
        return (
          <div key={entry.q} className={expanded ? 'lp-faq__item is-open' : 'lp-faq__item'}>
            <h3 className="lp-faq__q">
              <button
                type="button"
                aria-expanded={expanded}
                aria-controls={`${base}-${index}`}
                onClick={() => setOpen(expanded ? -1 : index)}
              >
                {entry.q}
                <span className="lp-faq__icon" aria-hidden="true" />
              </button>
            </h3>
            <div className="lp-faq__a" id={`${base}-${index}`} role="region">
              <div>
                <p>{entry.a}</p>
              </div>
            </div>
          </div>
        );
      })}
    </div>
  );
}
