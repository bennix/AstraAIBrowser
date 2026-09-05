(() => {
  const translations = {
    "hero.summary": "Astra 将 Chromium 浏览、扩展程序、隐私控制和视觉 AI 助手统一在一个专注的原生 Mac 应用中。",
    "features.summary": "Astra 在应用内统一日常 Chromium 兼容性、扩展程序、视觉 AI 上下文和隐私控制。",
    "features.extensions.title": "扩展程序始终留在 Astra 内",
    "features.extensions.body": "可直接从 Chrome 应用商店安装扩展，并在 Chromium 渲染的页面中保持扩展操作图标可见，全程不跳出另一个浏览器窗口。",
    "features.privacy.title": "语言与追踪隐私保持一致",
    "features.privacy.body": "原生界面保留用户选择的语言，网页对外语言信号则跟随公网出口 IPv4 所在国家；“勿追踪”默认开启，同时继续阻止不经过代理的 WebRTC 直连。",
    "features.fingerprintPrivacy.title": "兼顾安全验证的指纹隐私防护",
    "features.fingerprintPrivacy.body": "普通网页继续使用 Astra 的 Canvas、WebGL、WebAudio、GPU、字体、硬件与语言信号隐私防护；登录和安全验证路径使用 Chromium 原生表面，以提高滑块验证码的加载与校验一致性。",
    "features.visualContext.title": "视觉 AI 上下文",
    "features.visualContext.body": "可在提问区截取用户当前看到的网页渲染结果，包括标准视频在截图瞬间的画面，并可通过缩略图确认或删除。",
    "features.richAnswers.title": "丰富的技术内容渲染",
    "features.richAnswers.body": "AI 回复可在助手面板中渲染可横向滚动的 Markdown 表格、代码、数学 LaTeX 和化学公式，并兼容常见模型的公式包装格式。",
    "features.pageControl.title": "能理解并操作网页的 AI",
    "features.pageControl.body": "浏览器自动化可遍历可访问的同源框架，识别 contenteditable 与 designMode 富文本编辑器，将嵌套框架坐标转换到顶层视口，并在报告成功前验证输入内容确实保留。",
    "features.youtube.title": "减少等待 YouTube 广告",
    "features.youtube.body": "YouTube 将当前播放标记为广告时，Astra 会临时使用 8 倍速，并在正片开始后恢复原播放速度。",
    "features.mediaCompatibility.title": "X 媒体、图片缩放与原生守护",
    "features.mediaCompatibility.body": "X 和 Twitter 使用持久化的系统 WebKit 会话，直接获得 macOS 的 H.264/AAC 播放能力。图片查看器提供可见的缩小按钮、100%–800% 滑块、放大按钮、实时百分比和重置按钮，同时支持触控板捏合、滚轮、双击缩放与拖动查看。Astra 还会在本机匹配公开垃圾账号数据库，且只有用户明确点击“守护”或“屏蔽”后才执行账号操作。",
    "features.localMemory.title": "本地第二大脑",
    "features.localMemory.body": "Astra 将笔记和完整的用户/AI 对话保存到账号独立的本地向量索引，并镜像成可迁移的 Markdown 文件，在本机检索相关上下文。记忆内容支持 Markdown、可横向滚动的表格、本地 LaTeX 数学及化学公式渲染，并可将单条或多条记忆导出为 Markdown 文件。过期会话会先完成摘要，再删除原记录。",
    "features.browserOwnership.title": "原生链接与旧式 HTTP 兼容",
    "features.browserOwnership.body": "通用设置可让 Astra 完整接管 HTTP 与 HTTPS。其他 Mac 应用打开的网页链接会留在 Astra 内；网页中的腾讯会议等已安装应用链接会在确认后交给 macOS 打开；旧式 HTTP 页面则自动使用应用内兼容引擎。",
    "features.history.title": "完整保留浏览历史",
    "features.history.body": "Astra 将浏览历史保存在持久化 Chromium 配置中，可从原生“历史记录”菜单和“通用”设置查看或清除，也可按 Command-Y 打开完整记录。",
    "features.recentResearch.title": "口径安全的循证研究",
    "features.recentResearch.body": "ZenMux 在检索前先确定问题、对象清单、统计口径、时间规则、范围、排除项与目的。它优先使用主管机构和一手来源，保留官方原词及报告时点，禁止重叠账户加总，并输出可审计的对象对照表。",
    "features.immersiveTranslation.title": "双语沉浸式网页翻译",
    "features.immersiveTranslation.body": "在保留原文的同时，将网页可读内容逐段翻译并显示在原文下方。Astra 最多并发处理四个更小的 ZenMux 批次，每批完成后立即回填；一键即可恢复原页面。",
    "features.youtubeDigest.title": "重证据的 YouTube 视频摘要",
    "features.youtubeDigest.body": "YouTube 视频页会显示上下文侧边栏入口，使用可用字幕或视听分析生成覆盖完整视频的结构化摘要，包括时间章节、可核对引语、核心论证和明确标注的不确定性。",
    "features.vocabularyBook.title": "划词翻译与持久词汇本",
    "features.vocabularyBook.body": "在网页上选中文本后，可从右键菜单翻译内容或查询单词。指针锚定卡片会就地更新结果，支持复制译文，并可将词典结果保存到可搜索、可导出 Markdown 的持久词汇本。",
    "features.xBookmarkArchive.title": "可控制的 X 书签全文归档",
    "features.xBookmarkArchive.body": "Astra 直接在当前已登录的 X 标签页中归档书签，不打开后台标签页。采集可随时暂停、继续或停止，并保留详细正文、引用、图片资源与视频贴文链接；结果可直接留存为本地 Markdown，也可在明确确认后交给 ZenMux 分类整理。",
    "features.signedUpdates.title": "GitHub 签名在线更新",
    "features.signedUpdates.body": "打开“关于 Astra Browser”即会检查 GitHub Releases 更新。更新源与 DMG 均使用 Sparkle Ed25519 签名校验，并继续验证 Apple 代码签名。",
    "features.promptLibrary.title": "本地提示词管理器",
    "features.promptLibrary.body": "可将网页划词内容保存为提示词，并自动收藏已发送的提示词。所有内容仅保存在本机，支持按任务分类、搜索、复用、编辑、批量删除及 JSON 导入导出。",
    "download.summary": "Build 90 阻止过期的 Chromium 焦点、排队中的标签选择以及迟到的首屏回调覆盖用户最新的标签选择，并在动态网页重绘时保持已翻译文本。DMG 已通过 Apple Developer ID 签名和 Apple 公证。"
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
