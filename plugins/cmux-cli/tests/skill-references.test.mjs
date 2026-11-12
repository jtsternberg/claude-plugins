import { readFileSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import assert from 'node:assert/strict';

const skillDir = resolve(dirname(fileURLToPath(import.meta.url)), '../skills/using-cmux-cli');
const main = readFileSync(resolve(skillDir, 'SKILL.md'), 'utf8');
const references = [...main.matchAll(/\$\{CLAUDE_SKILL_DIR\}\/references\/([\w-]+\.md)/g)]
  .map(match => match[1]);
const slug = text => text.toLowerCase().replace(/[^\w\s-]/g, '').replace(/ /g, '-');

test('each required procedure is reachable through a runtime-resolved read trigger', () => {
  for (const name of ['targeting.md', 'opening-surfaces.md', 'terminal-io.md',
    'command-reference.md', 'events.md', 'browser.md', 'ssh.md', 'layouts.md', 'progress-loops.md']) {
    assert.ok(references.includes(name), `missing read trigger for ${name}`);
    assert.ok(existsSync(resolve(skillDir, 'references', name)), `missing ${name}`);
  }
});

test('moved procedures retain valid local links and section anchors', () => {
  for (const file of ['SKILL.md', ...new Set(references.map(name => `references/${name}`))]) {
    const path = resolve(skillDir, file);
    const text = readFileSync(path, 'utf8');
    for (const [, link] of text.matchAll(/\]\(([^)]+)\)/g)) {
      if (link.includes('://')) continue;
      const [relative, anchor] = link.split('#');
      const target = relative ? resolve(dirname(path), relative) : path;
      assert.ok(existsSync(target), `${file}: missing ${link}`);
      if (anchor) {
        const headings = [...readFileSync(target, 'utf8').matchAll(/^#{1,6} (.+)$/gm)]
          .map(match => slug(match[1]));
        assert.ok(headings.includes(anchor), `${file}: missing anchor ${link}`);
      }
    }
  }
});
