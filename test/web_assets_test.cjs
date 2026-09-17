// Run with: node --test test/web_assets_test.cjs
// The VM fixture controls network/media completion without third-party packages.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..');
const nodeTypes = { ELEMENT_NODE: 1, TEXT_NODE: 3, DOCUMENT_FRAGMENT_NODE: 11 };

class Element {
  constructor(name = 'div', text = '') {
    this.nodeName = name.toUpperCase();
    this.nodeType = name === '#text' ? 3 : name === '#fragment' ? 11 : 1;
    this.data = text;
    this.childNodes = [];
    this.attributes = new Map();
    this.listeners = new Map();
    this.classes = new Set();
    this.style = { setProperty(key, value) { this[key] = value; } };
    this.dataset = {};
    this.value = '';
    this.scrollHeight = 10000;
    this.clientHeight = 600;
    this.scrollTop = 0;
    this.htmlWrites = [];
    this.classList = {
      add: (...values) => values.forEach(value => this.classes.add(value)),
      remove: (...values) => values.forEach(value => this.classes.delete(value)),
      contains: value => this.classes.has(value),
      toggle: (value, force = !this.classes.has(value)) => {
        if (force) this.classes.add(value); else this.classes.delete(value);
        return force;
      },
    };
  }
  get className() { return [...this.classes].join(' '); }
  set className(value) { this.classes = new Set(value.split(/\s+/).filter(Boolean)); }
  get textContent() { return this.nodeType === 3 ? this.data : this.childNodes.map(n => n.textContent).join(''); }
  set textContent(value) {
    this.childNodes = [];
    if (String(value)) this.appendChild(new Element('#text', String(value)));
  }
  get innerText() { return this.textContent; }
  set innerText(value) { this.textContent = value; }
  get innerHTML() { return this.htmlWrites.at(-1) || ''; }
  set innerHTML(value) { this.htmlWrites.push(value); this.childNodes = []; }
  set src(value) { this.setAttribute('src', value); }
  get src() { return this.getAttribute('src') || ''; }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  removeAttribute(name) { this.attributes.delete(name); }
  appendChild(node) {
    if (node.nodeType === 11) {
      const children = node.childNodes.splice(0);
      children.forEach(child => this.appendChild(child));
    } else {
      this.childNodes.push(node);
    }
    return node;
  }
  append(...nodes) { nodes.forEach(node => this.appendChild(node)); }
  replaceChildren(...nodes) { this.childNodes = []; this.append(...nodes); }
  querySelectorAll(selector) {
    const selectors = selector.split(',').map(s => s.trim());
    const result = [];
    for (const child of this.childNodes) {
      if (selectors.some(s => child.matches(s))) result.push(child);
      result.push(...child.querySelectorAll(selector));
    }
    return result;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  matches(selector) {
    if (selector.startsWith('.')) return selector.slice(1).split('.').every(c => this.classes.has(c));
    return this.nodeName.toLowerCase() === selector.toLowerCase();
  }
  addEventListener(type, callback, options = {}) {
    const listeners = this.listeners.get(type) || [];
    listeners.push({ callback, once: !!options.once });
    this.listeners.set(type, listeners);
  }
  removeEventListener(type, callback) {
    this.listeners.set(type, (this.listeners.get(type) || []).filter(item => item.callback !== callback));
  }
  dispatch(type, values = {}) {
    const event = { type, target: this, stopPropagation() {}, preventDefault() {}, ...values };
    for (const item of [...(this.listeners.get(type) || [])]) {
      if (item.once) this.removeEventListener(type, item.callback);
      item.callback(event);
    }
  }
  scrollIntoView() {}
  click() { this.dispatch('click'); }
}

class MediaElement extends Element {
  constructor() {
    super('video');
    this.currentTime = 0;
    this.duration = NaN;
    this.paused = true;
    this.ended = false;
    this.playbackRate = 1;
    this.playCalls = 0;
  }
  get playbackRate() { return this._playbackRate; }
  set playbackRate(value) {
    if (!Number.isFinite(value)) throw new TypeError('playbackRate must be finite');
    if (value < 0 || value > 16) throw new Error('Unsupported playbackRate');
    this._playbackRate = value;
  }
  load() { this.currentTime = 0; this.duration = NaN; this.ended = false; this.paused = true; }
  pause() { this.paused = true; this.dispatch('pause'); }
  play() {
    this.playCalls += 1;
    this.paused = false;
    this.dispatch('play');
    return Promise.resolve();
  }
  metadata(duration = 100) { this.duration = duration; this.dispatch('loadedmetadata'); }
}

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function inlineScripts(file) {
  return [...fs.readFileSync(path.join(root, file), 'utf8').matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)].map(m => {
    const source = /\bsrc="([^"]+)"/.exec(m[1]);
    if (!source) return m[2];
    assert.ok(source[1].startsWith('/assets/'), `Unexpected script source: ${source[1]}`);
    return fs.readFileSync(path.join(root, 'assets/web', source[1]), 'utf8');
  });
}

