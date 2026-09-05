// Exercise the production preferences independently of the Chromium test host.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const source = fs.readFileSync(path.join(__dirname, '../Sources/States/ImmersiveTranslation.swift'), 'utf8');
const browserStateSource = fs.readFileSync(path.join(__dirname, '../Sources/States/BrowserState.swift'), 'utf8');
const translationPopoverSource = fs.readFileSync(path.join(__dirname, '../Sources/UserInterface/Sidebar/Bottom/SidebarBottomBar.swift'), 'utf8');
if (source.includes('automaticDisplayKey') || source.includes('translateFocusedPageAutomatically')) {
  throw new Error('Automatic translation remains enabled in the translation state');
}
if (browserStateSource.includes('translateFocusedPageAutomatically')) {
  throw new Error('Tab loading still triggers automatic translation');
}
if (!translationPopoverSource.includes('translation.popover.manualOnlyNotice')) {
  throw new Error('The translation popover does not explain explicit activation');
}
const start = source.indexOf('enum ImmersiveTranslationLanguage:');
const end = source.indexOf('enum ImmersiveTranslationError:');
if (start < 0 || end <= start) throw new Error('Could not locate production preferences');
const checks = `
let suite = "test.webpageLanguages." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
func check(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
check(ImmersiveTranslationPreferences.loadDisplayLanguages(from: defaults) == [.simplifiedChinese, .english], "Default ordering")
defaults.set("ja", forKey: "immersiveTranslation.targetLanguage")
check(ImmersiveTranslationPreferences.loadDisplayLanguages(from: defaults) == [.japanese], "Legacy preference migration")
ImmersiveTranslationPreferences.saveDisplayLanguages([.french, .english, .korean, .french], to: defaults)
check(ImmersiveTranslationPreferences.loadDisplayLanguages(from: defaults) == [.french, .english, .korean], "Ordered persistence and deduplication")
ImmersiveTranslationPreferences.saveLanguage(.japanese, to: defaults)
check(ImmersiveTranslationPreferences.loadDisplayLanguages(from: defaults) == [.french, .english, .korean], "Manual translation does not override automatic display")
ImmersiveTranslationPreferences.saveDisplayLanguages([.korean, .french], to: defaults)
check(ImmersiveTranslationPreferences.loadDisplayLanguages(from: defaults) == [.korean, .french], "Reorder and removal")
defaults.set(["invalid", "en", "en", "ja"], forKey: "immersiveTranslation.displayLanguages")
check(ImmersiveTranslationPreferences.loadDisplayLanguages(from: defaults) == [.english, .japanese], "Invalid stored values")
ImmersiveTranslationPreferences.saveDisplayLanguages([], to: defaults)
check(ImmersiveTranslationPreferences.loadDisplayLanguages(from: defaults) == [.simplifiedChinese, .english], "Nonempty fallback")
defaults.removePersistentDomain(forName: suite)
ImmersiveTranslationPreferences.saveLanguage(.french, to: defaults)
check(ImmersiveTranslationPreferences.loadDisplayLanguages(from: defaults) == [.simplifiedChinese, .english], "First manual use preserves display defaults")
print("PASS: default ordering, migration, deduplication, persistence, reordering, removal, validation, and manual translation isolation")
`;
const result = spawnSync('swift', ['-'], { input: 'import Foundation\n' + source.slice(start, end) + checks, encoding: 'utf8' });
process.stdout.write(result.stdout || '');
process.stderr.write(result.stderr || '');
if (result.error) throw result.error;
process.exit(result.status ?? 1);
