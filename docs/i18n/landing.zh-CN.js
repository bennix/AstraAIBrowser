(() => {
  const translations = {
    "hero.summary": "Astra 将 Chromium 浏览、扩展程序、隐私控制和视觉 AI 助手统一在一个专注的原生 Mac 应用中。",
    "features.summary": "Astra 在应用内统一日常 Chromium 兼容性、扩展程序、视觉 AI 上下文和隐私控制。",
    "features.extensions.title": "扩展程序始终留在 Astra 内",
    "features.extensions.body": "安装扩展、查看图标、打开控制面板及完成安装引导时，不再跳出另一个 Chromium 浏览器窗口。",
    "features.privacy.title": "默认保护 WebRTC 隐私",
    "features.privacy.body": "阻止不经过代理的 WebRTC 直连；网站请求摄像头或麦克风时，必须由用户明确决定是否仅允许本次访问。",
    "features.audioPrivacy.title": "防御静默音频指纹",
    "features.audioPrivacy.body": "防护在网页脚本运行前生效：随机化 WebAudio 指纹读取结果，并阻止零音量处理链长期占用 Mac 音频输出；标准视频和音频元素保持可用。",
    "features.visualContext.title": "视觉 AI 上下文",
    "features.visualContext.body": "可在提问区截取用户当前看到的网页渲染结果，包括标准视频在截图瞬间的画面，并可通过缩略图确认或删除。",
    "features.richAnswers.title": "丰富的技术内容渲染",
    "features.richAnswers.body": "AI 回复可在助手面板中渲染可横向滚动的 Markdown 表格、代码、数学 LaTeX 和化学公式，并兼容常见模型的公式包装格式。",
    "features.pageControl.title": "能理解并操作网页的 AI",
    "features.pageControl.body": "助手可检查当前标签页并执行经确认的浏览器操作，同时 Chromium 浏览体验始终内嵌在 Astra 中。",
    "features.youtube.title": "减少等待 YouTube 广告",
    "features.youtube.body": "YouTube 将当前播放标记为广告时，Astra 会临时使用 8 倍速，并在正片开始后恢复原播放速度。",
    "download.summary": "Build 28 修复 Grok 登录后因媒体兼容切换而丢失会话的问题，并保留 X OAuth 弹窗与原始页面的关联；现有 WebRTC 与静默音频指纹防护继续启用。DMG 已通过 Apple Developer ID 签名和 Apple 公证。"
  };

  const applyTranslations = () => {
    document.querySelectorAll("[data-zh-key]").forEach((element) => {
      const translation = translations[element.dataset.zhKey];
      if (translation) {
        element.textContent = translation;
      }
    });
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", applyTranslations, { once: true });
  } else {
    applyTranslations();
  }
})();
