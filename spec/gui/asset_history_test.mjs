import test from 'node:test';
import assert from 'node:assert/strict';
import { historyGeometry } from '../../gui/public/asset-history.js';

test('asset chart uses elapsed time and leaves a break across missing samples', () => {
  const geometry = historyGeometry([
    { at: 1000, total_jpy: '100' },
    { at: 1300, total_jpy: '200' },
    { at: 4900, total_jpy: '150' }
  ]);
  assert.equal(geometry.change, 50);
  assert.equal(geometry.low, 100);
  assert.equal(geometry.high, 200);
  assert.equal(geometry.path, 'M8.00,148.00 L68.31,12.00 M792.00,80.00');
});

test('empty, single and flat zero balances produce finite chart coordinates', () => {
  assert.equal(historyGeometry([]), null);
  const single = historyGeometry([{ at: 1000, total_jpy: '0' }]);
  assert.deepEqual(single.last, [400, 80]);
  const flat = historyGeometry([{ at: 1000, total_jpy: '0' }, { at: 1300, total_jpy: '0' }]);
  assert.equal(flat.path, 'M8.00,80.00 L792.00,80.00');
  assert.equal(flat.change, 0);
});
