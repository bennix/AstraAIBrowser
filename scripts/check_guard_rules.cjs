// Exercise the production rule validator without the CEF test host.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const source = fs.readFileSync(path.join(__dirname, '../Sources/ChromiumBridge/XSpamShield.swift'), 'utf8');
const rule = source.slice(source.indexOf('struct XSpamShieldRule:'), source.indexOf('actor XSpamShieldStore'));
const policy = source.slice(source.indexOf('enum XSpamShieldWebPolicy'));
const checks = String.raw`
func check(_ value: Bool) { precondition(value) }
check(XSpamShieldRule(pattern: "sale", isRegex: false).matches("Flash SALE today"))
check(!XSpamShieldRule(pattern: "a.b", isRegex: false).matches("axb"))
check(XSpamShieldRule(pattern: "sale[0-9]+", isRegex: true).matches("SALE123"))
check(!XSpamShieldRule(pattern: "sale", isRegex: false, enabled: false).matches("sale"))
for pattern in ["", "[", "(a+)+$", "a|b", "a.*b.*c", #"\1"#, "a{99999}"] {
    check(!XSpamShieldRule.isValid(pattern, regex: true))
}
check(!XSpamShieldRule.isValid(String(repeating: "x", count: 257), regex: false))
let script = XSpamShieldWebPolicy.javaScript(guardLabel: "Guard", junkLabel: "Junk", hideLabel: "Block", undoLabel: "Undo", hiddenMessage: "Blocked", signInMessage: "Sign in", blockFailedMessage: "Failed")
print(Data(script.utf8).base64EncodedString())
`;
const result = spawnSync('swift', ['-'], { input: 'import Foundation\n' + rule + policy + checks, encoding: 'utf8', timeout: 120000 });
if (result.status !== 0) { process.stderr.write(result.stderr || 'Swift failed'); process.exit(1); }
const script = Buffer.from(result.stdout.trim(), 'base64').toString('utf8');
new Function(script);
if (script.includes('response.ok || response.status === 403')) throw Error('403 must not claim successful blocking');
if (!script.includes("type: 'settings'") || !script.includes("type: 'scan', handles, posts")) throw Error('Missing rule UI bridge');
console.log('PASS: literal/regex matching, disabled rules, unsafe patterns, limits, and injected JavaScript syntax');
