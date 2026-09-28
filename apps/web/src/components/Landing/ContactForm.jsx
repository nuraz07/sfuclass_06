import { useMemo, useState } from 'react';
import { useCore } from '@classroom/core-client';
import { CONTACT_TOPICS, validateContact } from './landingModel.js';

/**
 * Contact  (Landing)
 *
 * Sent to POST /public/contact, which stores the message and, when
 * CONTACT_EMAIL is set on the server, forwards it by email. A hidden field
 * catches form-filling robots; people never see it.
 */
export default function ContactForm() {
  const { http } = useCore();
  const [form, setForm] = useState({ name: '', email: '', topic: 'school', message: '', website: '' });
  const [touched, setTouched] = useState(false);
  const [state, setState] = useState('idle'); // idle · sending · sent · error
  const [error, setError] = useState(null);

  const errors = useMemo(() => validateContact(form), [form]);
  const shown = touched ? errors : {};
  const set = (field) => (event) => setForm((current) => ({ ...current, [field]: event.target.value }));

  const submit = async (event) => {
    event.preventDefault();
    setTouched(true);
    if (Object.keys(errors).length > 0) return;
    setState('sending');
    setError(null);
    try {
      await http.post(
        '/public/contact',
        { ...form, name: form.name.trim(), email: form.email.trim(), message: form.message.trim() },
        { anonymous: true, retry: { attempts: 1 } },
      );
      setState('sent');
    } catch (cause) {
      setState('error');
      setError(cause?.detail ?? 'Your message was not sent. Check your connection and try again.');
    }
  };

  if (state === 'sent') {
    return (
      <div className="lp-contact__done" role="status">
        <p className="lp-contact__done-title">Thank you, {form.name.split(' ')[0]}.</p>
        <p>Your message is with us. We will answer at {form.email}.</p>
        <button
          type="button"
          className="lp-button lp-button--ghost"
          onClick={() => {
            setForm({ name: form.name, email: form.email, topic: 'question', message: '', website: '' });
            setTouched(false);
            setState('idle');
          }}
        >
          Write another message
        </button>
      </div>
    );
  }

  return (
    <form className="lp-contact__form" onSubmit={submit} noValidate>
      <div className="lp-contact__row">
        <label className="lp-field">
          <span className="lp-field__label">Name</span>
          <input className="lp-input" autoComplete="name" value={form.name} onChange={set('name')} maxLength={100} aria-invalid={Boolean(shown.name)} />
          {shown.name ? <span className="lp-field__error">{shown.name}</span> : null}
        </label>
        <label className="lp-field">
          <span className="lp-field__label">Email</span>
          <input className="lp-input" type="email" autoComplete="email" value={form.email} onChange={set('email')} maxLength={254} aria-invalid={Boolean(shown.email)} />
          {shown.email ? <span className="lp-field__error">{shown.email}</span> : null}
        </label>
      </div>
      <label className="lp-field">
        <span className="lp-field__label">What is it about?</span>
        <select className="lp-input" value={form.topic} onChange={set('topic')}>
          {CONTACT_TOPICS.map((topic) => (
            <option key={topic.value} value={topic.value}>
              {topic.label}
            </option>
          ))}
        </select>
      </label>
      <label className="lp-field">
        <span className="lp-field__label">Message</span>
        <textarea className="lp-input" rows={5} value={form.message} onChange={set('message')} maxLength={4000} aria-invalid={Boolean(shown.message)} />
        {shown.message ? <span className="lp-field__error">{shown.message}</span> : null}
      </label>
      {/* Robots fill every field; people never see this one. */}
      <label className="lp-honeypot" aria-hidden="true">
        Website
        <input tabIndex={-1} autoComplete="off" value={form.website} onChange={set('website')} />
      </label>
      {error ? (
        <p className="lp-field__error" role="alert">
          {error}
        </p>
      ) : null}
      <button type="submit" className="lp-button lp-button--dark" disabled={state === 'sending'}>
        {state === 'sending' ? 'Sending…' : 'Send message'}
      </button>
    </form>
  );
}