function page(file, options = {}) {
  const elements = new Map();
  const requests = [];
  const storage = new Map(Object.entries(options.storage || {}));
  const timers = new Map();
  const createdUrls = [];
  const document = new Element('document');
  document.body = new Element('body');
  document.documentElement = new Element('html');
  document.getElementById = id => {
    if (!elements.has(id)) elements.set(id, /^(videoPlayer|audioPlayer|video-player)$/.test(id) ? new MediaElement() : new Element());
    return elements.get(id);
  };
  document.createElement = name => new Element(name);
  document.createTextNode = text => new Element('#text', text);
  document.createDocumentFragment = () => new Element('#fragment');
  document.querySelector = selector => {
    if (selector === '.panel.is-open') return null;
    return document.getElementById(selector);
  };
  document.querySelectorAll = () => [];
  const location = new URL(`http://localhost/${file}?source=${encodeURIComponent('番茄')}&book_id=book&item_id=a&tab=${encodeURIComponent(options.tab || '小说')}`);
  const sandbox = {
    document, location, URL: class extends URL {
      static createObjectURL(blob) { createdUrls.push(blob); return 'blob:download'; }
      static revokeObjectURL() {}
    }, URLSearchParams, Node: nodeTypes, Blob, AbortController, DOMException,
    history: { replaceState(_state, _title, url) { location.href = url.href; } },
    localStorage: {
      getItem: key => storage.get(key) ?? null,
      setItem: (key, value) => {
        if (options.storageWritesFail) throw new Error('QuotaExceededError');
        storage.set(key, String(value));
      },
      removeItem: key => storage.delete(key),
      key: index => [...storage.keys()][index] ?? null,
      get length() { return storage.size; },
    },
    PLUGIN_PARAMS: options.pluginParams || {},
    fetch: (url, fetchOptions) => {
      const pending = deferred();
      requests.push({ url, fetchOptions, ...pending });
      const signal = fetchOptions?.signal;
      if (signal) {
        const abort = () => pending.reject(signal.reason);
        if (signal.aborted) abort();
        else signal.addEventListener('abort', abort, { once: true });
        const cleanup = () => signal.removeEventListener('abort', abort);
        pending.promise.then(cleanup, cleanup);
      }
      return pending.promise;
    },
    DOMParser: class { parseFromString() { throw new Error('This test must supply its parsed document fixture'); } },
    innerHeight: 600, scrollY: 0,
    scrollTo() {}, getSelection() { return ''; },
    requestAnimationFrame(callback) { callback(); },
    addEventListener: document.addEventListener.bind(document),
    setTimeout(callback) { const id = Symbol(); timers.set(id, callback); return id; },
    clearTimeout(id) { timers.delete(id); },
    atob: value => Buffer.from(value, 'base64').toString('binary'),
    console,
  };
  sandbox.window = sandbox;
  if (options.storageBlocked) {
    Object.defineProperty(sandbox, 'localStorage', {
      get() { throw new Error('SecurityError: persistence is disabled'); },
    });
  }
  const context = vm.createContext(sandbox);
  for (const script of inlineScripts(file)) vm.runInContext(script, context, { filename: file });
  const run = code => vm.runInContext(code, context);
  const respond = (request, data, ok = true) => request.resolve({ ok, json: async () => data, text: async () => JSON.stringify(data) });
  return { context, run, elements, requests, storage, timers, createdUrls, respond, document };
}

function contentRequests(p) { return p.requests.filter(request => request.url.startsWith('/api/content?')); }
function element(name, ...children) { const node = new Element(name); node.append(...children); return node; }
function text(value) { return new Element('#text', value); }
function searchPayload(tab, title, count = 1) {
  return { code: 200, data: { search_tabs: [{ title: tab, data: Array.from({ length: count }, (_, id) => ({ book_data: [{ book_name: title, book_id: String(id) }] })) }] } };
}

test('all embedded scripts, filters and JSON configs parse', () => {
  for (const folder of ['assets/web', 'assets/plugins']) {
    for (const name of fs.readdirSync(path.join(root, folder)).filter(name => name.endsWith('.html'))) {
      inlineScripts(`${folder}/${name}`).forEach(script => new vm.Script(script, { filename: `${folder}/${name}` }));
    }
  }
  for (const name of fs.readdirSync(path.join(root, 'assets/filters'))) {
    new vm.Script(fs.readFileSync(path.join(root, 'assets/filters', name), 'utf8'), { filename: name });
  }
  for (const name of fs.readdirSync(path.join(root, 'assets/config')).filter(name => name.endsWith('.json'))) {
    JSON.parse(fs.readFileSync(path.join(root, 'assets/config', name), 'utf8'));
  }
});

