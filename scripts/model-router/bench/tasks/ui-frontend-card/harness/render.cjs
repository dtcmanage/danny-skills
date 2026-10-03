// Repo-owned dependencies only. Render JSX in a throwaway DOM; no browser,
// candidate packages, scripts, fetches or install instructions are executed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const Module = require('node:module');
const {JSDOM} = require('jsdom');
const {transformSync} = require('esbuild');
const postcss = require('postcss');
const tailwind = require('tailwindcss');

async function main() {
  const [answerPath, fixturePath] = process.argv.slice(2);
  const source = fs.readFileSync(answerPath, 'utf8');
  const net = require('node:net');
  net.Socket.prototype.connect = () => {throw new Error('network disabled');};
  global.fetch = () => {throw new Error('network disabled');};
  const dom = new JSDOM('<!doctype html><html><head></head><body><div id="root"></div></body></html>', {
    url: 'http://127.0.0.1', pretendToBeVisual: true
  });
  global.window = dom.window;
  global.document = dom.window.document;
  global.HTMLElement = dom.window.HTMLElement;
  global.IS_REACT_ACT_ENVIRONMENT = true;
  const React = require('react');
  const {createRoot} = require('react-dom/client');
  const {act} = React;
  const compiled = transformSync(source, {loader: 'jsx', format: 'cjs', jsx: 'transform'}).code;
  const candidate = new Module(answerPath, module);
  candidate.filename = answerPath;
  candidate.paths = module.paths;
  candidate.require = (id) => {
    if (id !== 'react') throw new Error('Only react imports are supported');
    return React;
  };
  candidate._compile(compiled, answerPath);
  assert.equal(typeof candidate.exports.App, 'function');
  const {items} = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
  const css = await postcss([tailwind({content:[{raw:source, extension:'jsx'}], corePlugins:{preflight:false}})])
    .process('@tailwind utilities;', {from:undefined});
  const style = document.createElement('style'); style.textContent = css.css; document.head.append(style);
  const root = createRoot(document.getElementById('root'));
  await act(async () => root.render(React.createElement(candidate.exports.App, {items})));
  const layout = document.querySelector('[data-testid="layout"]');
  const list = document.querySelector('[data-testid="list"]');
  const workspace = document.querySelector('[data-testid="workspace"]');
  assert.ok(layout && list && workspace);
  assert.ok(layout.contains(list) && layout.contains(workspace));
  for (const utility of ['grid','grid-cols-[1fr_3fr]','gap-4','bg-white']) assert.ok(layout.classList.contains(utility));
  assert.equal(window.getComputedStyle(layout).display, 'grid');
  assert.match(css.css, /grid-template-columns:\s*1fr 3fr/);
  assert.match(css.css, /gap:\s*1rem/);
  assert.match(css.css, /background-color:/);
  const buttons = [...list.querySelectorAll('button')];
  assert.equal(buttons.length, items.length);
  assert.deepEqual(buttons.map(b => b.textContent.trim()), items.map(i => i.name));
  const input = workspace.querySelector('input[aria-label="Notes"]');
  assert.ok(input);
  // Bypass React's per-node value tracker, then deliver the browser input event
  // so controlled and uncontrolled inputs both receive actual typed notes.
  const setValue = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  await act(async () => {
    setValue.call(input, 'retain my working notes');
    input.dispatchEvent(new window.Event('input', {bubbles:true}));
  });
  function check(index) {
    assert.ok(document.querySelector('[data-testid="workspace"]') === workspace, 'Workspace DOM node was remounted');
    assert.ok(workspace.querySelector('input[aria-label="Notes"]') === input, 'Notes input DOM node was remounted');
    assert.equal(input.value, 'retain my working notes');
    assert.ok(workspace.textContent.includes(items[index].name));
    assert.ok(workspace.textContent.includes(items[index].detail));
    for (let i = 0; i < items.length; i++) assert.equal(buttons[i].getAttribute('aria-pressed'), String(i === index));
  }
  check(0);
  for (const index of [1,2,0]) {
    await act(async () => buttons[index].dispatchEvent(new window.MouseEvent('click', {bubbles:true})));
    check(index);
  }
  await act(async () => root.unmount());
  dom.window.close();
  console.log('PASS: React rendered, Tailwind compiled, selection and static workspace DOM verified');
}
main().catch(error => {console.error(String(error)); process.exitCode = 1;});
