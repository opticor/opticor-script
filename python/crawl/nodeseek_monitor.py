import feedparser
import requests
import re
import time
import os
import json
from datetime import datetime

# ================= 配置区域 =================

RSS_URL = "https://rss.nodeseek.com/"

# 这里填你的 TG 信息
TG_BOT_TOKEN = os.environ.get("TG_BOT_MESSANNOUCE_TOKEN")
TG_CHAT_ID = os.environ.get("TG_CHAT_ID")

# 监听间隔 (秒)
CHECK_INTERVAL = 20

# 存储文件名称
DATA_FILE = "rss_snapshot.json"

# --- 关键词配置逻辑 (新增) ---
# 优先读取环境变量 NODESEEK_KEYWORDS (青龙面板常用)
# 多个关键词用 & 连接，例如: "鸡&(\d+)刀&斯巴达"
if os.environ.get("NODESEEK_KEYWORDS"):
    raw_keywords = os.environ.get("NODESEEK_KEYWORDS")
    # 使用 & 分割，并去除前后空格
    KEYWORDS = [k.strip() for k in raw_keywords.split('&') if k.strip()]
    print(f"[Config] 已从环境变量加载关键词: {KEYWORDS}")
else:
    # 如果没有环境变量，使用默认列表
    KEYWORDS = [
        r".*抽(?!(风)).*",
        r".*活动.*",
        r".*快讯.*",
        r".*送(?!(中|的|风)).*",
        r".*白嫖.*",
        r".*快报.*"
    ]

# ===========================================

def send_telegram_message(title, link):
    """发送 TG 消息"""
    text = f"<b>🔔 NodeSeek 新帖发现</b>\n\n" \
           f"<b>标题:</b> {title}\n" \
           f"<b>链接:</b> {link}"
    
    url = f"https://api.telegram.org/bot{TG_BOT_TOKEN}/sendMessage"
    payload = {
        "chat_id": TG_CHAT_ID,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": False
    }
    
    try:
        requests.post(url, data=payload, timeout=10)
    except Exception as e:
        print(f"[TG Error] {e}")

def load_snapshot():
    """加载上一次的 RSS 快照 ID 列表"""
    if not os.path.exists(DATA_FILE):
        return []
    try:
        with open(DATA_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return []

def save_snapshot(id_list):
    """保存当前 RSS 快照"""
    try:
        with open(DATA_FILE, "w", encoding="utf-8") as f:
            json.dump(id_list, f, ensure_ascii=False)
    except Exception as e:
        print(f"[File Error] 保存快照失败: {e}")

def check_rss():
    #debug
    #print(f"[{datetime.now().strftime('%H:%M:%S')}] 检查更新...", end="", flush=True)
    
    try:
        # 1. 获取 RSS
        feed = feedparser.parse(RSS_URL)
        if feed.bozo: # 解析错误
            print(" [Failed] RSS 解析错误")
            return
        
        if not feed.entries:
            print(" [Empty] RSS 为空")
            return

        # 2. 提取当前所有帖子的 ID (用于保存快照)
        current_entries = []
        for entry in feed.entries:
            eid = entry.id if 'id' in entry else entry.link
            current_entries.append({
                'id': eid,
                'title': entry.title,
                'link': entry.link
            })
        
        # 提取纯 ID 列表用于对比和保存
        current_ids = [e['id'] for e in current_entries]

        # 3. 加载旧快照
        old_ids = load_snapshot()

        # 4. 如果是第一次运行（没有旧快照），直接保存当前状态，不推送
        if not old_ids:
            print(" [Init] 首次运行，建立基准快照，暂不推送。")
            save_snapshot(current_ids)
            return

        # 5. 寻找新帖子 (在 current 中，但不在 old 中)
        new_posts = []
        old_ids_set = set(old_ids) # 转为集合提高查找速度
        
        for item in current_entries:
            if item['id'] not in old_ids_set:
                new_posts.append(item)

        # 6. 处理新帖子
        if new_posts:
            #print(f" 发现 {len(new_posts)} 条新内容")
            for post in new_posts:
                # 关键词匹配
                matched = False
                for pattern in KEYWORDS:
                    try:
                        if re.search(pattern, post['title'], re.IGNORECASE):
                            matched = True
                            break
                    except re.error:
                        print(f" [Regex Error] 错误的正则关键词: {pattern}")
                
                if matched:
                    print(f"   -> [推送] {post['title']}")
                    send_telegram_message(post['title'], post['link'])
                #else:
                    #debug
                    #print(f"   -> [过滤] {post['title']}")
            
            # 7. 更新快照
            save_snapshot(current_ids)
        else:
            #debug
            #print(" 无新帖")

            # 同步快照以防 RSS 列表变动
            if current_ids != old_ids:
                save_snapshot(current_ids)

    except Exception as e:
        print(f"\n[Error] 主逻辑异常: {e}")

def main():
    print("=== NodeSeek RSS 监听 (JSON 快照版) 启动 ===")
    if not KEYWORDS:
        print("[Warning] 当前关键词列表为空，将不会推送任何消息！")
        
    while True:
        check_rss()
        time.sleep(CHECK_INTERVAL)

if __name__ == "__main__":
    main()