for (const name of ['index', 'detail', 'read', 'comic', 'listen', 'video']) {
  test(`${name} remains usable when browser storage access is denied`, () => {
    const p = page(`assets/web/${name}.html`, { storageBlocked: true });
    assert.ok(p.elements.get('themeToggle').listeners.get('click')?.length);
    if (name !== 'index') assert.ok(p.requests.length > 0, 'initial requests must still start');
  });
}

test('storage quota exhaustion does not prevent search results or in-page preferences', async () => {
  const p = page('assets/web/index.html', { storageWritesFail: true });
  const searching = p.run('queryInput.value = "book"; runSearch(false)');
  assert.equal(p.requests.length, 1);
  p.respond(p.requests[0], searchPayload('书籍', 'Visible result'));
  await searching;
  assert.equal(p.elements.get('results').querySelector('h3').textContent, 'Visible result');
  p.elements.get('themeToggle').click();
  assert.equal(p.document.body.classList.contains('dark'), true);
  await p.run('queryInput.value = "book"; runSearch(false)');
  assert.equal(p.requests.length, 1, 'a failed persistent cache write may use bounded session storage');
});

test('storage can recover persistence and hide a failed deletion within the page', () => {
  const options = { storageWritesFail: true, storage: { progress: '50' } };
  const p = page('assets/web/index.html', options);
  p.run('appStorage.setItem("speed", "1.5")');
  assert.equal(p.run('appStorage.getItem("speed")'), '1.5');
  assert.equal(p.storage.has('speed'), false);
  options.storageWritesFail = false;
  p.run('appStorage.setItem("speed", "2")');
  assert.equal(p.run('appStorage.getItem("speed")'), '2');
  assert.equal(p.storage.get('speed'), '2');
  p.context.localStorage.removeItem = () => { throw new Error('SecurityError'); };
  p.run('appStorage.removeItem("progress")');
  assert.equal(p.storage.get('progress'), '50');
  assert.equal(p.run('appStorage.getItem("progress")'), null);
  assert.equal(p.run('appStorage.keys().includes("progress")'), false);
  p.context.localStorage.getItem = () => { throw new Error('SecurityError'); };
  assert.equal(p.run('appStorage.getItem("unavailable")'), null);
});

test('session storage stays bounded when persistence is disabled', () => {
  const p = page('assets/web/index.html', { storageBlocked: true });
  p.run('for (let i = 0; i < 400; i++) appStorage.setItem(`chapter:${i}`, "17")');
  assert.ok(p.run('appStorage.keys().length') <= 128);
  assert.equal(p.run('appStorage.getItem("chapter:399")'), '17');
  p.run('for (let i = 0; i < 20; i++) appStorage.setItem(`cache:${i}`, "x".repeat(100000))');
  assert.ok(p.run('appStorage.keys().reduce((sum, key) => sum + key.length + appStorage.getItem(key).length, 0)') <= 1024 * 1024);
  p.run('appStorage.setItem("preference", "dark"); appStorage.setItem("oversized", "x".repeat(2 * 1024 * 1024))');
  assert.equal(p.run('appStorage.getItem("oversized")'), null);
  assert.equal(p.run('appStorage.getItem("preference")'), 'dark');
});

for (const name of ['index', 'detail']) {
  test(`${name} ignores malformed cache metadata and preserves other preferences on clear`, () => {
    for (const metadata of ['null', '[]', '"broken"', '{']) {
      const p = page(`assets/web/${name}.html`, { storage: { 'novelapi_cache_v2:meta': metadata } });
      assert.ok(p.elements.get('themeToggle').listeners.get('click')?.length);
    }
    const p = page(`assets/web/${name}.html`, { storage: {
      'novelapi_cache_v2:meta': JSON.stringify({ 'other_preference': 0, 'novelapi_cache_v2:search:old': 0 }),
      'other_preference': 'keep',
      'novelapi_cache_v2:search:old': 'expired',
    } });
    p.run('clearManagedCache()');
    assert.equal(p.storage.get('other_preference'), 'keep');
    assert.equal(p.storage.has('novelapi_cache_v2:search:old'), false);
  });
}

test('search cards and errors preserve external markup as text', () => {
  const p = page('assets/web/index.html');
  p.context.injected = '<img src=x onerror="globalThis.injected=true">';
  p.context.coverPayload = 'x" onerror=alert(1)';
  p.run('renderResults([{ title: injected, author: injected, desc: injected, tags: [injected], source: "番茄", tab: "小说", cover: coverPayload }], false)');
  const results = p.elements.get('results');
  assert.equal(results.querySelector('h3').textContent, p.context.injected);
  assert.equal(results.querySelector('p').textContent, p.context.injected);
  assert.equal(results.querySelectorAll('img').length, 1);
  assert.equal(results.querySelector('img').getAttribute('onerror'), null);
  p.run('showEmpty(injected)');
  assert.equal(results.textContent, p.context.injected);
  assert.equal(results.querySelectorAll('img').length, 0);
});

