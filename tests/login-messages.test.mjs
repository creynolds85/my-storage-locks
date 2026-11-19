import test from 'node:test';
import assert from 'node:assert/strict';
import {dailyLoginMessage} from '../lib/login-messages.mjs';

test('manager headline stays permanent across prior override dates, midnight and future dates',()=>{
 const expected='no locks were harmed during the making of this dashboard';
 assert.equal(dailyLoginMessage(),expected);
 for(const iso of ['2026-11-06T05:00:00Z','2026-11-19T04:59:59Z','2026-11-19T05:00:00Z','2026-12-01T17:00:00Z','2030-07-01T00:00:00Z'])assert.equal(dailyLoginMessage(new Date(iso)),expected);
});
