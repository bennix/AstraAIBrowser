(() => {
  const translations = {
    "hero.summary": "Astra 将 Chromium 浏览、扩展程序、隐私控制和视觉 AI 助手统一在一个专注的原生 Mac 应用中。",
    "features.summary": "Astra 在应用内统一日常 Chromium 兼容性、扩展程序、视觉 AI 上下文和隐私控制。",
    "features.extensions.title": "扩展程序始终留在 Astra 内",
    "features.extensions.body": "可直接从 Chrome 应用商店安装扩展，并在 Chromium 渲染的页面中保持扩展操作图标可见，全程不跳出另一个浏览器窗口。",
    "features.privacy.title": "默认保护 WebRTC 隐私",
    "features.privacy.body": "阻止不经过代理的 WebRTC 直连；网站请求摄像头或麦克风时，必须由用户明确决定是否仅允许本次访问。",
    "features.fingerprintPrivacy.title": "跨维度浏览器指纹防护",
    "features.fingerprintPrivacy.body": "Astra 对 Canvas、WebGL 和 WebAudio 读取结果进行扰动，隐藏精确 GPU 信息，阻止枚举受保护的本地及中文字体，并统一硬件与浏览器语言信号。Build 45 在中和字体测量探针的同时保留网页正常的字体样式赋值。",
    "features.visualContext.title": "视觉 AI 上下文",
    "features.visualContext.body": "可在提问区截取用户当前看到的网页渲染结果，包括标准视频在截图瞬间的画面，并可通过缩略图确认或删除。",
    "features.richAnswers.title": "丰富的技术内容渲染",
    "features.richAnswers.body": "AI 回复可在助手面板中渲染可横向滚动的 Markdown 表格、代码、数学 LaTeX 和化学公式，并兼容常见模型的公式包装格式。",
    "features.pageControl.title": "能理解并操作网页的 AI",
    "features.pageControl.body": "助手可检查当前标签页并执行经确认的浏览器操作，同时 Chromium 浏览体验始终内嵌在 Astra 中。",
    "features.youtube.title": "减少等待 YouTube 广告",
    "features.youtube.body": "YouTube 将当前播放标记为广告时，Astra 会临时使用 8 倍速，并在正片开始后恢复原播放速度。",
    "features.mediaCompatibility.title": "X 媒体、图片缩放与原生守护",
    "features.mediaCompatibility.body": "X 和 Twitter 使用持久化的系统 WebKit 会话，直接获得 macOS 的 H.264/AAC 播放能力。图片查看器提供可见的缩小按钮、100%–800% 滑块、放大按钮、实时百分比和重置按钮，同时支持触控板捏合、滚轮、双击缩放与拖动查看。Astra 还会在本机匹配公开垃圾账号数据库，且只有用户明确点击“守护”或“屏蔽”后才执行账号操作。",
    "features.localMemory.title": "本地第二大脑",
    "features.localMemory.body": "Astra 将笔记和完整的用户/AI 对话保存到账号独立的本地向量索引，并镜像成可迁移的 Markdown 文件，在本机检索相关上下文。记忆内容支持 Markdown、可横向滚动的表格、本地 LaTeX 数学及化学公式渲染，并可将单条或多条记忆导出为 Markdown 文件。过期会话会先完成摘要，再删除原记录。",
    "features.browserOwnership.title": "原生链接与语言集成",
    "features.browserOwnership.body": "通用设置可让 Astra 完整接管 HTTP 与 HTTPS。其他 Mac 应用打开的链接会进入 Astra 内嵌的 Chromium 标签页，网站检测到的浏览器语言也会与 Astra 界面语言保持一致。",
    "features.history.title": "完整保留浏览历史",
    "features.history.body": "Astra 将浏览历史保存在持久化 Chromium 配置中，可从原生“历史记录”菜单和“通用”设置查看或清除，也可按 Command-Y 打开完整记录。",
    "download.summary": "Build 60 支持 ZenMux 通过有次数限制的 Google、DuckDuckGo 搜索和公开网页抓取核验时效性信息。客户端提供的本地及 UTC 时间可稳定日期判断，检索内容始终按不可信数据处理，并阻止访问私有网络目标。DMG 已通过 Apple Developer ID 签名和 Apple 公证。"
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
