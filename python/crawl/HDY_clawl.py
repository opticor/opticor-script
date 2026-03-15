import requests
import time
import os
import logging
from bs4 import BeautifulSoup

PARENT_URL = "https://www.szhdy.com/newestactivity.html"
BASE_URL = "https://www.szhdy.com"

# Telegram
TG_BOT_TOKEN = os.environ.get("TG_BOT_MESSANNOUCE_TOKEN")
TG_CHAT_ID = os.environ.get("TG_CHAT_ID")

# ========== 轮询间隔（秒）==========
CHILD_INTERVAL = 15   # 子页（活动详情页）检查间隔
PARENT_INTERVAL = 60  # 父页（活动列表页）刷新间隔

# ========== 启动首扫通知配置 ==========
# 程序启动/重启时，会对父页上已有的所有活动做一次首次扫描。
# 对程序而言这些商品都是"第一次见到"，但实际上它们早已存在。
#
# NOTIFY_ON_EXISTING_PRODUCT_FIRST_SEEN:
#   True  → 首扫到有货商品时立即推送通知
#            （适合生产环境，重启后马上掌握当前在售情况）
#   False → 静默记录初始状态，不推送
#            （适合调试时，避免每次重启都收到大量通知）
NOTIFY_ON_EXISTING_PRODUCT_FIRST_SEEN = False

# ========== 日志级别配置 ==========
# 控制输出日志的详细程度，从简到繁依次为：
#
#   logging.CRITICAL  → 只输出导致程序崩溃的严重错误（几乎静默）
#   logging.ERROR     → 只输出错误信息（请求失败、解析异常等）
#   logging.WARNING   → 输出警告 + 错误（默认 Python 级别）
#   logging.INFO      → 输出关键流程信息：新活动发现、补货通知发送、
#                       当前监控数量等（推荐生产环境使用）
#   logging.DEBUG     → 输出所有细节：每个商品的解析结果、每次循环
#                       的检查过程、每条请求的状态（推荐调试时使用）
LOG_LEVEL = logging.WARNING

HEADERS = {
    "User-Agent": "Mozilla/5.0 (compatible; ActivityMonitor/1.0)"
}

# ===== 内存状态 =====
last_sold_out_state = {}
active_urls = []

# ========== 日志配置 ==========

logging.basicConfig(
    level=LOG_LEVEL,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)
logger = logging.getLogger(__name__)


# ========== Telegram ==========

def send_tg(msg: str):
    url = f"https://api.telegram.org/bot{TG_BOT_TOKEN}/sendMessage"
    payload = {
        "chat_id": TG_CHAT_ID,
        "text": msg,
        "disable_web_page_preview": False
    }
    try:
        requests.post(url, json=payload, timeout=10)
        logger.debug(f"TG消息发送成功，长度={len(msg)}")
    except Exception as e:
        logger.error(f"TG发送失败: {e}")


# ========== 父页：获取活动链接 ==========

def fetch_activity_urls() -> list[str]:
    logger.debug(f"请求父页：{PARENT_URL}")
    resp = requests.get(PARENT_URL, headers=HEADERS, timeout=15)
    resp.raise_for_status()
    logger.debug(f"父页响应 HTTP {resp.status_code}，内容长度={len(resp.text)}")

    soup = BeautifulSoup(resp.text, "html.parser")

    urls = []
    anchors = soup.select("a[href*='/activities/']")
    logger.debug(f"父页找到原始 <a> 标签数量：{len(anchors)}")

    seen = set()
    for a in anchors:
        href = a.get("href", "").strip()
        if not href:
            continue

        if href.startswith("http"):
            full_url = href
        elif href.startswith("/"):
            full_url = BASE_URL + href
        else:
            full_url = BASE_URL + "/" + href

        if full_url not in seen:
            seen.add(full_url)
            urls.append(full_url)

    logger.debug(f"父页去重后活动链接数：{len(urls)}")
    return urls


# ========== 子页：抓取商品信息 ==========

