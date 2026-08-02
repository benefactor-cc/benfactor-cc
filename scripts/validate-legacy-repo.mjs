#!/usr/bin/env node

import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import process from 'node:process';

const root = resolve(process.cwd());
const failures = [];
const read = (path) => readFileSync(join(root, path), 'utf8');
const fail = (message) => failures.push(message);

for (const required of ['README.md', 'index.html', 'robots.txt']) {
  if (!existsSync(join(root, required))) fail(`missing required retirement file: ${required}`);
}

if (existsSync(join(root, 'CNAME'))) {
  fail('CNAME must not exist in the retired misspelled repository');
}

if (failures.length === 0) {
  const index = read('index.html');
  const readme = read('README.md');
  const robots = read('robots.txt');

  if (!/<meta\b[^>]*name=["']robots["'][^>]*noindex/i.test(index)) {
    fail('index.html must declare noindex');
  }
  if (!/<link\b[^>]*rel=["']canonical["'][^>]*href=["']https:\/\/benefactor\.cc\/?["']/i.test(index)) {
    fail('index.html must point its canonical URL to https://benefactor.cc/');
  }
  if (!/<meta\b[^>]*http-equiv=["']refresh["'][^>]*https:\/\/benefactor\.cc\//i.test(index)) {
    fail('index.html must immediately redirect to https://benefactor.cc/');
  }
  if (/<(?:form|script)\b/i.test(index)) {
    fail('retired entrypoint must not contain forms or scripts');
  }
  if (/\b(?:src|href)=["']\/(?:_astro|assets)\//i.test(index)) {
    fail('retired entrypoint must not load the old generated asset graph');
  }
  if (/\b(?:3x|150\+|92%)\b|average roi lift|client retention|campaigns launched/i.test(index)) {
    fail('retired entrypoint must not republish unsupported legacy claims');
  }
  if (!/ORESoftware\/benefactor\.cc/.test(readme) || !/benefactor-cc\/benefactor-cc\.github\.io/.test(readme)) {
    fail('README must identify both canonical source and generated-output repositories');
  }
  if (!/^User-agent:\s*\*\s*$[\s\S]*^Disallow:\s*\/\s*$/m.test(robots)) {
    fail('robots.txt must disallow all crawling');
  }

  for (const [path, content] of [
    ['index.html', index],
    ['README.md', readme],
    ['robots.txt', robots],
  ]) {
    if (/^(?:<<<<<<<|=======|>>>>>>>)/m.test(content)) fail(`${path} contains a conflict marker`);
    if (/\b(?:ghp_|github_pat_|sk_live_|xox[baprs]-|SG\.)[A-Za-z0-9_.-]{12,}/.test(content)) {
      fail(`${path} contains a secret-shaped value`);
    }
  }
}

const workflowsDirectory = join(root, '.github', 'workflows');
if (existsSync(workflowsDirectory)) {
  const forbiddenDeployment = /\bpages\s*:\s*write\b|\bid-token\s*:\s*write\b|actions\/deploy-pages|actions\/configure-pages|peaceiris\/actions-gh-pages|JamesIves\/github-pages-deploy-action/i;
  for (const entry of readdirSync(workflowsDirectory, { withFileTypes: true })) {
    if (!entry.isFile() || entry.name === 'legacy-guard.yml') continue;
    const content = readFileSync(join(workflowsDirectory, entry.name), 'utf8');
    if (forbiddenDeployment.test(content)) {
      fail(`workflow ${entry.name} can deploy GitHub Pages from a retired repository`);
    }
  }
}

if (failures.length > 0) {
  console.error(`Legacy repository validation failed with ${failures.length} problem(s):`);
  for (const failure of failures) console.error(`- ${failure}`);
  process.exitCode = 1;
} else {
  console.log('Legacy repository is non-deployable, no-indexed, and points only to the canonical Benefactor site.');
}
