
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const kbSrc = readFileSync(join(here, '../chopstickshq-site/js/chopsticks-ai-kb.js'), 'utf8');
const engineSrc = readFileSync(join(here, '../chopstickshq-site/js/chopsticks-ai.js'), 'utf8');

const noop = () => {};
const fakeNode = new Proxy({}, {
  get: (_, k) => (k === 'style' || k === 'classList' || k === 'dataset'
    ? fakeNode
    : (k === 'textContent' || k === 'className' ? '' : noop)),
  set: () => true,
});
globalThis.window = globalThis;
globalThis.document = {
  readyState: 'complete',
  head: fakeNode,
  body: fakeNode,
  createElement: () => fakeNode,
  addEventListener: noop,
  querySelector: () => null,
};

eval(kbSrc);
eval(engineSrc);

const { cases } = JSON.parse(readFileSync(join(here, 'fixtures.json'), 'utf8'));
let pass = 0;
const failures = [];

for (const [question, expected] of cases) {
  const res = globalThis.chopsticksAI.ask(question);
  const got = res.confident ? res.intent.id : null;
  if (got === expected) pass++;
  else failures.push({ question, expected, got });
}

console.log(`JS engine: ${pass}/${cases.length} passed`);
for (const f of failures) {
  console.log(`  FAIL  ${JSON.stringify(f.question)}\n        expected ${f.expected}  got ${f.got}`);
}
process.exit(failures.length ? 1 : 0);