def fetch_products(url: str) -> dict:
    logger.debug(f"请求子页：{url}")
    resp = requests.get(url, headers=HEADERS, timeout=15)
    resp.raise_for_status()
    logger.debug(f"子页响应 HTTP {resp.status_code}，内容长度={len(resp.text)}")

    soup = BeautifulSoup(resp.text, "html.parser")
    cards = soup.select("div[class*='promotion-card']")

    logger.debug(f"子页解析到商品卡片数：{len(cards)}，来源：{url}")

    products = {}

    for card in cards:
        pid = card.get("data-id")
        if not pid:
            logger.debug("跳过无 data-id 的卡片")
            continue

        title_el = card.select_one("[class$='title'] h1")
        name = title_el.get_text(strip=True) if title_el else "未知商品"

        price_el = card.select_one(".main-price-current")
        price = price_el.get_text(strip=True) if price_el else "未知"

        footer_btn = card.select_one(".form-footer-butt")
        sold_out = footer_btn and "商品已售罄" in footer_btn.get_text()

        config_text = []
        form_containers = card.select("[class$='form-container'] .form-container")

        for form in form_containers:
            title_el = form.select_one(".form-title h5")
            content_el = form.select_one(".form-content-data")

            if not content_el:
                continue

            title = title_el.get_text(strip=True).replace("：", "").replace(":", "") if title_el else ""

            dropdown = content_el.select_one(".act-dropdown-selected")
            if dropdown:
                value = dropdown.get_text(strip=True)

                # act-dropdown-selected 为空时，从 option 中获取
                if not value:
                    options = content_el.select(".act-dropdown-option")
                    if options:
                        value = " / ".join(opt.get_text(strip=True) for opt in options if opt.get_text(strip=True))

                logger.debug(f"配置内容为下拉类型, value: {value}")

            else:
                value = content_el.get_text(strip=True)

            if value:
                config_text.append(f"{title}: {value}" if title else value)

        config_str = "\n".join(config_text)

        products[pid] = {
            "name": name,
            "price": price,
            "sold_out": sold_out,
            "config": config_str
        }

        logger.debug(
            f"  解析商品 pid={pid} | 名称={name} | 价格={price} | "
            f"售罄={sold_out} | 配置项数={len(config_text)}"
        )

    return products


# ========== 子页轮询：检查单个活动页 ==========

def check_activity(url: str, is_new_activity: bool = False):
    global last_sold_out_state

    if url not in last_sold_out_state:
        last_sold_out_state[url] = {}

    state = last_sold_out_state[url]

    try:
        products = fetch_products(url)

        if not products:
            logger.debug(f"未解析到任何商品，跳过：{url}")
            return

        logger.debug(f"共解析到 {len(products)} 个商品，开始逐一判断状态变化")

        for pid, info in products.items():
            sold_out_label = "已售罄" if info["sold_out"] else "有货"

            # ---- 首次见到该商品 ----
            if pid not in state:
                state[pid] = info["sold_out"]

                if is_new_activity:
                    # 场景 A：运行期间父页真正新增的活动，无条件推送有货通知
                    if not info["sold_out"]:
                        msg = (
                            "🆕 新活动有货提醒\n\n"
                            f"商品：{info['name']}\n"
                            f"价格：{info['price']} 元\n\n"
                            "📦 配置信息：\n"
                            f"{info['config']}\n\n"
                            f"链接：{url}"
                        )
                        send_tg(msg)
                        logger.info(
                            f"[新活动-有货] 通知已发送 | pid={pid} | {info['name']}"
                        )
                    else:
                        logger.info(
                            f"[新活动-首次] 已售罄，静默记录 | pid={pid} | {info['name']}"
                        )
                else:
                    # 场景 B：启动时首扫已有活动，受开关控制
                    if not info["sold_out"] and NOTIFY_ON_EXISTING_PRODUCT_FIRST_SEEN:
                        msg = (
                            "📋 启动首扫有货提醒\n\n"
                            f"商品：{info['name']}\n"
                            f"价格：{info['price']} 元\n\n"
                            "📦 配置信息：\n"
                            f"{info['config']}\n\n"
                            f"链接：{url}"
                        )
                        send_tg(msg)
                        logger.info(
                            f"[启动首扫-有货] 通知已发送 | pid={pid} | {info['name']}"
                        )
                    else:
                        logger.info(
                            f"[启动首扫] 静默记录 | pid={pid} | "
                            f"{info['name']} | {sold_out_label} | "
                            f"通知开关={NOTIFY_ON_EXISTING_PRODUCT_FIRST_SEEN}"
                        )

                continue

            # ---- 非首次：判断售罄状态是否发生变化 ----
            old_state = state[pid]
            new_state = info["sold_out"]

            if old_state == new_state:
                logger.debug(
                    f"[无变化] pid={pid} | {info['name']} | {sold_out_label}"
                )
            elif old_state and not new_state:
                # 售罄 → 有货：补货
                msg = (
                    "🎉 商品补货提醒\n\n"
                    f"商品：{info['name']}\n"
                    f"价格：{info['price']} 元\n\n"
                    "📦 配置信息：\n"
                    f"{info['config']}\n\n"
                    f"链接：{url}"
                )
                send_tg(msg)
                logger.info(
                    f"[补货] 通知已发送 | pid={pid} | {info['name']}"
                )
            else:
                # 有货 → 售罄
                logger.info(
                    f"[售罄] 状态变更 | pid={pid} | {info['name']} | 有货 → 已售罄"
                )

            state[pid] = new_state

    except Exception as e:
        logger.error(f"抓取子页失败 | url={url} | 错误：{e}")


