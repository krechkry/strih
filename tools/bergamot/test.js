// Translates sample captions with Firefox's translation models through bergamot-translator (WASM), the same
// engine the app will use. Usage: node test.js <modelsRoot>
const {Worker} = require('node:worker_threads');
const fs = require('fs'), zlib = require('zlib'), path = require('path');


const root = process.argv[2];
const w = new Worker(path.join(__dirname, 'engine', 'translator-worker.cjs'));
let next = 0; const pending = new Map();
w.on('message', ({id, result, error}) => { const p = pending.get(id); pending.delete(id); error ? p.reject(error) : p.resolve(result); });
const call = (name, ...args) => new Promise((resolve, reject) => { const id = ++next; pending.set(id, {resolve, reject}); w.postMessage({id, name, args}); });

function buf(file) {
  let b = fs.readFileSync(file);
  if (file.endsWith('.gz')) b = zlib.gunzipSync(b);
  return b.buffer.slice(b.byteOffset, b.byteOffset + b.length);
}

function files(dir) {
  const fs_ = fs.readdirSync(dir);
  const find = re => fs_.find(f => re.test(f));
  const model = find(/^model\..*\.bin(\.gz)?$/), lex = find(/^lex\..*(\.bin)?(\.gz)?$/);
  const vocab = find(/^vocab\..*\.spm(\.gz)?$/), src = find(/^srcvocab\./), trg = find(/^trgvocab\./);
  const vocabs = vocab ? [buf(path.join(dir, vocab))] : [buf(path.join(dir, src)), buf(path.join(dir, trg))];
  return {model: buf(path.join(dir, model)), shortlist: buf(path.join(dir, lex)), vocabs: vocabs.length === 1 ? [vocabs[0], vocabs[0]] : vocabs};
}

const samples = {
  cs: ['Ahoj, tohle je Bombocut.', 'Dneska jedeme na skatepark v Karlíně a natočíme nový díl.',
       'Robin jede první, pak zbytek party.', 'To je ono, to bylo fakt hustý!', 'Kluci, dejte mi chvilku, musím si nafouknout kolo.'],
  sk: ['Ahoj, toto je Bombocut.', 'Dnes ideme na skatepark a natočíme nový diel.', 'To bolo fakt super!'],
  en: ['Hey, this is Bombocut.', 'Today we are going to the skatepark in Karlín to film a new episode.',
       'Robin goes first, then the rest of the crew.', "That's it, that was really sick!"],
};

(async () => {
  const t0 = Date.now();
  await call('initialize', {cacheSize: 0});
  console.log(`engine ready in ${Date.now() - t0} ms`);
  for (const dir of fs.readdirSync(root).sort()) {
    const variant = 'firefox', pair = dir;
    const from = pair.slice(0, 2), to = pair.slice(2);
    try {
      const t1 = Date.now();
      await call('loadTranslationModel', {from, to}, files(path.join(root, dir)));
      const t2 = Date.now();
      const out = await call('translate', {models: [{from, to}], texts: samples[from].map(text => ({text, html: false}))});
      const t3 = Date.now();
      console.log(`\n== ${variant} ${from}->${to}  load ${t2 - t1} ms, translate ${t3 - t2} ms`);
      samples[from].forEach((s, i) => console.log(`  ${s}\n  -> ${out[i].target.text}`));
      await call('freeTranslationModel', {from, to});
    } catch (e) {
      console.log(`\n== ${variant} ${from}->${to} FAILED: ${e.message || JSON.stringify(e)}`);
    }
  }
  process.exit(0);
})();
