import assert from 'node:assert/strict';
import { registerHooks, syncBuiltinESMExports } from 'node:module';
import { pathToFileURL } from 'node:url';
import net from 'node:net';
import http from 'node:http';
import https from 'node:https';
import dgram from 'node:dgram';
import dns from 'node:dns';
import tls from 'node:tls';
import dnsPromises from 'node:dns/promises';
import http2 from 'node:http2';
import {writeSync} from 'node:fs';
// Capture the protocol and assertions before candidate code can touch globals.
const nonce = process.env.BENCH_NODE_NONCE;
delete process.env.BENCH_NODE_NONCE;
if (!nonce) throw new Error('Missing grading nonce');
const {ok, equal, notEqual, match, deepStrictEqual} = assert;
const stringify = JSON.stringify;
const write = writeSync;
const output = value => write(1, value);
const beforeExit = process.once.bind(process);
const same = Object.is;
const deny = () => { throw new Error('network disabled'); };
for (const [object, keys] of [[net, ['connect', 'createConnection']], [http, ['request', 'get']],
  [https, ['request', 'get']], [dgram, ['createSocket']], [dns, ['lookup', 'resolve']], [dnsPromises, ['lookup', 'resolve']], [http2, ['connect']], [tls, ['connect']]]) {
  for (const key of keys) object[key] = deny;
}
net.Socket.prototype.connect = deny;
dgram.Socket.prototype.send = deny;
dgram.Socket.prototype.connect = deny;
globalThis.fetch = deny;
globalThis.WebSocket = class { constructor() { deny(); } };
syncBuiltinESMExports();
const [testFile, solution] = process.argv.slice(2);
const solutionURL = pathToFileURL(solution).href;
registerHooks({resolve(specifier, context, next) {
  if (specifier.startsWith('./') && new URL(specifier + '.js', context.parentURL).href === solutionURL)
    return {url: solutionURL, shortCircuit: true};
  return next(specifier, context);
}, load(url, context, next) {
  return next(url, url === solutionURL ? {...context, format: "module"} : context);
}});
const tests = [], suites = [];
const defineGlobal = (name, value) => Object.defineProperty(globalThis, name,
  {value, writable: false, configurable: false});
defineGlobal('describe', (name, fn) => { suites.push({name, hooks: []}); try { fn(); } finally { suites.pop(); } });
defineGlobal('beforeEach', fn => { if (!suites.length) rootHooks.push(fn); else suites.at(-1).hooks.push(fn); });
const rootHooks = [];
const test = (name, fn) => tests.push({name: [...suites.map(s => s.name), name].join(' / '), fn,
  hooks: [rootHooks, ...suites.map(s => s.hooks)]});
for (const name of ['test', 'it', 'xtest', 'xit']) defineGlobal(name, test);
// Jest compares enumerable values recursively, ignoring undefined properties,
// array holes and class prototypes. Special values retain their own semantics.
function jestEqual(a, b, left = [], right = []) {
  if (same(a, b)) return true;
  if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object') return false;
  const tag = value => Object.prototype.toString.call(value);
  if (tag(a) !== tag(b)) return false;
  if (a instanceof Error) return a.message === b.message;
  if (a instanceof Date) return +a === +b;
  if (a instanceof RegExp) return a.source === b.source && a.flags === b.flags;
  if (['[object Number]', '[object String]', '[object Boolean]'].includes(tag(a)))
    return same(a.valueOf(), b.valueOf());
  const index = left.indexOf(a);
  if (index !== -1) return right[index] === b;
  if (right.includes(b)) return false;
  left.push(a); right.push(b);
  try {
    if (a instanceof Map || a instanceof Set) {
      if (a.size !== b.size) return false;
      const remaining = [...b];
      return [...a].every(value => {
        const found = remaining.findIndex(other => jestEqual(value, other, left, right));
        if (found === -1) return false;
        remaining.splice(found, 1); return true;
      });
    }
    const keys = value => Reflect.ownKeys(value).filter(key =>
      Object.prototype.propertyIsEnumerable.call(value, key) && value[key] !== undefined);
    const aKeys = keys(a), bKeys = keys(b);
    return aKeys.length === bKeys.length && aKeys.every(key => bKeys.includes(key) && jestEqual(a[key], b[key], left, right));
  } finally { left.pop(); right.pop(); }
}
const matcherNames = {
  toEqual: (a,b) => ok(jestEqual(a,b)), toStrictEqual: (a,b) => deepStrictEqual(a,b), toBe: (a,b) => ok(same(a,b)),
  toThrow: (a,b) => { equal(typeof a, 'function'); let caught; let threw = false;
    try { a(); } catch (e) { caught=e; threw=true; } ok(threw);
    if (typeof b === 'string') ok(String(caught?.message ?? caught).includes(b));
    else if (b instanceof RegExp) match(String(caught?.message ?? caught), b);
    else if (typeof b === 'function') ok(caught instanceof b);
    else if (b instanceof Error) equal(caught?.message, b.message); },
  toBeCloseTo: (a,b,d=2) => ok(Math.abs(a-b) < .5 * 10 ** -d),
  toBeInstanceOf: (a,b) => ok(a instanceof b), toBeUndefined: a => equal(a,undefined),
  toBeNull: a => equal(a,null), toBeDefined: a => notEqual(a,undefined),
  toMatch: (a,b) => ok(b instanceof RegExp ? b.test(a) : a.includes(b)),
  toHaveLength: (a,b) => equal(a.length,b), toContain: (a,b) => ok(a.includes(b)),
  toBeTruthy: a => ok(a), toBeFalsy: a => ok(!a),
  toBeGreaterThan: (a,b) => ok(a>b), toBeLessThan: (a,b) => ok(a<b)
};
matcherNames.toThrowError = matcherNames.toThrow;
defineGlobal('expect', value => {
  const build = negative => Object.fromEntries(Object.entries(matcherNames).map(([name, matcher]) =>
    [name, (...args) => { if (!negative) return matcher(value,...args);
      let failed = false; try { matcher(value,...args); } catch { failed=true; } ok(failed); }]));
  return {...build(false), not: build(true)};
});
// Keep candidate logging out of the single machine-readable result.
process.stdout.write = () => true;
process.stderr.write = () => true;
// Integer counters: a candidate that tampers with Array.prototype cannot hide a failure.
let passed = 0, ran = 0, failed = 0;
const failures = [];
output(nonce + ' loaded\n');
try { await import(pathToFileURL(testFile).href); }
catch (error) { failed++; failures.push('test loading: ' + String(error)); }
for (const item of tests) {
  try { for (const hook of item.hooks.flat()) await hook(); ran++; await item.fn(); passed++; }
  catch (error) { failed++; failures.push(item.name + ': ' + String(error)); }
}
if (!tests.length && !failed) { failed++; failures.push('No tests registered'); }
// Emit the verdict after asynchronous work drains. A late throw or an unresolved
// top-level await therefore cannot leave an accepted passing verdict behind.
beforeExit('beforeExit', () => output(nonce + ' verdict ' +
  '{"passed":' + passed + ',"failed":' + failed + ',"failures":' + stringify(failures) +
  ',"skipped":' + (tests.length - ran) + '}\n'));