# ========== 主循环 ==========

def monitor_loop():
    global active_urls

    logger.info("=" * 50)
    logger.info("监控程序启动")
    logger.info(f"父页刷新间隔：{PARENT_INTERVAL}s | 子页检查间隔：{CHILD_INTERVAL}s")
    logger.info(f"启动首扫通知={NOTIFY_ON_EXISTING_PRODUCT_FIRST_SEEN}")
    logger.info("=" * 50)

    last_parent_fetch = 0
    is_first_run = True  # 标记是否为程序启动后第一次父页加载

    while True:
        now = time.time()

        # -------- 父页：定时刷新活动列表 --------
        if now - last_parent_fetch >= PARENT_INTERVAL:
            logger.debug("触发父页刷新")
            try:
                new_urls = fetch_activity_urls()

                added = [u for u in new_urls if u not in active_urls]
                removed = [u for u in active_urls if u not in new_urls]

                if added:
                    if is_first_run:
                        # 程序启动时加载的活动，走启动首扫逻辑
                        logger.info(f"启动时加载活动 {len(added)} 个：")
                        for u in added:
                            logger.info(f"  · {u}")
                            check_activity(u, is_new_activity=False)
                    else:
                        # 运行期间真正新增的活动，无条件推送
                        logger.info(f"运行期间新增活动 {len(added)} 个：")
                        for u in added:
                            logger.info(f"  + {u}")
                        send_tg(
                            f"📢 发现新活动 {len(added)} 个\n\n"
                            + "\n".join(added)
                        )
                        for u in added:
                            logger.debug(f"新活动立即首次检查：{u}")
                            check_activity(u, is_new_activity=True)
                else:
                    logger.debug("父页无新增活动")

                if removed:
                    logger.info(f"下线活动 {len(removed)} 个：")
                    for u in removed:
                        logger.info(f"  - {u}")
                else:
                    logger.debug("父页无下线活动")

                active_urls = new_urls
                last_parent_fetch = time.time()
                is_first_run = False  # 首次父页加载完成，后续均视为运行期间
                logger.info(f"当前监控活动数：{len(active_urls)}")

            except Exception as e:
                logger.error(f"父页抓取失败：{e}")

        # -------- 子页：逐一检查每个活动页 --------
        if active_urls:
            logger.debug(f"开始轮询检查，共 {len(active_urls)} 个活动")
            for url in active_urls:
                check_activity(url)
        else:
            logger.debug("当前无活动可检查，等待下次父页刷新")

        logger.debug(f"本轮检查完毕，休眠 {CHILD_INTERVAL}s")
        time.sleep(CHILD_INTERVAL)


if __name__ == "__main__":
    monitor_loop()