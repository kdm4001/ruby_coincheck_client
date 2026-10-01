import test from 'node:test';
import assert from 'node:assert/strict';
import { OrderBook, parseTrades, mergeTrades } from '../../gui/public/market.js';

test('buffers updates until snapshot, normalizes prices and deletes zero sizes', () => {
  const book = new OrderBook();
  book.delta({ bids: [['100.0', '0'], ['99', '3']], asks: [['102', '2']] });
  book.snapshot({ bids: [['100', '1'], ['98', '4']], asks: [['103', '1']] });
  assert.deepEqual(book.rows('bids'), [[99, '3'], [98, '4']]);
  assert.deepEqual(book.rows('asks'), [[102, '2'], [103, '1']]);
  book.delta({ bids: [['99.0', '5']] });
  assert.deepEqual(book.rows('bids', 1), [[99, '5']]);
});

test('resets obsolete levels on pair switches and reconnects', () => {
  const book = new OrderBook();
  book.snapshot({ bids: [['100', '1']], asks: [['101', '2']] });
  book.reset();
  assert.equal(book.ready, false);
  assert.deepEqual(book.rows('asks'), []);
  book.snapshot({ asks: [['200', '3']] });
  assert.deepEqual(book.rows('bids'), []);
});

test('parses batched trades, isolates the selected pair and deduplicates REST/WS overlap', () => {
  const trades = parseTrades([
    ['1663318663', '2357062', 'btc_jpy', '2820896.0', '5.0', 'sell'],
    ['1663318664', '2357063', 'eth_jpy', '200000', '1.0', 'buy'],
    ['1663318665', '2357064', 'btc_jpy', '2820900.0', '0.2', 'buy']
  ], 'btc_jpy');
  assert.equal(trades.length, 2);
  const merged = mergeTrades([trades[0]], trades);
  assert.deepEqual(merged.map(item => item.id), ['2357064', '2357062']);
  assert.deepEqual(parseTrades(['btc_jpy', { bids: [] }], 'btc_jpy'), []);
});
