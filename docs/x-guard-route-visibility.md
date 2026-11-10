# X Guard route visibility

X Guard scans posts and shows an in-page status pill. The pill belongs on X feeds, post pages, and profiles. X Chat, Grok, and sign-in onboarding own their page controls. Guard must hide its status pill and skip post scanning on these routes, including nested routes, while leaving X itself and the signed-in WebKit session intact. Show Guard only on recognized content routes so new X workspace paths cannot accidentally inherit the fixed overlay.

X is a single-page application. The injected script must re-evaluate the current path on every scheduled scan so a transition from a feed to Chat, Grok, or `/i/jf/onboarding` hides the pill, and a transition back restores it. It must not change X network traffic. Acceptance: open X home and see Guard; enter Grok and confirm New Chat remains clickable; enter X Chat and the sign-in flow and confirm no Guard pill; return home and see Guard again.