test('a fresh search supersedes an in-flight search and stale failures keep the new request loading', async () => {
  const p = page('assets/web/index.html');
  const first = p.run('queryInput.value = "old"; runSearch(false)');
  const second = p.run('state.tab = "漫画"; queryInput.value = "new"; runSearch(false)');
  assert.equal(p.requests.length, 2);
  p.requests[0].reject(new Error('old error'));
  await first;
  assert.equal(p.run('state.loading'), true);
  assert.equal(p.elements.get('statusBar').textContent, '正在加载…');
  p.respond(p.requests[1], searchPayload('漫画', 'new result'));
  await second;
  assert.equal(p.elements.get('results').querySelector('h3').textContent, 'new result');
  assert.equal(p.run('state.page'), 1);
});

test('late search success cannot overwrite a new result or a mode reset', async () => {
  const p = page('assets/web/index.html');
  const first = p.run('queryInput.value = "old"; runSearch(false)');
  const second = p.run('queryInput.value = "new"; runSearch(false)');
  p.respond(p.requests[1], searchPayload('书籍', 'new result'));
  await second;
  p.respond(p.requests[0], searchPayload('书籍', 'old result'));
  await first;
  assert.equal(p.elements.get('results').querySelector('h3').textContent, 'new result');
  const third = p.run('queryInput.value = "third"; runSearch(false)');
  p.run('resetResults()');
  p.respond(p.requests[2], searchPayload('书籍', 'third result'));
  await third;
  assert.equal(p.elements.get('results').textContent, '');
  assert.equal(p.run('state.hasMore'), false);
});

test('search pagination uses the submitted query while the input is being edited', async () => {
  const p = page('assets/web/index.html');
  const loading = p.run('state.query = "submitted"; state.page = 1; state.hasMore = true; queryInput.value = "edited"; runSearch(true)');
  const url = new URL(p.requests[0].url, p.context.location);
  assert.equal(url.searchParams.get('query'), 'submitted');
  assert.equal(url.searchParams.get('page'), '2');
  p.respond(p.requests[0], searchPayload('书籍', 'page two'));
  await loading;
});

test('reader keeps the latest chapter on screen and caches each response with its original title', async () => {
  const p = page('assets/web/read.html');
  p.run('chapterList = [{ id: "a", title: "Alpha" }, { id: "b", title: "Beta" }]; globalThis.rendered = []; renderChapter = chapter => rendered.push(chapter)');
  const first = p.run('loadChapter()');
  const second = p.run('goToIndex(1)');
  const [a, b] = contentRequests(p);
  p.respond(b, { code: 200, data: { content: 'Beta body.' } });
  await second;
  p.respond(a, { code: 200, data: { content: 'Alpha body.' } });
  await first;
  assert.deepEqual(Array.from(p.context.rendered, item => item.title), ['Beta']);
  await p.run('goToIndex(0)');
  assert.deepEqual(Array.from(p.context.rendered, item => item.title), ['Beta', 'Alpha']);
  assert.equal(p.context.location.searchParams.get('item_id'), 'a');
});

test('reader rejects active chapter markup while preserving formatting and safe images', () => {
  const p = page('assets/web/read.html');
  const paragraph = element('p', text('Readable '), element('strong', text('text')));
  paragraph.setAttribute('onclick', 'attack()');
  paragraph.setAttribute('style', 'position:fixed');
  const image = element('img');
  image.setAttribute('src', 'https://example.test/page.jpg');
  image.setAttribute('onerror', 'attack()');
  const unsafeImage = element('img');
  unsafeImage.setAttribute('src', 'javascript:attack()');
  p.context.chapterNode = element('div', paragraph, image, unsafeImage, element('script', text('attack()')), element('svg', element('a', text('bad'))));
  const result = p.run('safeChapterNode(chapterNode)');
  assert.equal(result.textContent, 'Readable text');
  assert.equal(result.querySelectorAll('strong').length, 1);
  assert.equal(result.querySelectorAll('img').length, 1);
  assert.equal(result.querySelector('img').src, 'https://example.test/page.jpg');
  assert.equal(result.querySelector('img').getAttribute('onerror'), null);
  assert.equal(result.querySelector('p').getAttribute('onclick'), null);
  assert.equal(result.querySelector('p').getAttribute('style'), null);
  assert.equal(result.querySelectorAll('script,svg').length, 0);
});

test('reader retains body text that starts with the chapter title', () => {
  const p = page('assets/web/read.html');
  p.context.bodyText = '序\n序幕之后，故事才开始。';
  assert.deepEqual(Array.from(p.run('normalizeTextParagraphs(bodyText, "序")')), ['序幕之后，故事才开始。']);
});

