(() => {
  const translations = {
    "hero.summary": "Astra 将 Chromium 浏览、扩展程序、隐私控制和视觉 AI 助手统一在一个专注的原生 Mac 应用中。",
    "features.summary": "Astra 在应用内统一日常 Chromium 兼容性、扩展程序、视觉 AI 上下文和隐私控制。",
    "features.extensions.title": "扩展程序始终留在 Astra 内",
    "features.extensions.body": "安装扩展、查看图标、打开控制面板及完成安装引导时，不再跳出另一个 Chromium 浏览器窗口。",
    "features.privacy.title": "默认保护 WebRTC 隐私",
    "features.privacy.body": "阻止不经过代理的 WebRTC 直连；网站请求摄像头或麦克风时，必须由用户明确决定是否仅允许本次访问。",
    "features.fingerprintPrivacy.title": "跨维度浏览器指纹防护",
    "features.fingerprintPrivacy.body": "Astra 对 Canvas、WebGL 和 WebAudio 读取结果进行扰动，隐藏精确 GPU 信息，阻止直接 API 与字宽探针枚举受保护的本地及中文字体，并统一硬件与浏览器语言信号，同时保持标准媒体播放可用。",
    "features.visualContext.title": "视觉 AI 上下文",
    "features.visualContext.body": "可在提问区截取用户当前看到的网页渲染结果，包括标准视频在截图瞬间的画面，并可通过缩略图确认或删除。",
    "features.richAnswers.title": "丰富的技术内容渲染",
    "features.richAnswers.body": "AI 回复可在助手面板中渲染可横向滚动的 Markdown 表格、代码、数学 LaTeX 和化学公式，并兼容常见模型的公式包装格式。",
    "features.pageControl.title": "能理解并操作网页的 AI",
    "features.pageControl.body": "助手可检查当前标签页并执行经确认的浏览器操作，同时 Chromium 浏览体验始终内嵌在 Astra 中。",
    "features.youtube.title": "减少等待 YouTube 广告",
    "features.youtube.body": "YouTube 将当前播放标记为广告时，Astra 会临时使用 8 倍速，并在正片开始后恢复原播放速度。",
    "features.mediaCompatibility.title": "不离开 Astra 的视频兼容",
    "features.mediaCompatibility.body": "YouTube 保持 Chromium 的 VP9/AV1 播放路径；B 站、AcFun 以及主流大陆视频网站需要 H.264、AAC 或 HLS 时，则使用内嵌的系统媒体引擎。",
    "features.localMemory.title": "本地第二大脑",
    "features.localMemory.body": "Astra 将手动笔记和完整的用户/AI 对话保存到账号独立的 SQLite 向量索引，并镜像成可迁移的 Markdown 文件，在本机检索相关上下文。过期会话只有在摘要成功写回后才删除原记录。",
    "features.browserOwnership.title": "完整的默认浏览器设置",
    "features.browserOwnership.body": "账号设置会显示 Astra 是否同时接管 HTTP 与 HTTPS，并可请求将两种网页链接完整设为由 Astra 打开，同时避免重复的系统确认。",
    "download.summary": "Build 32 将失效的浏览器记忆地址升级为本地向量记忆第二大脑，并完善 HTTP 与 HTTPS 默认浏览器设置，同时保留 Build 31 的隐私、扩展、AI、WebRTC 防泄漏及视频兼容改进。DMG 已通过 Apple Developer ID 签名和 Apple 公证。"
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
