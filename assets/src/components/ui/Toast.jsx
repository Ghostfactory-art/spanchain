// GF-792a — bottom toast notification; visible while `message` is non-empty.
export default function Toast({ message }) {
  return <div className={'toast' + (message ? ' show' : '')}>{message}</div>;
}