test('comic ignores a late chapter response', async () => {
  const p = page('assets/web/comic.html');
  p.run('chapters = [{ id: "a", title: "Alpha" }, { id: "b", title: "Beta" }]; extractImages = html => [html]');
  const first = p.run('loadChapter()');
  const second = p.run('goToIndex(1)');
  const [a, b] = contentRequests(p);
  p.respond(b, { code: 200, data: { images: 'https://example.test/b.jpg' } });
  await second;
  p.respond(a, { code: 200, data: { images: 'https://example.test/a.jpg' } });
  await first;
  assert.equal(p.elements.get('imageList').querySelector('img').src, 'https://example.test/b.jpg');
});

for (const [file, collection, load, mediaId, responseKey, storageType] of [
  ['video', 'episodes', 'loadEpisode', 'videoPlayer', 'video_url', 'video'],
  ['listen', 'chapters', 'loadChapter', 'audioPlayer', 'audio_url', 'audio'],
]) {
  const setup = () => {
    const p = page(`assets/web/${file}.html`);
    p.run(`${collection} = [{ id: "a", title: "Alpha" }, { id: "b", title: "Beta" }, { id: "c", title: "Gamma" }]`);
    return p;
  };
  const progressKey = id => `novelapi_${storageType}_progress:番茄:book:${id}`;
  test(`${file} saves old media under its own chapter and ignores stale responses`, async () => {
    const p = setup();
    const media = p.elements.get(mediaId);
    const first = p.run(`${load}(false)`);
    p.respond(contentRequests(p)[0], { code: 200, data: { [responseKey]: 'https://example.test/a' } });
    await first;
    media.metadata();
    media.currentTime = 31;
    media.paused = false;
    p.storage.set(progressKey('b'), '12');
    p.storage.set(progressKey('c'), '8');
    const second = p.run('goToIndex(1)');
    assert.equal(p.storage.get(progressKey('a')), '31');
    assert.equal(media.paused, true);
    assert.equal(media.src, '');
    media.currentTime = 35;
    media.dispatch('timeupdate');
    media.dispatch('pause');
    assert.equal(p.storage.get(progressKey('b')), '12');
    const third = p.run('goToIndex(2)');
    p.respond(contentRequests(p)[2], { code: 200, data: { [responseKey]: 'https://example.test/c' } });
    await third;
    p.respond(contentRequests(p)[1], { code: 200, data: { [responseKey]: 'https://example.test/b' } });
    await second;
    assert.equal(media.src, 'https://example.test/c');
    media.metadata();
    assert.equal(media.currentTime, 8);
  });

  test(`${file} removes previous metadata callbacks before loading a new chapter`, async () => {
    const p = setup();
    const media = p.elements.get(mediaId);
    p.storage.set(progressKey('a'), '47');
    p.storage.set(progressKey('b'), '13');
    const first = p.run(`${load}(true)`);
    p.respond(contentRequests(p)[0], { code: 200, data: { [responseKey]: 'https://example.test/a' } });
    await first;
    const second = p.run(`currentIndex = 1; ${load}(false)`);
    p.respond(contentRequests(p)[1], { code: 200, data: { [responseKey]: 'https://example.test/b' } });
    await second;
    media.metadata();
    assert.equal(media.currentTime, 13);
    assert.equal(media.playCalls, 0);
  });

  test(`${file} does not recreate completed progress during automatic advance`, async () => {
    const p = setup();
    const media = p.elements.get(mediaId);
    const first = p.run(`${load}(false)`);
    p.respond(contentRequests(p)[0], { code: 200, data: { [responseKey]: 'https://example.test/a' } });
    await first;
    media.metadata();
    p.storage.set(progressKey('a'), '90');
    media.currentTime = 100;
    media.ended = true;
    media.dispatch('ended');
    assert.equal(p.storage.has(progressKey('a')), false);
    assert.equal(contentRequests(p).length, 2);
  });
}

test('late book tones reload the selected audio chapter without losing the play request', async () => {
  const p = page('assets/web/listen.html');
  const directory = p.requests.find(request => request.url.startsWith('/api/directory?'));
  const detail = p.requests.find(request => request.url.startsWith('/api/detail?'));
  p.respond(directory, { code: 200, data: { data: { chapterListWithVolume: [[{ itemId: 'a', title: 'Alpha' }, { itemId: 'b', title: 'Beta' }]] } } });
  await new Promise(setImmediate);
  const selected = p.run('goToIndex(1)');
  p.respond(detail, { code: 200, data: { tones: '2,3' } });
  await new Promise(setImmediate);
  const requests = contentRequests(p);
  assert.equal(requests.length, 2);
  const corrected = new URL(requests[1].url, p.context.location);
  assert.equal(corrected.searchParams.get('item_id'), 'b');
  assert.equal(corrected.searchParams.get('tone_id'), '2');
  p.respond(requests[1], { code: 200, data: { audio_url: 'https://example.test/b-tone-2' } });
  await new Promise(setImmediate);
  p.respond(requests[0], { code: 200, data: { audio_url: 'https://example.test/b-tone-1' } });
  await selected;
  const audio = p.elements.get('audioPlayer');
  assert.equal(audio.src, 'https://example.test/b-tone-2');
  audio.metadata();
  assert.equal(audio.playCalls, 1);
});

