// This is the first production release date for this rotation, in America/New_York.
// Keep the anchor unchanged on later deployments so the sequence continues.
export const LOGIN_MESSAGE_START_DATE = '2026-11-05';
export const LOGIN_MESSAGE_TIME_ZONE = 'America/New_York';
export const LOGIN_MESSAGES = Object.freeze([
  'May your locks be easy to find and your combinations correct.',
  'No scavenger hunt required. We checked.',
  'Lock, stock, and organized.',
  'A place for every lock. Even that one.',
  'Less hunting. More locking.',
  'Because guessing combinations is not a strategy.',
  'The only drama should be on the security cameras.',
  'For the love of locks, stay organized.',
  'Some mysteries are better left unsolved. Not lock locations.',
  'Lock management. Now with fewer headaches.',
  'Keep calm and check the serial number.',
  'Your lock inventory has entered its organized era.',
  'Putting the "where\'s that lock?" question to rest.',
  'A little less chaos behind the gates.',
  'All these locks, and not one escape room.',
  'Making misplaced locks slightly less legendary.',
  'Who knew locks needed this much supervision?',
  'Because "I swear it was right here" gets old.',
  'We\'re keeping tabs on the things that keep things locked.',
  'Organized locks. Unorganized desk? No judgment.',
  'There\'s a combination for that.',
  'Lock it. Log it. Love it. Maybe just log it.',
  'Your locks called. They wanted better management.',
  'The search party has officially been canceled.',
  'No locks were harmed in the making of this dashboard.',
]);
const calendar = new Intl.DateTimeFormat('en-US', {
  timeZone: LOGIN_MESSAGE_TIME_ZONE, year: 'numeric', month: '2-digit', day: '2-digit',
});
function dayNumber(date) {
  const parts = Object.fromEntries(calendar.formatToParts(date).map(p => [p.type, p.value]));
  // Subtract calendar dates, not 24-hour intervals: DST days can be 23 or 25 hours.
  return Date.UTC(Number(parts.year), Number(parts.month) - 1, Number(parts.day)) / 86400000;
}
export function dailyLoginMessage(now = new Date(), startDate = LOGIN_MESSAGE_START_DATE) {
  const [year, month, day] = startDate.split('-').map(Number);
  const elapsedDays = dayNumber(now) - Date.UTC(year, month - 1, day) / 86400000;
  const index = ((elapsedDays + LOGIN_MESSAGES.length - 1) % LOGIN_MESSAGES.length + LOGIN_MESSAGES.length) % LOGIN_MESSAGES.length;
  return LOGIN_MESSAGES[index];
}
