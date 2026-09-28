import { useInView } from './motion.js';

/**
 * Content that settles into place the first time it is scrolled into view.
 * `delay` (ms) staggers siblings; `as` picks the element.
 */
export default function Reveal({ as: Tag = 'div', delay = 0, className = '', children, ...rest }) {
  const [ref, inView] = useInView();
  return (
    <Tag
      ref={ref}
      className={`lp-reveal${inView ? ' is-in' : ''}${className ? ` ${className}` : ''}`}
      style={{ '--lp-delay': `${delay}ms` }}
      {...rest}
    >
      {children}
    </Tag>
  );
}
