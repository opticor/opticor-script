// ==UserScript==
// @name         YouTube 字幕下载器
// @name:zh-CN   YouTube 字幕下载器
// @name:en      YouTube Subtitle Downloader (Fixed Compatibility Ver. 1.6)
// @namespace    http://tampermonkey.net/
// @version      1.6
// @description  在YouTube视频页面添加按钮以下载字幕(TXT/SRT)。修复404错误，尝试直接使用baseUrl。
// @description:zh-CN 在YouTube视频页面添加按钮以下载字幕(TXT/SRT)。修复因URL修改导致的404错误，优化数据获取逻辑。
// @description:en Adds a button to YouTube video pages to download subtitles (TXT/SRT). Fixes 404 error by attempting to use baseUrl directly.
// @author       AI
// @match        *://www.youtube.com/watch*
// @icon         https://www.google.com/s2/favicons?sz=64&domain=youtube.com
// @grant        GM_xmlhttpRequest
// @grant        GM_download
// @grant        GM_addStyle
// @connect      www.youtube.com
// @license      MIT
// ==/UserScript==

(function() {
    'use strict';

    // --- 配置 ---
    const BUTTON_TEXT = "下载字幕";
    const MENU_TITLE_LANGUAGE = "选择语言:";
    const MENU_TITLE_FORMAT = "选择格式:";
    const DOWNLOAD_TXT_TEXT = "下载 TXT";
    const DOWNLOAD_SRT_TEXT = "下载 SRT";
    const DOWNLOADING_TEXT = "正在下载...";
    const NO_SUBTITLES_TEXT = "当前视频没有可用字幕。";
    const NO_DATA_FOUND_TEXT = "无法获取视频数据 (PlayerResponse)，请稍后重试或刷新页面。";
    const NO_CAPTIONS_IN_DATA_TEXT = "在视频数据中未找到字幕轨道信息。";
    const DOWNLOAD_FAILED_TEXT = "下载失败，请检查控制台获取错误信息。";
    const DOWNLOAD_SUCCESS_TEXT = "下载成功！"; // (可选, 目前未使用)
    const RETRY_INTERVAL = 1000; // 初始化重试间隔 (毫秒)
    const MAX_RETRIES = 15; // 初始化最大重试次数
    const GET_DATA_DELAY = 200; // 在按钮点击后延迟多少毫秒获取数据 (略微增加延迟)

    // --- 样式 ---
    GM_addStyle(`
        #yt-subtitle-downloader-menu {
            position: absolute; /* 使用 absolute 方便定位 */
            background-color: var(--yt-spec-menu-background, #282828);
            border: 1px solid var(--yt-spec-menu-border-color, #3f3f3f);
            border-radius: 12px; /* 圆角 */
            box-shadow: 0 4px 8px rgba(0, 0, 0, 0.2); /* 阴影 */
            padding: 8px 0;
            z-index: 2500; /* 确保在顶层 */
            min-width: 150px;
            color: var(--yt-spec-text-primary, #fff);
            font-size: 14px;
            display: none; /* 默认隐藏 */
            font-family: "Roboto","Arial",sans-serif; /* YouTube 字体 */
        }
        #yt-subtitle-downloader-menu h3 {
            padding: 8px 16px;
            margin: 0;
            font-size: 1.1em;
            font-weight: 500;
            border-bottom: 1px solid var(--yt-spec-menu-border-color, #3f3f3f);
            margin-bottom: 8px;
            color: var(--yt-spec-text-secondary, #aaa);
        }
        #yt-subtitle-downloader-menu ul {
            list-style: none;
            padding: 0;
            margin: 0;
            max-height: 250px; /* 限制最大高度，超出则滚动 */
            overflow-y: auto; /* 自动显示滚动条 */
        }
        #yt-subtitle-downloader-menu li {
            padding: 8px 16px;
            cursor: pointer;
            color: var(--yt-spec-text-primary, #fff);
        }
        #yt-subtitle-downloader-menu li:hover {
            background-color: var(--yt-spec-badge-chip-background-hover, rgba(255, 255, 255, 0.2)); /* 悬停效果 */
        }
        #yt-subtitle-downloader-button {
            /* 按钮样式，尽量模仿 YouTube 现有按钮 */
            border-radius: 18px;
            padding: 0 16px;
            height: 36px;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            box-sizing: border-box;
            cursor: pointer;
            font-family: "Roboto","Arial",sans-serif;
            font-size: 14px;
            font-weight: 500;
            white-space: nowrap; /* 防止文字换行 */
            margin-left: 8px; /* 与左侧按钮的间距 */
            background-color: var(--yt-spec-badge-chip-background, rgba(255, 255, 255, 0.1)); /* 背景色 */
            color: var(--yt-spec-text-primary, #fff); /* 文字颜色 */
            border: none; /* 无边框 */
            transition: background-color .3s ease; /* 背景色过渡动画 */
        }
        #yt-subtitle-downloader-button:hover {
             background-color: var(--yt-spec-badge-chip-background-hover, rgba(255, 255, 255, 0.2)); /* 悬停背景色 */
        }
        #yt-subtitle-downloader-button:focus {
            outline: none; /* 移除焦点时的外框 */
        }
        /* 自定义滚动条样式 (可选) */
        #yt-subtitle-downloader-menu ul::-webkit-scrollbar { width: 8px; }
        #yt-subtitle-downloader-menu ul::-webkit-scrollbar-track { background: var(--yt-spec-menu-background, #282828); border-radius: 4px; }
        #yt-subtitle-downloader-menu ul::-webkit-scrollbar-thumb { background-color: var(--yt-spec-text-secondary, #aaa); border-radius: 4px; border: 2px solid var(--yt-spec-menu-background, #282828); }
    `);

    // --- 全局变量 ---
    let downloadButton = null; // 下载按钮元素
    let downloadMenu = null; // 下载菜单元素
    let currentCaptionTracks = []; // 当前视频可用的字幕轨道信息
    let selectedTrack = null; // 用户选择的字幕轨道
    let initRetryCount = 0; // 初始化重试计数
    let initInterval = null; // 初始化重试的定时器
    let observer = null; // MutationObserver 实例，用于检测页面变化

    // --- 辅助函数 ---

    /**
     * 清理文件名中的非法字符
     * @param {string} name 原始文件名 (通常是视频标题)
     * @returns {string} 清理后的安全文件名
     */
    function sanitizeFilename(name) {
        if (!name || typeof name !== 'string') return "youtube_subtitles";
        // 移除 Windows 和 Linux 文件名中的非法字符，并将控制字符替换为下划线
        return name.replace(/[\\/:*?"<>|]/g, '_').replace(/[\x00-\x1f\x7f]/g, '_').substring(0, 200); // 限制最大长度
    }

    /**
     * 将秒数格式化为 SRT 时间戳 (时:分:秒,毫秒)
     * @param {number} seconds 秒数
     * @returns {string} SRT 格式的时间字符串
     */
    function formatSRTTime(seconds) {
        const date = new Date(0);
        date.setSeconds(seconds);
        // 提取 ISO 时间字符串的小时、分钟、秒和毫秒部分
        const timeString = date.toISOString().substr(11, 12);
        // 将小数点替换为逗号，符合 SRT 标准
        return timeString.replace('.', ',');
    }

    /**
     * 解析 YouTube 返回的 XML 格式字幕数据
     * @param {string} subtitleData XML 格式的字幕文本
     * @returns {Array|null} 解析后的字幕对象数组 [{start, end, text}, ...] 或 null (如果解析失败)
     */
    function parseSubtitleXML(subtitleData) {
        try {
            const parser = new DOMParser();
            const xmlDoc = parser.parseFromString(subtitleData, "text/xml");
            const subtitles = [];

            // 检查是否有解析错误 (常见的错误是返回HTML错误页而不是XML)
            const parseError = xmlDoc.querySelector('parsererror');
            if (parseError) {
                console.error("Subtitle Downloader: XML 解析错误:", parseError.textContent);
                console.error("Subtitle Downloader: 收到的原始数据:", subtitleData.substring(0, 500) + "..."); // 显示部分原始数据帮助诊断
                return null;
            }

            // 优先尝试 <text> 标签 (常见于 ASR 自动生成字幕)
            const textNodes = xmlDoc.getElementsByTagName('text');
            if (textNodes && textNodes.length > 0) {
                console.log("Subtitle Downloader: 尝试使用 <text> 标签解析字幕。");
                for (let i = 0; i < textNodes.length; i++) {
                    const node = textNodes[i];
                    const start = parseFloat(node.getAttribute('start'));
                    const duration = parseFloat(node.getAttribute('dur'));
                    // 确保 start 和 duration 是有效数字
                    if (isNaN(start) || isNaN(duration)) continue;
                    const end = start + duration;
                    // 处理 HTML 实体解码 (例如 & -> &, ' -> ')
                    const tempDiv = document.createElement('div');
                    tempDiv.innerHTML = node.textContent || node.innerText || ""; // 使用 innerHTML 进行解码
                    const text = (tempDiv.textContent || tempDiv.innerText || "").trim(); // 获取纯文本并去除首尾空格
                    if (text) { // 只添加有内容的字幕
                        subtitles.push({ start: start, end: end, text: text });
                    }
                }
                if (subtitles.length > 0) {
                    console.log(`Subtitle Downloader: 使用 <text> 标签成功解析了 ${subtitles.length} 条字幕。`);
                    return subtitles;
                }
            }

            // 如果没有 <text> 标签或解析无结果，尝试 <p> 标签 (常见于旧格式或某些手动上传字幕)
            const pNodes = xmlDoc.getElementsByTagName('p');
            if (pNodes && pNodes.length > 0) {
                console.log("Subtitle Downloader: 未找到有效的 <text> 标签或解析无内容，尝试使用 <p> 标签解析字幕。");
                // 注意：<p> 标签的时间单位通常是毫秒 (t=start_ms, d=duration_ms)
                for (let i = 0; i < pNodes.length; i++) {
                    const node = pNodes[i];
                    const startMillis = node.getAttribute('t');
                    const durationMillis = node.getAttribute('d');
                    // 检查属性是否存在
                    if (startMillis === null || durationMillis === null) continue;
                    const start = parseFloat(startMillis) / 1000.0; // 转换为秒
                    const duration = parseFloat(durationMillis) / 1000.0; // 转换为秒
                    // 确保 start 和 duration 是有效数字
                    if (isNaN(start) || isNaN(duration)) continue;
                    const end = start + duration;

                    // 处理文本内容，可能包含 <s> 标签或其他格式
                    let textContent = "";
                    // 检查是否有子节点，并且第一个子节点是 <s> 标签 (有时 YouTube 会这样嵌套)
                    if (node.childNodes && node.childNodes.length > 0) {
                        if (node.childNodes.length === 1 && node.childNodes[0].nodeType === Node.ELEMENT_NODE && node.childNodes[0].tagName?.toLowerCase() === 's') {
                            textContent = node.childNodes[0].textContent || ''; // 取 <s> 标签内的文本
                        } else {
                            textContent = node.textContent || ''; // 否则取 <p> 标签内的所有文本
                        }
                    } else {
                        textContent = node.textContent || ''; // 没有子节点，直接取文本
                    }

                    // 使用与上面相同的方法解码 HTML 实体
                    const tempDiv = document.createElement('div');
                    tempDiv.innerHTML = textContent;
                    const text = (tempDiv.textContent || tempDiv.innerText || "").trim();
                    if (text) { // 只添加有内容的字幕
                        subtitles.push({ start: start, end: end, text: text });
                    }
                }
                if (subtitles.length > 0) {
                    console.log(`Subtitle Downloader: 使用 <p> 标签成功解析了 ${subtitles.length} 条字幕。`);
                    return subtitles;
                }
            }

            // 如果两种标签都解析失败或没有找到
            console.warn("Subtitle Downloader: 无法从 XML 数据中解析出任何字幕内容 (既没有有效的 <text> 也没有 <p> 标签)。");
            return null; // 返回 null 表示解析失败

        } catch (e) {
            console.error("Subtitle Downloader: 解析字幕 XML 时发生 JavaScript 错误:", e);
            console.error("Subtitle Downloader: 发生错误的原始数据:", subtitleData.substring(0, 500) + "...");
            return null; // 解析出错返回 null
        }
    }

    /**
     * 将解析后的字幕对象数组转换为 TXT 格式字符串
     * @param {Array} parsedSubtitles 解析后的字幕对象数组
     * @returns {string} TXT 格式的字幕文本
     */
    function convertToTXT(parsedSubtitles) {
        if (!parsedSubtitles || parsedSubtitles.length === 0) return "";
        // 提取每条字幕的文本内容，过滤掉空文本，然后用换行符连接
        return parsedSubtitles.map(sub => sub.text).filter(text => text).join('\n');
    }

    /**
     * 将解析后的字幕对象数组转换为 SRT 格式字符串
     * @param {Array} parsedSubtitles 解析后的字幕对象数组
     * @returns {string} SRT 格式的字幕文本
     */
    function convertToSRT(parsedSubtitles) {
        if (!parsedSubtitles || parsedSubtitles.length === 0) return "";
        let srtContent = "";
        let srtIndex = 1;
        parsedSubtitles.forEach((sub) => {
            // 确保字幕有文本内容才添加到 SRT 文件中
            if (!sub.text) return;
            srtContent += srtIndex + '\n'; // 序号
            srtContent += formatSRTTime(sub.start) + ' --> ' + formatSRTTime(sub.end) + '\n'; // 时间戳
            srtContent += sub.text + '\n\n'; // 字幕内容和空行
            srtIndex++;
        });
        return srtContent;
    }

    /**
     * 获取当前视频的标题，用于生成默认文件名
     * @returns {string} 清理过的视频标题
     */
    function getVideoTitle() {
        let title = "youtube_subtitles"; // 默认标题
        try {
            // 优先尝试从 Player Response 获取，信息最准确
            const playerResponse = getPlayerResponseData();
            if (playerResponse?.videoDetails?.title) {
                title = playerResponse.videoDetails.title;
                console.log("Subtitle Downloader: 从 Player Response 获取标题:", title);
            } else {
                // 备选方案：从 DOM 中查找 H1 标题
                const h1Title = document.querySelector('h1.ytd-watch-metadata yt-formatted-string, h1.title yt-formatted-string'); // 兼容新旧版选择器
                if (h1Title?.textContent) {
                    title = h1Title.textContent.trim();
                    console.log("Subtitle Downloader: 从 H1 元素获取标题:", title);
                } else {
                    // 再次备选：从 meta 标签获取
                    const metaTitle = document.querySelector('meta[name="title"]');
                    if (metaTitle?.content) {
                        title = metaTitle.content;
                        console.log("Subtitle Downloader: 从 meta[name='title'] 获取标题:", title);
                    } else if (document.title) { // 最后备选：使用页面标题
                        // 移除 YouTube 后缀
                        title = document.title.replace(/ - YouTube$/, '').trim();
                        console.log("Subtitle Downloader: 从 document.title 获取标题:", title);
                    }
                }
            }
        } catch (e) {
            console.warn("Subtitle Downloader: 获取视频标题时出错:", e);
        }
        // 清理文件名并返回
        return sanitizeFilename(title);
    }

    /**
     * 触发文件下载
     * @param {string} content 文件内容
     * @param {string} filename 文件名
     */
    function triggerDownload(content, filename) {
        console.log(`Subtitle Downloader: 准备下载文件: ${filename}`);
        try {
            // 移除可能存在的 BOM (Byte Order Mark)
            const cleanedContent = content.charCodeAt(0) === 0xFEFF ? content.slice(1) : content;
            // 使用 GM_download 进行下载
            GM_download({
                url: 'data:text/plain;charset=utf-8,' + encodeURIComponent(cleanedContent), // 创建 Data URL
                name: filename, // 下载的文件名
                saveAs: true, // 弹出另存为对话框
                onerror: (err) => {
                    console.error("Subtitle Downloader: GM_download 失败:", err);
                    alert(DOWNLOAD_FAILED_TEXT + "\n错误详情请查看控制台。");
                    hideMenu(); // 下载失败也隐藏菜单
                },
                onload: () => {
                    console.log("Subtitle Downloader: GM_download 已成功启动下载。");
                    // alert(DOWNLOAD_SUCCESS_TEXT); // 可以取消注释以显示成功提示
                    hideMenu(); // 下载成功后隐藏菜单
                }
            });
        } catch (e) {
            console.error("Subtitle Downloader: 调用 GM_download 时发生错误:", e);
            // GM_download 可能在某些环境下不可用或被阻止，尝试使用 Blob URL 作为备选方案
            try {
                console.log("Subtitle Downloader: 尝试使用 Blob URL 回退方案进行下载...");
                const blob = new Blob([content], { type: 'text/plain;charset=utf-8' });
                const url = URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url;
                a.download = filename;
                document.body.appendChild(a); // 需要添加到 DOM 中才能触发点击
                a.click();
                document.body.removeChild(a); // 点击后移除
                URL.revokeObjectURL(url); // 释放内存
                console.log("Subtitle Downloader: Blob URL 下载已启动。");
                hideMenu();
            } catch (fallbackError) {
                console.error("Subtitle Downloader: Blob URL 回退方案也失败了:", fallbackError);
                alert(DOWNLOAD_FAILED_TEXT + "\nGM_download 和备选方案均失败，请检查控制台。");
                hideMenu();
            }
        }
    }

    /**
     * 获取字幕数据并根据选定格式进行下载
     * @param {'txt' | 'srt'} format 下载格式
     */
    function fetchAndDownload(format) {
        if (!selectedTrack?.url) {
            console.error("Subtitle Downloader: 没有选中的轨道或选中的轨道缺少 URL。");
            alert(DOWNLOAD_FAILED_TEXT + " (内部错误：未选择有效轨道)");
            hideMenu();
            return;
        }

        showStatus(DOWNLOADING_TEXT); // 在菜单中显示正在下载

        // --- 关键修复：直接使用 baseUrl ---
        // 不再强制添加 fmt=xml 或 type=track，假设 YouTube 提供的 URL 是完整的
        const url = selectedTrack.url;
        // ---------------------------------

        const langCode = selectedTrack.langCode;
        const langName = selectedTrack.name;

        console.log(`Subtitle Downloader: 正在为 [${langName} (${langCode})] 请求字幕数据...`);
        console.log(`Subtitle Downloader: 请求 URL: ${url}`); // 打印将要请求的 URL

        GM_xmlhttpRequest({
            method: "GET",
            url: url,
            responseType: 'text', // 明确需要文本响应
            timeout: 15000, // 设置 15 秒超时
            headers: { // 可以添加一些常见的请求头，模拟浏览器行为，有时有助于解决 403/404
                'Accept': 'text/xml,application/xml,*/*', // 接受 XML
                // 'User-Agent': navigator.userAgent // (可选) 模拟浏览器 User-Agent
            },
            onload: function(response) {
                console.log(`Subtitle Downloader: 请求完成，状态码: ${response.status}`);
                // console.log("Subtitle Downloader: 响应头信息:", response.responseHeaders); // (调试用) 查看响应头
                // console.log("Subtitle Downloader: 收到的原始响应数据 (前 500 字符):", response.responseText.substring(0, 500)); // (调试用)

                if (response.status >= 200 && response.status < 300) {
                    const rawData = response.responseText;
                    if (!rawData || rawData.trim().length === 0) {
                        console.warn("Subtitle Downloader: 收到的字幕数据为空。");
                        alert("获取成功，但字幕文件内容为空。这可能是 YouTube 的问题。");
                        hideMenu();
                        return;
                    }

                    // 解析 XML 数据
                    const parsedSubs = parseSubtitleXML(rawData);

                    // 检查解析结果
                    if (!parsedSubs) {
                        console.error("Subtitle Downloader: 无法解析字幕数据。请检查控制台中的 XML 解析错误。");
                        alert(DOWNLOAD_FAILED_TEXT + " (无法解析字幕 XML 数据，可能是格式错误或返回了非 XML 内容)");
                        hideMenu();
                        return;
                    }
                    if (parsedSubs.length === 0) {
                        // 解析成功但没有内容 (这在某些空字幕文件中可能发生)
                        console.warn("Subtitle Downloader: 字幕文件解析成功，但内容为空。");
                        alert("下载成功，但该字幕轨道似乎不包含任何文本内容。");
                        hideMenu();
                        return;
                    }

                    // 根据选择的格式转换数据
                    let fileContent = "";
                    let fileExtension = format;

                    if (format === 'txt') {
                        fileContent = convertToTXT(parsedSubs);
                    } else if (format === 'srt') {
                        fileContent = convertToSRT(parsedSubs);
                    } else {
                        console.error("Subtitle Downloader: 无效的下载格式:", format);
                        alert(DOWNLOAD_FAILED_TEXT + " (内部错误：无效格式)");
                        hideMenu();
                        return;
                    }

                    // 获取视频标题并生成文件名
                    const videoTitle = getVideoTitle();
                    const filename = `${videoTitle}.${langCode}.${fileExtension}`;

                    // 触发下载
                    triggerDownload(fileContent, filename);

                } else {
                    // 处理 HTTP 错误 (包括 404)
                    console.error(`Subtitle Downloader: 获取字幕失败。HTTP 状态码: ${response.status}`, response);
                    alert(DOWNLOAD_FAILED_TEXT + ` (服务器错误: ${response.status})`);
                    // 可以在这里添加一些针对特定状态码的提示，例如：
                    if (response.status === 404) {
                        console.error("Subtitle Downloader: 收到 404 (Not Found)，可能是 URL 已失效或 YouTube API 变更。");
                        alert("无法找到字幕资源 (404)。这可能是因为链接已过期或 YouTube 更改了规则。请尝试刷新页面后再试。");
                    } else if (response.status === 403) {
                        console.error("Subtitle Downloader: 收到 403 (Forbidden)，可能是权限问题或缺少必要的请求头。");
                        alert("无权访问字幕资源 (403)。请确保你登录了 YouTube 并且没有使用可能干扰请求的扩展。");
                    }
                    hideMenu();
                }
            },
            onerror: function(error) {
                console.error("Subtitle Downloader: 请求字幕时发生网络错误:", error);
                alert(DOWNLOAD_FAILED_TEXT + " (网络错误，请检查网络连接和控制台)");
                hideMenu();
            },
            ontimeout: function() {
                console.error("Subtitle Downloader: 请求字幕超时。");
                alert(DOWNLOAD_FAILED_TEXT + " (请求超时，可能是网络缓慢或服务器无响应)");
                hideMenu();
            }
        });
    }

    /**
     * 在菜单中显示状态信息 (如 "正在下载...")
     * @param {string} text 要显示的状态文本
     */
    function showStatus(text) {
        if (downloadMenu) {
            // 清空菜单并显示状态文本
            downloadMenu.innerHTML = `<h3 style="text-align: center; padding: 16px;">${text}</h3>`;
            positionMenu(); // 重新定位菜单
            downloadMenu.style.display = 'block'; // 确保菜单可见
        }
    }

    /**
     * 显示语言选择菜单
     */
    function showLanguageMenu() {
        if (!downloadMenu) return;
        downloadMenu.innerHTML = ''; // 清空旧内容

        // 创建标题
        const title = document.createElement('h3');
        title.textContent = MENU_TITLE_LANGUAGE;
        downloadMenu.appendChild(title);

        // 创建列表
        const list = document.createElement('ul');
        if (currentCaptionTracks.length === 0) {
            // 如果没有找到字幕轨道
            const noSubsItem = document.createElement('li');
            noSubsItem.textContent = NO_SUBTITLES_TEXT;
            noSubsItem.style.cursor = 'default'; // 设置为不可点击样式
            noSubsItem.style.color = 'var(--yt-spec-text-secondary, #aaa)'; // 灰色显示
            list.appendChild(noSubsItem);
        } else {
            // 遍历找到的字幕轨道并创建列表项
            currentCaptionTracks.forEach(track => {
                const listItem = document.createElement('li');
                let trackName = track.name; // 轨道名称 (如 "中文（中国）")
                // 添加额外信息，如是否为自动生成或可翻译
                if (track.kind === 'asr') trackName += ' (自动生成)'; // ASR: Automatic Speech Recognition
                // (注意: isTranslatable 属性在简单的轨道列表中可能不直接可用，需要从更详细的数据源获取，
                // 但如果 playerResponse 中包含，可以加上)
                // else if (track.isTranslatable) trackName += ' (可翻译)';

                listItem.textContent = trackName;
                // 将轨道信息存储在 dataset 中，方便后续使用
                listItem.dataset.langCode = track.langCode;
                listItem.dataset.langName = track.name;
                listItem.dataset.url = track.url; // 存储原始 URL
                listItem.dataset.kind = track.kind || ''; // 存储类型
                listItem.dataset.isTranslatable = track.isTranslatable || 'false'; // 存储是否可翻译

                // 为每个语言项添加点击事件监听器
                listItem.addEventListener('click', () => {
                    // 点击后，将当前选中的轨道信息保存到全局变量
                    selectedTrack = track;
                    console.log("Subtitle Downloader: 用户选择了轨道:", selectedTrack);
                    // 显示格式选择菜单
                    showFormatMenu();
                });
                list.appendChild(listItem);
            });
        }
        downloadMenu.appendChild(list);

        positionMenu(); // 定位菜单
        downloadMenu.style.display = 'block'; // 显示菜单
    }

    /**
     * 显示格式选择菜单 (TXT / SRT)
     */
    function showFormatMenu() {
        if (!downloadMenu || !selectedTrack) return; // 必须先选择了语言轨道
        downloadMenu.innerHTML = ''; // 清空旧内容

        // 创建标题，显示已选语言
        const title = document.createElement('h3');
        title.textContent = `语言: ${selectedTrack.name}${selectedTrack.kind === 'asr' ? ' (自动)' : ''} - ${MENU_TITLE_FORMAT}`;
        downloadMenu.appendChild(title);

        // 创建格式列表
        const list = document.createElement('ul');

        // TXT 格式选项
        const txtItem = document.createElement('li');
        txtItem.textContent = DOWNLOAD_TXT_TEXT;
        txtItem.addEventListener('click', () => fetchAndDownload('txt')); // 点击下载 TXT
        list.appendChild(txtItem);

        // SRT 格式选项
        const srtItem = document.createElement('li');
        srtItem.textContent = DOWNLOAD_SRT_TEXT;
        srtItem.addEventListener('click', () => fetchAndDownload('srt')); // 点击下载 SRT
        list.appendChild(srtItem);

        downloadMenu.appendChild(list);
        positionMenu(); // 定位菜单
        downloadMenu.style.display = 'block'; // 显示菜单
    }

    /**
     * 定位菜单，使其出现在按钮下方，并处理边界情况
     */
    function positionMenu() {
        if (!downloadButton || !downloadMenu) return;
        const buttonRect = downloadButton.getBoundingClientRect(); // 获取按钮位置和尺寸

        // 初始定位：按钮正下方，考虑页面滚动
        let top = buttonRect.bottom + window.scrollY + 5; // 按钮底部 + 滚动偏移 + 5px间距
        let left = buttonRect.left + window.scrollX; // 按钮左侧 + 滚动偏移

        downloadMenu.style.top = `${top}px`;
        downloadMenu.style.left = `${left}px`;
        downloadMenu.style.display = 'block'; // 先设置为 block 以便获取尺寸

        // 检查并调整边界
        const menuRect = downloadMenu.getBoundingClientRect(); // 获取菜单位置和尺寸
        const viewportWidth = window.innerWidth;
        const viewportHeight = window.innerHeight;

        // 如果菜单右侧超出视口
        if (menuRect.right > viewportWidth - 10) { // 留 10px 边距
            left = viewportWidth - menuRect.width - 10 + window.scrollX; // 右对齐
            downloadMenu.style.left = `${left}px`;
        }
        // 如果菜单左侧超出视口 (不太可能，但以防万一)
        if (menuRect.left < 10 + window.scrollX) {
            left = 10 + window.scrollX; // 左对齐
            downloadMenu.style.left = `${left}px`;
        }
        // 如果菜单底部超出视口
        if (menuRect.bottom > viewportHeight - 10 + window.scrollY) {
            top = buttonRect.top + window.scrollY - menuRect.height - 5; // 尝试放到按钮上方
            // 如果放到上方后，顶部又超出视口 (说明按钮在页面顶部附近且菜单很高)
            if (top < 10 + window.scrollY) {
                top = buttonRect.bottom + window.scrollY + 5; // 还是放回下方 (可能部分被遮挡)
            }
            downloadMenu.style.top = `${top}px`;
        }
        // 设置最终位置后，再次确保菜单是显示的 (虽然前面设置过，但以防万一)
        downloadMenu.style.display = 'block';
    }

    /**
     * 隐藏下载菜单
     */
    function hideMenu() {
        if (downloadMenu) downloadMenu.style.display = 'none';
        selectedTrack = null; // 清除选中的轨道
    }

    /**
     * 尝试获取 YouTube 页面中的 Player Response 数据
     * 这是获取视频元数据（包括字幕信息）的关键步骤
     * @returns {object|null} Player Response 对象或 null (如果找不到)
     */
    function getPlayerResponseData() {
        console.log("Subtitle Downloader: 开始尝试获取 Player Response 数据...");

        // 方法 0: 检查全局变量 ytplayer (如果 YouTube 播放器已完全初始化)
        try {
            if (window.ytplayer?.config?.args?.raw_player_response) {
                console.log("Subtitle Downloader: 方法 0 成功 - window.ytplayer.config.args.raw_player_response");
                return window.ytplayer.config.args.raw_player_response;
            }
            if (window.ytplayer?.bootstrapPlayerResponse) { // 有时在这里
                console.log("Subtitle Downloader: 方法 0 成功 - window.ytplayer.bootstrapPlayerResponse");
                return window.ytplayer.bootstrapPlayerResponse;
            }
        } catch (e) {
            console.warn("Subtitle Downloader: 访问 window.ytplayer 数据时出错 (可能未初始化):", e);
        }

        // 方法 1：检查全局变量 ytInitialPlayerResponse (最常见的位置)
        if (window.ytInitialPlayerResponse) {
            console.log("Subtitle Downloader: 方法 1 成功 - window.ytInitialPlayerResponse");
            return window.ytInitialPlayerResponse;
        }

        // 方法 2: 检查 ytcfg 对象 (YouTube 配置对象)
        try {
            const cfgData = window.ytcfg?.data_?.PLAYER_RESPONSE // 大写键
                || window.ytcfg?.data_?.playerResponse // 小写键
                || window.ytcfg?.get?.('PLAYER_RESPONSE') // 使用 get 方法 (大写)
                || window.ytcfg?.get?.('playerResponse'); // 使用 get 方法 (小写)
            if (cfgData) {
                console.log("Subtitle Downloader: 方法 2 成功 - 从 ytcfg 对象获取");
                return cfgData;
            }
        } catch (e) {
            console.warn("Subtitle Downloader: 访问 ytcfg 数据时出错:", e);
        }

        // 方法 3：从页面的 <script> 标签中抓取 (作为最后的备选方案)
        console.log("Subtitle Downloader: 尝试从 <script> 标签中抓取 Player Response...");
        try {
            const scripts = document.getElementsByTagName('script');
            for (const script of scripts) {
                const text = script.textContent;
                if (!text) continue;

                // 查找 `var ytInitialPlayerResponse = {...};` 或 `window["ytInitialPlayerResponse"] = {...};`
                if (text.includes('ytInitialPlayerResponse')) {
                    // 改进正则表达式，更精确地匹配 JSON 对象，并处理可能的空格和分号
                    const jsonMatch = text.match(/(?:var|window\["ytInitialPlayerResponse"\])\s*ytInitialPlayerResponse\s*=\s*({.+?})\s*;/);
                    if (jsonMatch && jsonMatch[1]) {
                        try {
                            const jsonData = JSON.parse(jsonMatch[1]);
                            console.log("Subtitle Downloader: 方法 3 成功 - 从脚本中抓取 ytInitialPlayerResponse");
                            return jsonData;
                        } catch (e) {
                            console.warn("Subtitle Downloader: 抓取到的 ytInitialPlayerResponse JSON 解析失败:", e, jsonMatch[1].substring(0, 500) + "..."); // 打印部分字符串帮助调试
                        }
                    }
                }

                // 备选：查找嵌入在其他 JSON 中的 "playerResponse":{...}
                // (这个方法风险较高，可能匹配到非预期的 JSON)
                if (text.includes('"playerResponse":{') && text.includes('"captionTracks":')) { // 添加 captionTracks 检查提高准确性
                    // 使用更健壮的方法来提取 JSON 对象，考虑嵌套括号
                    const startIndex = text.indexOf('"playerResponse":');
                    if (startIndex !== -1) {
                        const objectStartIndex = text.indexOf('{', startIndex);
                        if (objectStartIndex !== -1) {
                            let braceCount = 0;
                            let objectEndIndex = -1;
                            for (let i = objectStartIndex; i < text.length; i++) {
                                if (text[i] === '{') {
                                    braceCount++;
                                } else if (text[i] === '}') {
                                    braceCount--;
                                    if (braceCount === 0) {
                                        objectEndIndex = i + 1;
                                        break;
                                    }
                                }
                                // 添加字符串引号的处理，防止误判括号
                                if (text[i] === '"') {
                                    i = text.indexOf('"', i + 1); // 跳过字符串内容
                                    if (i === -1) break; // 如果字符串未闭合，则退出
                                }
                            }

                            if (objectEndIndex !== -1) {
                                const potentialJson = text.substring(objectStartIndex, objectEndIndex);
                                try {
                                    const jsonData = JSON.parse(potentialJson);
                                    // 再次确认这个对象看起来像 PlayerResponse (例如检查是否有 videoDetails)
                                    if (jsonData && jsonData.videoDetails) {
                                        console.log("Subtitle Downloader: 方法 3 成功 - 从脚本中抓取嵌入的 playerResponse");
                                        return jsonData;
                                    } else {
                                        console.warn("Subtitle Downloader: 抓取到的嵌入式 JSON 解析成功，但似乎不是有效的 PlayerResponse:", potentialJson.substring(0, 500) + "...");
                                    }
                                } catch (e) {
                                    console.warn("Subtitle Downloader: 抓取到的嵌入式 playerResponse JSON 解析失败:", e, potentialJson.substring(0, 500) + "...");
                                }
                            }
                        }
                    }
                }
            }
        } catch (e) {
            console.error("Subtitle Downloader: 搜索或解析嵌入脚本时发生错误:", e);
        }

        // 如果所有方法都失败了
        console.error("Subtitle Downloader: 无法通过任何已知方法找到 Player Response 数据。");
        return null;
    }

    /**
     * 主按钮的点击事件处理函数
     * @param {Event} event 点击事件对象
     */
    function handleButtonClick(event) {
        event.stopPropagation(); // 阻止事件冒泡，防止触发下面的 document 点击事件
        console.log("Subtitle Downloader: Button clicked for video:", window.location.href); // 添加日志


        // 如果菜单当前是显示的，再次点击按钮则隐藏菜单
        if (downloadMenu && downloadMenu.style.display === 'block') {
            hideMenu();
            return;
        }

        console.log(`Subtitle Downloader: 按钮被点击。等待 ${GET_DATA_DELAY}毫秒 后获取数据...`);

        // 延迟执行获取数据的操作，给页面（尤其是 Player Response）更多加载时间
        setTimeout(() => {
            console.log("Subtitle Downloader: 开始执行数据获取...");
            const playerResponse = getPlayerResponseData(); // 尝试获取数据

            if (!playerResponse) {
                alert(NO_DATA_FOUND_TEXT); // 提示用户找不到数据
                console.error("Subtitle Downloader: 延迟后仍然无法获取 PlayerResponse 数据。");
                return; // 获取失败则终止
            }

            // 获取成功，打印部分数据结构用于调试
            console.log("Subtitle Downloader: 成功获取 PlayerResponse 对象。正在查找字幕信息...");
            // console.log("Subtitle Downloader: PlayerResponse (部分):", { // (调试用)
            //      captions: playerResponse.captions ? '存在' : '不存在',
            //      videoDetails: playerResponse.videoDetails ? {title: playerResponse.videoDetails.title} : '不存在'
            // });

            // 检查字幕相关的嵌套结构是否存在
            const captions = playerResponse.captions;
            if (!captions) {
                console.warn("Subtitle Downloader: 在 PlayerResponse 中未找到 'captions' 对象。");
                alert(NO_CAPTIONS_IN_DATA_TEXT + " (原因: 未找到 captions 对象)");
                currentCaptionTracks = []; // 清空轨道列表
                showLanguageMenu(); // 显示 "无字幕" 消息
                return;
            }

            const renderer = captions.playerCaptionsTracklistRenderer;
            if (!renderer) {
                console.warn("Subtitle Downloader: 在 captions 对象中未找到 'playerCaptionsTracklistRenderer'。");
                alert(NO_CAPTIONS_IN_DATA_TEXT + " (原因: 未找到 renderer)");
                currentCaptionTracks = [];
                showLanguageMenu();
                return;
            }

            const tracks = renderer.captionTracks;
            if (!tracks || !Array.isArray(tracks)) {
                console.warn("Subtitle Downloader: 在 renderer 中未找到 'captionTracks' 数组或其不是数组。");
                alert(NO_CAPTIONS_IN_DATA_TEXT + " (原因: 未找到 tracks 数组)");
                currentCaptionTracks = [];
                showLanguageMenu();
                return;
            }

            console.log(`Subtitle Downloader: 在 PlayerResponse 中找到 ${tracks.length} 个原始字幕轨道信息。`);

            // 提取并处理有效的字幕轨道信息
            currentCaptionTracks = tracks.map(track => {
                // 检查必要的属性是否存在，尤其是 baseUrl
                if (!track.baseUrl || !track.languageCode) {
                    console.warn("Subtitle Downloader: 发现一个缺少 baseUrl 或 languageCode 的轨道:", track);
                    return null; // 无效轨道，返回 null
                }
                return {
                    langCode: track.languageCode, // 语言代码 (如 "en", "ja")
                    // 优先使用 name.simpleText，备选 languageCode
                    name: track.name?.simpleText || track.languageCode || '未知语言',
                    url: track.baseUrl, // 字幕下载 URL (最关键!)
                    kind: track.kind, // 字幕类型 (如 "asr" 表示自动生成)
                    // isTranslatable: track.isTranslatable || false // 是否为可翻译轨道
                };
            }).filter(track => track !== null); // 过滤掉无效轨道 (返回 null 的)

            if (currentCaptionTracks.length === 0) {
                if (tracks.length > 0) {
                    // 有原始轨道信息，但处理后没有有效的（都缺少 URL 等）
                    console.warn("Subtitle Downloader: 原始数据中有轨道，但处理后没有找到有效的字幕轨道 (可能都缺少 URL)。");
                    alert("找到了字幕信息，但无法获取有效的下载链接。");
                } else {
                    // 原始数据中就没有轨道
                    console.log("Subtitle Downloader: 此视频确认没有任何字幕轨道。");
                    // 无需 alert，showLanguageMenu 会显示 "无字幕"
                }
            } else {
                console.log(`Subtitle Downloader: 成功提取了 ${currentCaptionTracks.length} 个有效字幕轨道:`, currentCaptionTracks.map(t => `${t.name} (${t.langCode})`));
            }

            // 显示语言选择菜单（即使没有字幕，也会显示提示信息）
            showLanguageMenu();

        }, GET_DATA_DELAY); // 执行延迟
    }

    // --- 初始化和页面监控 ---

    // 添加全局点击监听器，用于在点击菜单外部时隐藏菜单
    document.addEventListener('click', (event) => {
        // 检查菜单是否可见，以及点击的目标是否不在按钮和菜单内部
        if (downloadMenu?.style.display === 'block' &&
            !downloadButton?.contains(event.target) && // 点击的不是按钮
            !downloadMenu.contains(event.target)) { // 点击的也不是菜单内部
            hideMenu(); // 隐藏菜单
        }
    }, true); // 使用捕获阶段确保先执行

    /**
     * 初始化脚本，查找按钮容器并添加下载按钮和菜单
     * @returns {boolean} 是否初始化成功
     */
    function init() {
        // 如果按钮已存在，则不再初始化
        if (document.getElementById('yt-subtitle-downloader-button')) {
            console.log("Subtitle Downloader: 按钮已存在，跳过初始化。");
            // 清除可能存在的重试定时器
            if (initInterval) {
                clearInterval(initInterval);
                initInterval = null;
            }
            return true;
        }

        console.log(`Subtitle Downloader: 尝试初始化 (第 ${initRetryCount + 1} 次)...`);

        // 定义可能的按钮容器选择器 (YouTube 布局可能变化)
        const targetSelectors = [
            // 新版布局的选择器 (通常在这里)
            'ytd-watch-metadata #actions-inner #menu #top-level-buttons-computed',
            '#actions-inner > #menu > ytd-menu-renderer > #top-level-buttons-computed',
            '#menu.ytd-watch-metadata #top-level-buttons-computed',
            // 旧版布局的选择器
            'ytd-watch-metadata #actions #menu #top-level-buttons-computed',
            '#info-contents #menu #top-level-buttons-computed'
        ];

        let buttonContainer = null;
        // 遍历选择器，查找第一个存在的容器
        for (const selector of targetSelectors) {
            buttonContainer = document.querySelector(selector);
            if (buttonContainer) {
                console.log("Subtitle Downloader: 找到按钮容器:", selector);
                break; // 找到即停止
            }
        }

        // 如果找不到容器，则初始化失败
        if (!buttonContainer) {
            console.warn(`Subtitle Downloader: 未找到按钮容器 (尝试 ${initRetryCount + 1}/${MAX_RETRIES})。将在 ${RETRY_INTERVAL}ms 后重试...`);
            return false; // 返回 false 表示失败
        }

        // 创建下载按钮
        downloadButton = document.createElement('button');
        downloadButton.id = 'yt-subtitle-downloader-button';
        downloadButton.textContent = BUTTON_TEXT;
        downloadButton.title = "点击选择字幕语言和格式进行下载"; // 鼠标悬停提示

        // 创建或获取下载菜单元素
        if (!document.getElementById('yt-subtitle-downloader-menu')) {
            downloadMenu = document.createElement('div');
            downloadMenu.id = 'yt-subtitle-downloader-menu';
            // 将菜单添加到 body 末尾，避免被父容器的样式影响 (如 overflow: hidden)
            document.body.appendChild(downloadMenu);
        } else {
            downloadMenu = document.getElementById('yt-subtitle-downloader-menu');
            downloadMenu.innerHTML = ''; // 清空可能存在的旧内容
        }

        // 尝试将按钮插入到“分享”按钮后面，如果找不到则附加到末尾
        try {
            const shareButtonViewModel = buttonContainer.querySelector('yt-button-view-model:has(button[aria-label*="分享"]), yt-button-view-model:has(button[title*="分享"]), yt-button-view-model:has(button[aria-label*="Share"]), yt-button-view-model:has(button[title*="Share"])'); // 查找分享按钮的容器
            if (shareButtonViewModel && shareButtonViewModel.parentElement === buttonContainer) {
                buttonContainer.insertBefore(downloadButton, shareButtonViewModel.nextSibling); // 插入到分享按钮之后
                console.log("Subtitle Downloader: 按钮已插入到分享按钮之后。");
            } else {
                // 如果找不到分享按钮或结构不符，直接添加到容器末尾
                buttonContainer.appendChild(downloadButton);
                console.log("Subtitle Downloader: 未找到分享按钮或结构不符，按钮已附加到容器末尾。");
            }
        } catch (e) {
            // 插入失败的备选方案
            console.error("Subtitle Downloader: 尝试插入按钮时出错，将按钮附加到末尾:", e);
            buttonContainer.appendChild(downloadButton);
        }


        // 为按钮添加点击事件监听器
        downloadButton.addEventListener('click', handleButtonClick);

        console.log("Subtitle Downloader: 初始化成功，按钮和菜单已添加。");
        // 清除可能存在的重试定时器
        if (initInterval) {
            clearInterval(initInterval);
            initInterval = null;
        }
        return true; // 返回 true 表示成功
    }

    /**
     * 尝试初始化脚本，如果失败则设置定时器重试
     */
    function tryInit() {
        if (init()) {
            // 初始化成功，不需要再做任何事
            console.log("Subtitle Downloader: 最终初始化成功。");
        } else {
            // 初始化失败
            initRetryCount++; // 增加重试次数
            if (initRetryCount >= MAX_RETRIES) {
                // 达到最大重试次数，停止重试并报错
                if (initInterval) {
                    clearInterval(initInterval);
                    initInterval = null;
                }
                console.error(`Subtitle Downloader: 达到最大重试次数 (${MAX_RETRIES})，初始化失败。脚本可能无法在此页面上运行。`);
            } else {
                // 如果定时器还未设置，则设置定时器进行下一次重试
                if (!initInterval) {
                    console.log(`Subtitle Downloader: 初始化失败，将在 ${RETRY_INTERVAL}ms 后进行第 ${initRetryCount + 1} 次尝试...`);
                    initInterval = setInterval(tryInit, RETRY_INTERVAL);
                }
            }
        }
    }

    // --- 监听 YouTube 页面动态加载 (SPA 导航) ---
    if (observer) {
        // 如果之前有观察者，先断开连接，防止重复观察
        observer.disconnect();
        console.log("Subtitle Downloader: 已断开旧的 MutationObserver 连接。");
    }

    // 创建 MutationObserver 实例，监听 DOM 变化
    observer = new MutationObserver((mutations) => {
        let shouldReInit = false; // 标记是否需要重新初始化
        let pageNavigated = false; // 标记是否发生了页面导航

        for (const mutation of mutations) {
            // 检查是否有关键节点被添加或移除，这可能表示页面内容更新或导航
            // 监听 #page-manager 的子节点变化通常能捕捉到 YouTube 的 SPA 导航
            if (mutation.target.id === 'page-manager' && mutation.type === 'childList') {
                console.log("Subtitle Downloader: 检测到 #page-manager 子节点变化，可能发生页面导航。");
                pageNavigated = true;
                shouldReInit = true; // 页面导航后需要重新初始化
                break; // 确认导航后无需检查其他 mutation
            }

            // 检查下载按钮是否被意外移除 (例如 YouTube 更新了 DOM 结构)
            if (mutation.removedNodes) {
                for (const node of mutation.removedNodes) {
                    // 如果移除的节点是我们的按钮
                    if (node.nodeType === Node.ELEMENT_NODE && node.id === 'yt-subtitle-downloader-button') {
                        console.log("Subtitle Downloader: 检测到下载按钮被移除，尝试重新初始化...");
                        shouldReInit = true;
                        break; // 找到按钮被移除，无需检查其他移除的节点
                    }
                }
            }
            if (shouldReInit) break; // 如果已确定需要重置，跳出外层循环

            // (可选) 添加对按钮容器变化的更精确监听，减少不必要的重试
            // if (mutation.target.matches && mutation.target.matches('#actions-inner, #menu, #top-level-buttons-computed')) {
            //     // 如果按钮还不存在，则尝试初始化
            //     if (!document.getElementById('yt-subtitle-downloader-button')) {
            //         console.log("Subtitle Downloader: 检测到按钮容器相关区域变化，尝试重新初始化...");
            //         shouldReInit = true;
            //         break;
            //     }
            // }
        }

        // 如果检测到需要重新初始化，并且按钮当前不存在
        if (shouldReInit && !document.getElementById('yt-subtitle-downloader-button')) {
            console.log("Subtitle Downloader: 触发重新初始化流程...");
            initRetryCount = 0; // 重置重试计数器
            if (initInterval) clearInterval(initInterval); // 清除旧的定时器
            initInterval = null;
            // 使用 requestAnimationFrame 稍微延迟执行，等待 DOM 更新稳定
            requestAnimationFrame(tryInit);
        }

        // 如果发生页面导航，确保旧菜单被隐藏
        if (pageNavigated) {
            hideMenu();
        }
    });

    // 选择要观察的目标节点 (ytd-app 是 YouTube 应用的根元素)
    const appElement = document.querySelector('ytd-app');
    if (appElement) {
        // 配置观察选项：观察子节点变化和整个子树的变化
        observer.observe(appElement, {
            childList: true, // 监听子节点的添加或删除
            subtree: true    // 监听所有后代节点的变化
        });
        console.log("Subtitle Downloader: MutationObserver 已附加到 ytd-app，开始监听页面变化。");
    } else {
        // 如果找不到 ytd-app，脚本可能在页面加载早期运行，或者页面结构已改变
        console.error("Subtitle Downloader: 未找到 ytd-app 元素，无法附加 MutationObserver。页面导航时可能无法自动重新加载按钮。将尝试在 load 事件后初始化。");
    }

    // --- 初始加载 ---
    // 尝试在 DOMContentLoaded 或 load 事件后执行第一次初始化
    // 使用 setTimeout 稍微延迟执行，给 YouTube 自己的脚本一些执行时间
    if (document.readyState === 'complete' || document.readyState === 'interactive') {
        // 如果页面已经加载完成或进入交互状态
        console.log("Subtitle Downloader: 页面已加载，延迟 750ms 后尝试初始化...");
        setTimeout(tryInit, 750);
    } else {
        // 如果页面仍在加载中，监听 DOMContentLoaded 事件
        console.log("Subtitle Downloader: 页面加载中，监听 DOMContentLoaded 事件...");
        window.addEventListener('DOMContentLoaded', () => {
            console.log("Subtitle Downloader: DOMContentLoaded 事件触发，延迟 750ms 后尝试初始化...");
            setTimeout(tryInit, 750);
        });
        // 同时监听 load 事件作为备选，以防 DOMContentLoaded 时所需元素还未完全准备好
        window.addEventListener('load', () => {
            console.log("Subtitle Downloader: load 事件触发，如果还未初始化，将再次尝试...");
            // 检查按钮是否还未创建，避免重复执行 tryInit
            if (!document.getElementById('yt-subtitle-downloader-button')) {
                setTimeout(tryInit, 200); // 短暂延迟后尝试
            }
        });
    }

})();