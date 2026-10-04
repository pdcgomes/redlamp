#!/usr/bin/env python3
"""Screenshots one element of a locally served redlamp.app at a desktop and a phone width.

usage: capture.py [url] [selector] [output prefix]
       capture.py http://localhost:3123/ '#ai' /tmp/rl-site-shot/ai

Writes <prefix>-desktop.png and <prefix>-phone.png, and prints each element's size and the
page's horizontal overflow, which should be 0. Needs Playwright (pip install playwright) and
Google Chrome, which it drives with the flags Chrome needs to start inside the agent sandbox.
"""

import sys

from playwright.sync_api import sync_playwright

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ARGS = ["--no-sandbox", "--disable-gpu-sandbox", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"]
VIEWPORTS = {"desktop": ({"width": 1440, "height": 900}, 1), "phone": ({"width": 390, "height": 844}, 2)}


def main() -> None:
    url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:3123/"
    selector = sys.argv[2] if len(sys.argv) > 2 else "main"
    prefix = sys.argv[3] if len(sys.argv) > 3 else "/tmp/rl-site-shot/capture"
    with sync_playwright() as playwright:
        # Each launch gets a throwaway profile directory.
        browser = playwright.chromium.launch(executable_path=CHROME, headless=True, args=ARGS)
        for name, (viewport, scale) in VIEWPORTS.items():
            page = browser.new_context(viewport=viewport, device_scale_factor=scale).new_page()
            page.goto(url, wait_until="networkidle")
            element = page.locator(selector).first
            element.scroll_into_view_if_needed()
            page.wait_for_timeout(400)
            path = f"{prefix}-{name}.png"
            element.screenshot(path=path)
            box = element.bounding_box() or {"width": 0, "height": 0}
            overflow = page.evaluate("document.documentElement.scrollWidth - window.innerWidth")
            print(f"{name}: {path}, {box['width']:.0f} × {box['height']:.0f} px, horizontal overflow {overflow} px")
        browser.close()


if __name__ == "__main__":
    main()
