const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(require('node:path').join(__dirname, '../Sources/ChromiumBridge/CefWebContentWrapper.swift'), 'utf8');
const script = source.split('enum YouTubeOriginalAudioPolicy {')[1].split('#"""')[1].split('"""#')[0];
const events = new Map();
const selected = [];
let video = 'first';
let tracks = [];
const player = {
  getVideoData: () => ({video_id: video}),
  getAvailableAudioTracks: () => tracks,
  setAudioTrack: track => selected.push(track)
};
const context = {window: {}, document: {
  getElementById: () => player,
  addEventListener: (name, action) => events.set(name, action)
}};
vm.runInNewContext(script, context);
assert.equal(selected.length, 0);
const original = {getLanguageInfo: () => ({name: 'Chinese (original)'})};
tracks = [{kind: 'dubbed'}, original];
events.get('canplay')();
assert.equal(selected[0], original);
events.get('canplay')();
events.get('yt-player-updated')();
assert.equal(selected.length, 1, 'Do not overwrite later manual track choices');
video = 'second';
events.get('yt-navigate-finish')();
assert.equal(selected.length, 2);
video = 'third';
tracks = [{audioIsDefault: true, name: 'English'}];
events.get('canplay')();
assert.equal(selected.length, 2, 'Default does not establish original-track identity');
vm.runInNewContext(script, context);
assert.equal(events.size, 4);
console.log('PASS: original audio, delayed tracks, manual choice, SPA navigation and unknown identity');
