import test from 'node:test';
import assert from 'node:assert/strict';
import {LOGIN_MESSAGES, LOGIN_MESSAGE_START_DATE, dailyLoginMessage} from '../lib/login-messages.mjs';
const messageAt = iso => dailyLoginMessage(new Date(iso));
test('approved collection has 25 unique messages and starts production on message 25',()=>{
 assert.equal(LOGIN_MESSAGES.length,25);assert.equal(new Set(LOGIN_MESSAGES).size,25);
 assert.equal(LOGIN_MESSAGE_START_DATE,'2026-11-05');
 assert.equal(messageAt('2026-11-05T05:00:00Z'),'No locks were harmed in the making of this dashboard.');
 assert.equal(messageAt('2026-11-06T04:59:59.999Z'),LOGIN_MESSAGES[24]);
 assert.equal(messageAt('2026-11-06T05:00:00Z'),LOGIN_MESSAGES[0]);
});
test('advances through every approved message and wraps after 24 back to 25',()=>{
 for(let day=0;day<100;day++){
  const date=new Date(Date.UTC(2026,10,5+day,17));
  assert.equal(dailyLoginMessage(date),LOGIN_MESSAGES[(day+24)%25]);
 }
 assert.equal(messageAt('2026-11-29T17:00:00Z'),LOGIN_MESSAGES[23]);
 assert.equal(messageAt('2026-11-30T17:00:00Z'),LOGIN_MESSAGES[24]);
 assert.equal(messageAt('2026-12-01T17:00:00Z'),LOGIN_MESSAGES[0]);
});
test('all instants within one New York day agree, across UTC dates and visitor offsets',()=>{
 for(const time of ['2026-11-06T05:00:00Z','2026-11-06T23:59:59Z','2026-11-07T04:59:59Z','2026-11-07T13:59:59+09:00'])assert.equal(messageAt(time),LOGIN_MESSAGES[0]);
});
test('calendar calculation advances once across spring-forward and fall-back days',()=>{
 const at=(iso,anchor)=>dailyLoginMessage(new Date(iso),anchor);
 assert.equal(at('2027-03-14T05:00:00Z','2027-03-13'),LOGIN_MESSAGES[0]);
 assert.equal(at('2027-03-15T03:59:59Z','2027-03-13'),LOGIN_MESSAGES[0]);
 assert.equal(at('2027-03-15T04:00:00Z','2027-03-13'),LOGIN_MESSAGES[1]);
 assert.equal(at('2027-11-07T04:00:00Z','2027-11-06'),LOGIN_MESSAGES[0]);
 assert.equal(at('2027-11-08T04:59:59Z','2027-11-06'),LOGIN_MESSAGES[0]);
 assert.equal(at('2027-11-08T05:00:00Z','2027-11-06'),LOGIN_MESSAGES[1]);
});
