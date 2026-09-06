import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

// Exercise the production operation without issuing requests or touching accounts.
const source = readFileSync(new URL('../Sources/ChromiumBridge/CefWebContentWrapper.swift', import.meta.url), 'utf8');
const script = source.match(/enum PageDistractionDismissal[\s\S]*?static let script = #"""\n([\s\S]*?)\n    """#/)[1];

async function run(options = {}) {
  let clicks = 0;
  const close = { disabled: !!options.disabled, getClientRects: () => [1], click() {
    clicks++;
    if (!options.keptOpen) dialog.isConnected = false;
  }};
  const dialog = {
    isConnected: true,
    getClientRects: () => options.hidden ? [] : [1],
    querySelector(selector) {
      if (selector === '.SignFlow') return options.otherDialog ? null : {};
      if (selector === 'button.Modal-closeButton') return options.noClose ? null : close;
      return options.challenge ? {} : null;
    }
  };
  const context = {
    location: { hostname: options.host ?? 'www.zhihu.com', pathname: options.path ?? '/question/34569900' },
    document: { querySelectorAll: () => options.empty ? [] : [dialog] },
    getComputedStyle: () => ({ visibility: 'visible', display: 'block' }),
    setTimeout: callback => callback()
  };
  const result = await vm.runInNewContext(`(async () => {${script}})()`, context);
  return { result, clicks };
}

assert.deepEqual(await run(), { result: 'closed', clicks: 1 });
for (const options of [{challenge:true}, {otherDialog:true}, {noClose:true}, {disabled:true}, {hidden:true}, {empty:true}]) {
  assert.deepEqual(await run(options), { result: 'none', clicks: 0 });
}
for (const options of [{host:'zhihu.com.example.org'}, {host:'example.org'}, {path:'/signin'}]) {
  assert.deepEqual(await run(options), { result: 'unsupported', clicks: 0 });
}
assert.deepEqual(await run({keptOpen:true}), { result: 'none', clicks: 1 });
console.log('Page distraction checks passed (11 scenarios).');