test('late audio fallback cannot replace the selected chapter or its progress', async () => {
  const p = page('assets/web/listen.html');
  p.run('chapters = [{ id: "a", title: "Alpha" }, { id: "b", title: "Beta" }]');
  const first = p.run('loadChapter(false)');
  p.respond(contentRequests(p)[0], { code: 200, data: {} });
  await new Promise(setImmediate);
  const fallback = p.requests.find(request => request.url.startsWith('/api/v1/audio/play?'));
  assert.ok(fallback, 'the first chapter started its fallback request');

  const second = p.run('goToIndex(1)');
  p.respond(contentRequests(p)[1], { code: 200, data: { audio_url: 'https://example.test/b' } });
  await second;
  const audio = p.elements.get('audioPlayer');
  audio.metadata();
  audio.currentTime = 23;
  p.respond(fallback, { video_info: { data: { video_model_datas: [{
    item_id: 'a', item_status: 0,
    video_model: JSON.stringify({ media_type: 'audio', video_list: [{ main_url: 'https://example.test/a' }] }),
  }] } } });
  await first;

  assert.equal(audio.src, 'https://example.test/b');
  assert.equal(audio.currentTime, 23);
  assert.equal(p.run('itemId'), 'b');
  assert.equal(p.run('activeItemId'), 'b');
  assert.equal(audio.listeners.get('loadedmetadata')?.length || 0, 0);
});

test('plugin video selection tracks the requested ID and ignores late responses', async () => {
  const p = page('assets/plugins/player.html');
  p.run('player.playlist = [{ item_id: "a", title: "Alpha" }, { item_id: "b", title: "Beta" }]');
  const first = p.run('player.loadVideo("a")');
  const second = p.run('player.loadVideo("b")');
  assert.equal(p.run('player.currentItemId'), 'b');
  p.respond(p.requests[1], { video_info: { data: { video_list: { video_1: { main_url: 'https://example.test/b' } } } } });
  await second;
  p.respond(p.requests[0], { video_info: { data: { video_list: { video_1: { main_url: 'https://example.test/a' } } } } });
  await first;
  assert.equal(p.elements.get('video-player').src, 'https://example.test/b');
  assert.equal(p.run('player.currentIndex'), 1);
});

test('plugin player restores long-press speed on cancellation and handles play rejection', async () => {
  const p = page('assets/plugins/player.html');
  p.run('player.currentSpeedIndex = 1; player.isLongPressing = true; player.startFastForward()');
  p.elements.get('interaction-layer').dispatch('touchcancel');
  assert.equal(p.elements.get('video-player').playbackRate, 1.25);
  assert.equal(p.run('player.isLongPressing'), false);
  p.elements.get('video-player').play = () => Promise.reject(new Error('blocked'));
  p.run('player.togglePlay()');
  await Promise.resolve();
  assert.match(p.elements.get('toast').textContent, /Playback failed/);
});

test('plugin manga selection can supersede a pending chapter without losing its identity', async () => {
  const p = page('assets/plugins/manga_reader.html');
  p.run('reader.chapters = [{ item_id: "a", title: "Alpha" }, { item_id: "b", title: "Beta" }]');
  const first = p.run('reader.loadChapter("a")');
  const second = p.run('reader.loadChapter("b")');
  assert.equal(p.run('reader.currentItemId'), 'b');
  p.respond(p.requests[0], { success: true, data: { images: ['https://example.test/a.jpg'] } });
  await first;
  assert.equal(p.run('reader.changingChapter'), true);
  p.respond(p.requests[1], { success: true, data: { images: ['https://example.test/b.jpg'] } });
  await second;
  assert.equal(p.elements.get('image-scroll-area').querySelector('img').src, 'https://example.test/b.jpg');
  assert.equal(p.run('reader.currentChapterIndex'), 1);
});

