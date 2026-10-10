import assert from 'node:assert/strict';
import test from 'node:test';

import { slugify } from '../slugify.js';

test('lowercases and joins words with dashes', () => {
  assert.equal(slugify('Hello, World'), 'hello-world');
});

test('collapses runs of punctuation and trims the ends', () => {
  assert.equal(slugify('  --Read   the *diff* first!  '), 'read-the-diff-first');
});

test('an empty title gives an empty slug', () => {
  assert.equal(slugify(''), '');
});
