// Exercise production model persistence and the long-message sizing contract.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.join(__dirname, '..');
const api = fs.readFileSync(path.join(root, 'Sources/Networking/APIClient.swift'), 'utf8');
const preferences = fs.readFileSync(path.join(root, 'Sources/UserInterface/Preferences/PhiPreferences.swift'), 'utf8');
const chat = fs.readFileSync(path.join(root, 'Sources/UserInterface/Chat/EmbeddedChatViewController.swift'), 'utf8');

function between(source, start, end) {
  const first = source.indexOf(start);
  const last = source.indexOf(end, first + start.length);
  if (first < 0 || last <= first) throw new Error(`Missing production boundary: ${start}`);
  return source.slice(first, last);
}

const model = between(api, 'struct ZenMuxModel:', 'enum ZenMuxInputLanguage:');
const modelPreferences = between(
  preferences,
  '        static let zenMuxModelKey',
  '        static func loadZenMuxInputLanguage'
).replace(/^        /gm, '    ');

for (const contract of [
  'view.textContainer?.widthTracksTextView = false',
  'view.layoutManager?.invalidateLayout(',
  'nsView.frame.size.width = width',
]) {
  if (!chat.includes(contract)) throw new Error(`Missing message layout contract: ${contract}`);
}

const checks = `
import AppKit
import Foundation
${model}
enum Settings {
${modelPreferences}
}
func check(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
let suite = "test.zenmuxModels." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
check(Settings.loadZenMuxModels(from: defaults) == ZenMuxModel.allCases, "Built-in migration")
let custom = ZenMuxModel(rawValue: "openai/example-model")
Settings.saveZenMuxModels([.geminiFlash, custom, custom], defaultModel: custom, to: defaults)
check(Settings.loadZenMuxModels(from: defaults) == [.geminiFlash, custom], "Add and deduplicate")
check(Settings.loadZenMuxModel(from: defaults) == custom, "Custom default")
Settings.saveZenMuxModels([.geminiFlash], defaultModel: custom, to: defaults)
check(Settings.loadZenMuxModel(from: defaults) == .geminiFlash, "Deleted default fallback")

func measuredHeight(width: CGFloat) -> CGFloat {
    let view = NSTextView()
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.widthTracksTextView = false
    view.frame.size.width = width
    view.string = Array(repeating: "A long message must wrap without covering the controls below it.", count: 20).joined(separator: " ")
    view.textContainer?.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
    view.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: view.string.utf16.count), actualCharacterRange: nil)
    view.layoutManager?.ensureLayout(for: view.textContainer!)
    return ceil(view.layoutManager!.usedRect(for: view.textContainer!).height)
}
let narrow = measuredHeight(width: 260)
let wide = measuredHeight(width: 520)
check(narrow > wide && wide > 40, "Width-sensitive long-message height")
print("PASS: model add, deduplication, deletion, default selection, and width-sensitive message height")
`;

const result = spawnSync('swift', ['-'], { input: checks, encoding: 'utf8' });
process.stdout.write(result.stdout || '');
process.stderr.write(result.stderr || '');
if (result.error) throw result.error;
process.exit(result.status ?? 1);