for (const boundary of ['next', 'previous']) {
  test(`plugin manga cancels pending ${boundary} navigation when the reader scrolls away`, () => {
    const p = page('assets/plugins/manga_reader.html');
    p.run('reader.chapters = [{ item_id: "a", title: "Alpha" }, { item_id: "b", title: "Beta" }]; reader.currentChapterIndex = 1; reader.ignoreScrollBoundary = false');
    if (boundary === 'next') p.run('reader.currentChapterIndex = 0');
    const container = p.elements.get('image-container');
    container.scrollTop = boundary === 'next' ? 9400 : 0;
    container.dispatch('scroll');
    assert.equal(p.timers.size, 1);
    container.scrollTop = 4000;
    container.dispatch('scroll');
    for (const callback of [...p.timers.values()]) callback();
    assert.equal(p.requests.length, 0);
    assert.equal(p.run('reader.currentChapterIndex'), boundary === 'next' ? 0 : 1);
  });
}

test('plugin manga still advances when it remains at the end', () => {
  const p = page('assets/plugins/manga_reader.html');
  p.run('reader.chapters = [{ item_id: "a", title: "Alpha" }, { item_id: "b", title: "Beta" }]; reader.currentChapterIndex = 0');
  const container = p.elements.get('image-container');
  container.scrollTop = 9400;
  container.dispatch('scroll');
  for (const callback of [...p.timers.values()]) callback();
  assert.equal(p.requests.length, 1);
  assert.equal(p.run('reader.currentItemId'), 'b');
});

test('plugin manga rechecks the end after late image layout changes', () => {
  const p = page('assets/plugins/manga_reader.html');
  p.run('reader.chapters = [{ item_id: "a", title: "Alpha" }, { item_id: "b", title: "Beta" }]; reader.currentChapterIndex = 0');
  const container = p.elements.get('image-container');
  container.scrollTop = 9400;
  container.dispatch('scroll');
  container.scrollHeight = 20000;
  for (const callback of [...p.timers.values()]) callback();
  assert.equal(p.requests.length, 0);
  assert.equal(p.run('reader.currentChapterIndex'), 0);
});

test('download text keeps nested paragraphs once and retains text beginning with the title', () => {
  const p = page('assets/web/detail.html');
  const body = element('body', element('div', element('p', text('序')), element('p', text('序幕之后')), element('p', text('下一段'), element('br'), text('换行'))), element('script', text('attack()')));
  p.context.DOMParser = class { parseFromString() { return { body }; } };
  assert.equal(p.run('normalizeDownloadParagraphs("fixture", "序")'), '序幕之后\n下一段\n换行');
});

test('download failure drains active workers before another download can start', async () => {
  const p = page('assets/web/detail.html');
  p.run('chapterData = [{ chapters: Array.from({ length: 8 }, (_, i) => ({ id: String(i), title: String(i) })) }]; normalizeDownloadParagraphs = content => content');
  const downloading = p.run('frontendDownload()');
  await p.run('frontendDownload()');
  assert.equal(contentRequests(p).length, 6);
  const pending = contentRequests(p);
  pending[0].reject(new Error('chapter fetch failed'));
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(p.elements.get('frontendDownloadBtn').disabled, true);
  for (const request of pending.slice(1)) p.respond(request, { code: 200, data: { content: 'Body' } });
  await downloading;
  assert.equal(contentRequests(p).length, 6);
  assert.equal(p.createdUrls.length, 0);
  assert.equal(p.elements.get('frontendDownloadBtn').disabled, false);
  assert.equal(p.elements.get('progressText').textContent, 'chapter fetch failed');
});

test('download failure aborts stalled peers, preserves its cause, and permits retry', async () => {
  const p = page('assets/web/detail.html');
  p.run('chapterData = [{ chapters: Array.from({ length: 8 }, (_, i) => ({ id: String(i), title: String(i) })) }]; normalizeDownloadParagraphs = content => content');
  const first = p.run('frontendDownload()');
  const stalled = contentRequests(p);
  assert.equal(stalled.length, 6);
  stalled[0].reject(new Error('chapter fetch failed'));
  await new Promise(setImmediate);
  assert.ok(stalled.every(request => request.fetchOptions?.signal?.aborted), 'one failure must abort every outstanding chapter request');
  await first;
  assert.equal(contentRequests(p).length, 6);
  assert.equal(p.createdUrls.length, 0);
  assert.equal(p.elements.get('progressText').textContent, 'chapter fetch failed');
  assert.equal(p.elements.get('frontendDownloadBtn').disabled, false);
  assert.ok(p.requests.filter(request => !stalled.includes(request))
    .every(request => request.fetchOptions?.signal === undefined));

  p.run('chapterData = [{ chapters: [{ id: "retry", title: "Retry" }] }]');
  const second = p.run('frontendDownload()');
  const retry = contentRequests(p).at(-1);
  assert.notEqual(retry.fetchOptions.signal, stalled[0].fetchOptions.signal);
  assert.equal(retry.fetchOptions.signal.aborted, false);
  p.respond(retry, { code: 200, data: { content: 'Complete text' } });
  await second;
  assert.equal(p.createdUrls.length, 1);
  assert.equal(p.elements.get('progressText').textContent, '下载完成');
});

