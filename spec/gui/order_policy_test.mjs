import test from 'node:test';
import assert from 'node:assert/strict';
import { prepareOrder, resultText } from '../../gui/public/order-policy.js';

const order = { pair: 'btc_jpy', order_type: 'buy', rate: '10000000', amount: '0.001', stop_loss_rate: '9000000', time_in_force: 'post_only' };
const now = Date.parse('2026-10-04T00:00:00Z');

test('normal orders retain existing options; IOC strips incompatible options', () => {
  assert.deepEqual(prepareOrder(order, 'normal').body, order);
  const ioc = prepareOrder(order, 'immediate_or_cancel');
  assert.equal(ioc.path, '/api/orders/immediate_or_cancel');
  assert.deepEqual(ioc.body, { pair: 'btc_jpy', order_type: 'buy', rate: '10000000', amount: '0.001' });
  assert.equal(order.time_in_force, 'post_only');
});

test('GTD converts the selected deadline to an absolute timestamp', () => {
  const prepared = prepareOrder(order, 'good_til_date', '2026-10-04T10:00:00+09:00', now);
  assert.equal(prepared.path, '/api/orders/good_til_date');
  assert.equal(prepared.body.expires_at, '2026-10-04T01:00:00.000Z');
  assert.equal(prepared.body.stop_loss_rate, undefined);
});

test('invalid, elapsed and excessive deadlines are rejected, including after confirmation', () => {
  for (const expiry of ['', 'invalid', '2026-10-03T00:00:00Z', '2026-10-12T00:00:00Z']) {
    assert.throws(() => prepareOrder(order, 'good_til_date', expiry, now));
  }
  assert.throws(() => prepareOrder(order, 'good_til_date', '2026-10-04T01:00:00Z', now + 3600000));
});

test('managed policies cannot be submitted as market orders', () => {
  for (const policy of ['immediate_or_cancel', 'good_til_date']) {
    assert.throws(() => prepareOrder({ ...order, order_type: 'market_sell' }, policy));
  }
  assert.throws(() => prepareOrder(order, 'other'));
});

test('unknown quantities are displayed as unknown, while real zero is retained', () => {
  assert.match(resultText({ status: 'unknown', executed_amount: null }), /約定 不明/);
  assert.match(resultText({ status: 'canceled', executed_amount: '0.0', remaining_amount: '0.0', canceled_amount: '0.001' }), /約定 0.0/);
});
