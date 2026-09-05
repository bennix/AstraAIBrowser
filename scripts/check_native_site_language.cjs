// Verify the destination policy without launching the Chromium test host.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'Vendor/CefSwift/Sources/CefKit/BrowserClient.swift'), 'utf8');
const policy = source.slice(source.indexOf('public enum CefNativeSiteLanguagePolicy'), source.indexOf('/// Process-wide request policy'));
const checks = `
for address in ["https://elearning.fudan.edu.cn", "https://developer.amd.com.cn", "https://www.baidu.com", "https://www.bilibili.com", "https://WWW.ZHIHU.COM."] {
    precondition(CefNativeSiteLanguagePolicy.prefersChinese(URL(string: address)), address)
}
for address in ["https://google.com", "https://claude.ai", "https://example.com/cn", "https://baidu.com.example.org", "https://notbaidu.com", "file:///site.cn", "https://example.com/?next=https://baidu.com"] {
    precondition(!CefNativeSiteLanguagePolicy.prefersChinese(URL(string: address)), address)
}
precondition(!CefNativeSiteLanguagePolicy.prefersChinese(nil))
print("PASS: native Chinese destinations, boundary matching, and outward-language exclusions")
`;
const result = spawnSync('swift', ['-'], { input: 'import Foundation\n' + policy + checks, encoding: 'utf8' });
process.stdout.write(result.stdout || '');
process.stderr.write(result.stderr || '');
if (result.error) throw result.error;
process.exit(result.status ?? 1);