test('cancelling a stalled download aborts its requests and permits a fresh download', async () => {
  const p = page('assets/web/detail.html');
  p.run('chapterData = [{ chapters: Array.from({ length: 8 }, (_, i) => ({ id: String(i), title: String(i) })) }]; normalizeDownloadParagraphs = content => content');
  const first = p.run('frontendDownload()');
  const stalled = contentRequests(p);
  assert.equal(stalled.length, 6);
  const pageRequests = p.requests.filter(request => !stalled.includes(request));
  assert.ok(pageRequests.length > 0);
  assert.ok(pageRequests.every(request => request.fetchOptions?.signal === undefined));
  p.elements.get('cancelDownloadBtn').click();
  await new Promise(setImmediate);
  assert.ok(stalled.every(request => request.fetchOptions?.signal?.aborted), 'all active chapter requests must be aborted');
  await first;
  assert.equal(p.elements.get('frontendDownloadBtn').disabled, false);
  assert.equal(p.elements.get('progressText').textContent, '下载已取消');
  assert.equal(p.createdUrls.length, 0);

  p.run('chapterData = [{ chapters: [{ id: "fresh", title: "Fresh" }] }]');
  const second = p.run('frontendDownload()');
  const fresh = contentRequests(p).at(-1);
  assert.notEqual(fresh.fetchOptions.signal, stalled[0].fetchOptions.signal);
  assert.equal(fresh.fetchOptions.signal.aborted, false);
  p.respond(fresh, { code: 200, data: { content: 'Complete text' } });
  await second;
  assert.equal(p.createdUrls.length, 1);
  assert.equal(p.elements.get('progressText').textContent, '下载完成');
});

test('audio fallback never plays an explicitly different chapter', async () => {
  const p = page('assets/web/listen.html');
  p.run('chapters = [{ id: "wanted", title: "Wanted" }]');
  const loading = p.run('loadChapter(true)');
  p.respond(contentRequests(p)[0], { code: 200, data: {} });
  await new Promise(setImmediate);
  const fallback = p.requests.find(request => request.url.startsWith('/api/v1/audio/play?'));
  p.respond(fallback, { video_info: { data: { video_model_datas: [{
    item_id: 'different', item_status: 0,
    video_model: { media_type: 'audio', video_list: [{ main_url: 'https://example.test/wrong-chapter' }] },
  }] } } });
  await loading;
  assert.equal(p.elements.get('audioPlayer').src, '');
  assert.equal(p.run('activeItemId'), '');
  assert.equal(p.elements.get('playerStatus').textContent, '未获取到音频地址');
});

test('audio fallback finds the matching chapter after an unrelated row', async () => {
  const p = page('assets/web/listen.html');
  const loading = p.run('fetchPlaybackURL("wanted", "1")');
  const fallback = p.requests.find(request => request.url.startsWith('/api/v1/audio/play?'));
  const row = id => ({ item_id: id, item_status: 0, video_model: {
    media_type: 'audio', video_list: [{ main_url: `https://example.test/${id}` }],
  } });
  p.respond(fallback, { video_info: { data: { video_model_datas: [row('different'), row('wanted')] } } });
  assert.equal(await loading, 'https://example.test/wanted');
});

test('audio fallback rejects a singleton row without a chapter identity', async () => {
  const p = page('assets/web/listen.html');
  const loading = p.run('fetchPlaybackURL("wanted", "1")');
  const fallback = p.requests.find(request => request.url.startsWith('/api/v1/audio/play?'));
  p.respond(fallback, { video_info: { data: { video_model_datas: [{
    item_status: 0, video_model: { media_type: 'audio', video_list: [{ main_url: 'https://example.test/unidentified' }] },
  }] } } });
  assert.equal(await loading, '');
});

for (const [name, key, mediaId] of [
  ['listen', 'novelapi_audio_speed_v3', 'audioPlayer'],
  ['video', 'novelapi_video_speed_v3', 'videoPlayer'],
]) {
  test(`${name} recovers invalid persisted speeds without blocking initialization`, () => {
    for (const value of ['bad', 'Infinity', '-1', '100', '0']) {
      const p = page(`assets/web/${name}.html`, { storage: { [key]: value } });
      assert.equal(p.elements.get(mediaId).playbackRate, 1, `invalid speed ${value}`);
      assert.ok(p.requests.some(request => request.url.startsWith('/api/directory?')));
    }
  });

  test(`${name} preserves each supported persisted speed`, () => {
    for (const value of ['1', '1.25', '1.5', '2']) {
      const p = page(`assets/web/${name}.html`, { storage: { [key]: value } });
      assert.equal(p.elements.get(mediaId).playbackRate, Number(value));
      assert.ok(p.requests.some(request => request.url.startsWith('/api/directory?')));
    }
  });
}
