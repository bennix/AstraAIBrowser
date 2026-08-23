(() => {
  const translations = {
    "hero.summary": "Astra 将 Chromium 浏览、扩展程序、隐私控制和视觉 AI 助手统一在一个专注的原生 Mac 应用中。",
    "features.summary": "Astra 在应用内统一日常 Chromium 兼容性、扩展程序、视觉 AI 上下文和隐私控制。",
    "features.extensions.title": "扩展程序始终留在 Astra 内",
    "features.extensions.body": "安装扩展、查看图标、打开控制面板及完成安装引导时，不再跳出另一个 Chromium 浏览器窗口。",
    "features.privacy.title": "默认保护 WebRTC 隐私",
    "features.privacy.body": "阻止不经过代理的 WebRTC 直连；网站请求摄像头或麦克风时，必须由用户明确决定是否仅允许本次访问。",
    "features.visualContext.title": "视觉 AI 上下文",
    "features.visualContext.body": "提问时可附带当前浏览器可见区域截图，并支持最多五张可删除的粘贴或上传图片。",
    "features.richAnswers.title": "丰富的技术内容渲染",
    "features.richAnswers.body": "AI 回复可在助手面板中正确渲染 Markdown、代码、表格、数学 LaTeX 和化学公式。",
    "features.pageControl.title": "能理解并操作网页的 AI",
    "features.pageControl.body": "助手可检查当前标签页并执行经确认的浏览器操作，同时 Chromium 浏览体验始终内嵌在 Astra 中。",
    "features.youtube.title": "减少等待 YouTube 广告",
    "features.youtube.body": "YouTube 将当前播放标记为广告时，Astra 会临时使用 8 倍速，并在正片开始后恢复原播放速度。",
    "download.summary": "Build 24 让扩展程序及安装引导页面始终留在 Astra 内，阻止可能泄露真实 IP 的 WebRTC 路径，并在网页旁保留完整视觉 AI 工作区。DMG 已通过 Apple Developer ID 签名和 Apple 公证。"
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
