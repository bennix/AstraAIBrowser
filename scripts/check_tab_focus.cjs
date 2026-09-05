// Run production focus gates without launching Chromium or touching user data.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const read = file => fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
const wrapper = read('Sources/ChromiumBridge/CefWebContentWrapper.swift');
const container = read('Sources/UserInterface/WebContent/WebContentContainerViewController.swift');
const runtime = read('Sources/ChromiumBridge/CefBrowserRuntime.swift');
function between(source, start, end) {
  const a = source.indexOf(start);
  const b = source.indexOf(end, a + start.length);
  if (a < 0 || b < 0) throw new Error(`Missing production boundary: ${start}`);
  return source.slice(a, b);
}
const gates = between(wrapper, '    func browserShouldCancelSetFocus(', '    func browserDidClose(');
const focus = between(wrapper, '    func focus() {', '    func restoreFocus()');
const selectionGate = between(container, '        guard state.focusingTab?.guid == tab.guid', '\n\n');
const paintGate = between(container, '        guard browserState?.focusingTab?.guid == tabId', '\n');
const wiring = between(runtime, '        wrapper.onActivate =', '        wrapper.onClose =');
const test = `
import Foundation
final class CefBrowser {}
final class Window { func makeFirstResponder(_ value: Any) {} }
final class Host { var window: Window? = Window(); var isHiddenOrHasHiddenAncestor = false }
final class Chrome { var activations = 0; func activate() { activations += 1 } }
final class Wrapper {
 var didRequestClose = false
 var canReceiveFocus: (() -> Bool)?
 var onActivate: (() -> Void)?
 var hostView = Host()
 var isFocused = false
 var chromeBrowser: Chrome? = Chrome()
 var systemMediaWebView: Int?
 ${gates}
 ${focus}
}
final class Tab { let guid: Int; init(_ id: Int) { guid = id } }
final class State {
 var focusingTab: Tab?
 var changes = 0
 var groups: [Int: Int] = [:]
 func focuseTab(_ tab: Tab) { changes += 1; focusingTab = tab }
 func splitGroup(forTabId id: Int) -> Int? { groups[id] }
}
func wire(_ wrapper: Wrapper, _ state: State, _ tab: Tab) {
 ${wiring}
}
func check(_ value: Bool, _ message: String) { precondition(value, message) }
let state = State(), a = Tab(1), b = Tab(2), old = Wrapper(), current = Wrapper()
wire(old, state, a); wire(current, state, b)
let browser = CefBrowser()
state.focusingTab = a
old.browserDidGainFocus(browser)
check(state.changes == 0, "Focus acknowledgement must not republish selection")
state.focusingTab = b
old.browserDidGainFocus(browser)
old.focus()
check(state.focusingTab === b && old.chromeBrowser!.activations == 0, "Visible outgoing tab must not reclaim focus")
check(old.browserShouldCancelSetFocus(browser), "Reject outgoing CEF focus")
current.focus()
check(current.chromeBrowser!.activations == 1, "Selected surface remains interactive")
current.hostView.isHiddenOrHasHiddenAncestor = true
current.focus()
check(current.chromeBrowser!.activations == 1, "Hidden surface cannot activate")
current.hostView.isHiddenOrHasHiddenAncestor = false
current.hostView.window = nil
check(current.browserShouldCancelSetFocus(browser), "Detached surface cannot focus")
current.hostView.window = Window(); current.didRequestClose = true
check(current.browserShouldCancelSetFocus(browser), "Closed surface cannot focus")
state.groups = [1: 7, 2: 7]
old.browserDidGainFocus(browser)
check(state.focusingTab === a, "Visible split partner can receive focus")
var mounts = 0
func mount(_ tab: Tab) {
 ${selectionGate}
 mounts += 1
}
state.focusingTab = b
mount(a); mount(b)
check(mounts == 1, "Queued obsolete selection must not mount")
var browserState: State? = state
var promotions = 0
func promote(_ tabId: Int) {
 ${paintGate}
 promotions += 1
}
promote(1); promote(2)
check(promotions == 1, "Late first paint must not promote obsolete tab")
print("PASS: outgoing, selected, hidden, detached, closed, split, duplicate focus, queued selection, late paint")
`;
const result = spawnSync('swift', ['-'], { input: test, encoding: 'utf8' });
process.stdout.write(result.stdout || '');
process.stderr.write(result.stderr || '');
if (result.error) throw result.error;
process.exit(result.status ?? 1);
