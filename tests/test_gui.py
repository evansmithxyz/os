"""Desktop: window manager, workspaces, GUI terminal, canvas and browser.

Coordinates below assume the default window geometry (x=56, y=44, 912x640):
title bar y 44-75 with close/minimize/maximize lights centred at x 76/96/116,
y 60; client area starts at (57, 76). The top bar and the dock are laid out
in gui/desktop.asm, the browser's toolbar in apps/browser.asm (BR_*).
"""

import os
import re
import time
import unittest

from tests.harness import OUTPUT, PROMPT, ROOT, OSTestCase, agbuild
from tests.test_net import BIG_HTML, HostWebServer

# Theme colours (kernel/gui/theme.inc)
EDGE_FOCUS = 0x475681
RED = 0xF7768E
CANVAS_BG = 0x0E121B

DOT_Y = 60
CLOSE_X, MINIMIZE_X, MAXIMIZE_X = 76, 96, 116
DOCK_Y = 726                            # centre of the dock icons
DOCK_TERM_X, DOCK_WEB_X = 425, 483
POWER_X, POWER_Y = 1008, 14
WS_BUTTON_X = (144, 172, 200, 228)      # top bar workspace buttons 1-4, y 14
BOOKMARK_Y = 134
BOOKMARK_DEMO_X, BOOKMARK_AFS_X = 180, 362
PAGE_LINE_1, PAGE_LINE_2 = 178, 200     # first two lines of a page (default margins)
FORM_LINE_1, FORM_LINE_2, FORM_LINE_3 = 175, 192, 210  # form.html's rows of controls


class DesktopTest(OSTestCase):

    def test_start_and_exit(self):
        self.start_gui()
        shot = self.vm.screenshot("desktop")
        self.assertEqual((shot.width, shot.height), (1024, 768))
        self.vm.key("esc")
        self.vm.expect("gui: stopped")
        self.vm.expect(PROMPT)
        time.sleep(0.3)
        self.assertEqual(self.vm.screenshot("text").width, 720)
        self.assertIn("welcome.txt", self.vm.run("ls"), "shell still works afterwards")

    def test_exit_button(self):
        self.start_gui()
        self.vm.click(POWER_X, POWER_Y)
        self.vm.expect("gui: stopped")

    def test_terminal_runs_real_commands(self):
        self.start_gui()
        self.vm.send("write gui.txt made in the desktop\r")
        self.vm.expect("Wrote 19 bytes to gui.txt")
        self.vm.expect(PROMPT)
        self.vm.send("ls\r")
        listing = self.vm.expect(PROMPT)
        self.assertIn("gui.txt", listing)
        self.vm.key("esc")
        self.vm.expect("gui: stopped")
        self.vm.expect(PROMPT)
        self.assertEqual(self.vm.run("cat gui.txt").strip(), "made in the desktop")

    def test_terminal_takes_keyboard_input(self):
        self.start_gui()
        self.vm.type("echo typed-on-ps2\n")
        self.assertIn("typed-on-ps2", self.vm.expect(PROMPT))

    def test_workspace_keys(self):
        self.start_gui()
        for key, ws in (("f2", 2), ("f3", 3), ("f4", 4), ("f1", 1)):
            self.vm.key(key)
            self.vm.expect(f"wm: workspace {ws}")
        self.vm.key("alt", "3")
        self.vm.expect("wm: workspace 3")

    def test_move_window_to_workspace(self):
        self.start_gui()
        self.vm.key("shift", "f3")      # terminal is focused on workspace 1
        self.vm.expect("wm: moved to workspace 3")
        self.vm.send("ws\r")
        status = self.vm.expect(PROMPT)
        self.assertIn("Workspace 3 is active", status)
        self.assertIn("Terminal on workspace 3", status)

    def test_window_buttons(self):
        self.start_gui()
        self.vm.mouse_home()
        self.vm.click(MAXIMIZE_X, DOT_Y)
        self.vm.expect("wm: maximize Terminal")
        self.vm.click(8 + 60, 36 + 16)      # maximized windows sit at (8, 36)
        self.vm.expect("wm: restore Terminal")
        self.vm.click(MINIMIZE_X, DOT_Y)
        self.vm.expect("wm: minimize Terminal")
        self.vm.click(DOCK_TERM_X, DOCK_Y)
        self.vm.expect("wm: open Terminal")
        self.vm.click(CLOSE_X, DOT_Y)
        self.vm.expect("wm: close Terminal")
        self.vm.click(DOCK_TERM_X, DOCK_Y)
        self.vm.expect("wm: open Terminal")

    def test_dock_opens_and_minimizes_apps(self):
        self.start_gui()
        self.vm.mouse_home()
        self.vm.click(DOCK_WEB_X, DOCK_Y)   # on workspace 2: goes there
        self.vm.expect("wm: open Browser")
        self.vm.click(DOCK_WEB_X, DOCK_Y)   # focused: minimizes
        self.vm.expect("wm: minimize Browser")
        self.vm.click(DOCK_WEB_X, DOCK_Y)
        self.vm.expect("wm: open Browser")

    def test_top_bar_workspace_buttons(self):
        self.start_gui()
        self.vm.mouse_home()
        self.vm.click(WS_BUTTON_X[2], 14)
        self.vm.expect("wm: workspace 3")
        self.vm.click(WS_BUTTON_X[0], 14)
        self.vm.expect("wm: workspace 1")

    def test_windows_have_rounded_corners(self):
        self.start_gui()
        self.vm.mouse_home()
        shot = self.vm.screenshot("corners")
        self.assertEqual(shot.pixel_hex(56 + 100, 44), EDGE_FOCUS, "the outline's straight top edge")
        self.assertEqual(shot.pixel_hex(56, 44 + 100), EDGE_FOCUS, "the outline's straight left edge")
        self.assertNotEqual(shot.pixel_hex(56, 44), EDGE_FOCUS, "the corner pixel is cut away")

    def test_drag_and_resize(self):
        self.start_gui()
        self.vm.mouse_home()
        self.vm.drag(960, 676, 700, 500)    # resize from the corner grip: 652x464
        self.vm.drag(300, 60, 400, 160)     # then move by (+100, +100)
        time.sleep(0.4)
        shot = self.vm.screenshot("moved")
        # the outline's straight edges (the corners are rounded)
        self.assertEqual(shot.pixel_hex(156 + 200, 144), EDGE_FOCUS, "focused frame at its new position")
        self.assertEqual(shot.pixel_hex(156 + 652 - 1, 144 + 200), EDGE_FOCUS, "new width 652")
        self.assertEqual(shot.pixel_hex(156 + 200, 144 + 464 - 1), EDGE_FOCUS, "new height 464")

    def test_canvas_paints_and_clears(self):
        self.start_gui()
        self.vm.key("f3")
        self.vm.expect("wm: workspace 3")
        self.vm.key("4")                    # red
        self.vm.mouse_home()
        self.vm.drag(150, 200, 350, 200, steps=4)
        time.sleep(0.4)
        self.assertEqual(self.vm.screenshot("painted").pixel_hex(250, 200), RED)
        self.vm.key("c")
        time.sleep(0.4)
        self.assertEqual(self.vm.screenshot("cleared").pixel_hex(250, 200), CANVAS_BG)

    def test_browser_bookmarks(self):
        self.start_gui()
        self.vm.expect("browser: CyberSurf - Antigravity Portal")
        self.vm.key("f2")
        self.vm.expect("wm: workspace 2")
        self.vm.mouse_home()
        self.vm.click(BOOKMARK_DEMO_X, BOOKMARK_Y)
        self.vm.expect("browser: CyberSurf - HTML Showcase Demo")
        self.vm.click(BOOKMARK_AFS_X, BOOKMARK_Y)
        self.vm.expect("browser: afs://readme.txt")

    def test_browser_works_partly_offscreen(self):
        """Regression: negative window x once blanked the page (unsigned compares)."""
        self.start_gui()
        self.vm.key("f2")
        self.vm.expect("wm: workspace 2")
        self.vm.mouse_home()
        self.vm.drag(300, 60, 140, 60)      # window x: 56 -> -104
        self.vm.click(20, 284)              # the visible end of the "Showcase Demo" link
        self.vm.expect("browser: CyberSurf - HTML Showcase Demo")

    def test_browser_command_opens_afs_file(self):
        self.start_gui()
        self.vm.send("browser afs://welcome.txt\r")
        self.vm.expect("browser: afs://welcome.txt")
        self.vm.expect("wm: open Browser")

    def test_browser_fetches_from_host(self):
        with HostWebServer() as web:
            self.vm.send(f"browser http://10.0.2.2:{web.port}/hello.html\r")
            self.vm.expect("gui: started")
            self.vm.expect("browser: CyberSurf - 10.0.2.2", timeout=20)
            self.vm.expect("browser status: HTTP/1.0 200 OK | 10.0.2.2")
            self.vm.expect("browser text: Hello from the host served by tests/test_net.py")
        time.sleep(0.5)
        self.vm.screenshot("host_page")

    def test_browser_renders_page_with_long_head(self):
        """Regression: a <head> longer than the response buffer (www.google.com) left the page blank."""
        self.assertGreater(len(BIG_HTML), 32768)
        with HostWebServer() as web:
            self.vm.send(f"browser http://10.0.2.2:{web.port}/big.html\r")
            self.vm.expect("browser status: HTTP/1.0 200 OK | 10.0.2.2", timeout=20)
            line = self.vm.expect(r"browser text: [^\r\n]*\r?\n", regex=True)
        self.assertIn("browser text: Big page body Fish & chips <3", line)

    def test_browser_renders_page_without_head_end(self):
        with HostWebServer() as web:
            self.vm.send(f"browser http://10.0.2.2:{web.port}/nohead.html\r")
            self.vm.expect("browser status: HTTP/1.0 200 OK | 10.0.2.2", timeout=20)
            self.vm.expect("browser text: Still visible")

    # --- layout (kernel/apps/browser_html.asm), pages from tests/test_net.py ------
    def open_page(self, web, page: str) -> str:
        self.vm.send(f"browser http://10.0.2.2:{web.port}/{page}\r")
        self.vm.expect("gui: started")
        return self.vm.expect(r"browser text: [^\r\n]*\r?\n", regex=True, timeout=20)

    def test_browser_layout_whitespace_entities_tables(self):
        with HostWebServer() as web:
            line = self.open_page(web, "features.html")
        self.assertIn('browser text: Collapsed white space It\'s (c) 2026 - cafe "quoted" \' EUR5 1. Row title', line)
        self.assertIn("browser: CyberSurf - Feature test", self.vm.output, "window title from <title>")

    def test_browser_css_selectors_cascade_media(self):
        with HostWebServer() as web:
            line = self.open_page(web, "css.html")
        self.assertIn("browser: style sheet bytes", self.vm.output, "extra.css fetched")
        self.assertIn("browser text: SHOWN0 SHOWNA SHOWNB SHOWNC SHOWN1 SHOWN2 SHOWN3 SHOWN4", line)
        self.assertNotIn("HIDDEN", line)

    # --- page scripts (kernel/js/jsdom.asm), pages from tests/test_net.py --------
    def test_browser_runs_page_scripts(self):
        with HostWebServer() as web:
            line = self.open_page(web, "js.html")
        out = self.vm.output
        for expected in (
            "js: head object loading null",
            "js: items 3 two",
            'js: html <li class="a">one</li><li class="b">two</li><li class="c">three</li>',
            "js: style color: red; background-color: blue red",
            "js: class y true false",
            "js: tree BODY list 3",
            "js: external JS test /js.html",
            "js: Uncaught SyntaxError: Unexpected token 'is' (line 1)",
            "js: after an error P",
            "js: loaded ready NEW & <ok>",
        ):
            self.assertIn(expected, out)
        self.assertIn("browser text: NEW & <ok> one two three box WRITTEN", line)

    def test_browser_dom_api(self):
        with HostWebServer() as web:
            line = self.open_page(web, "dom.html")
            out = self.vm.output
            for expected in (
                "js: ids i1,i2,i3 2 UL tail & end",
                "js: clone 3 null one",
                "js: after replace onetwo3! null",
                "js: notes 2 1",
                "js: closest host true false",
                'js: html <ul><li id="i1">one</li><li id="i2">two</li>3!</ul><span>tail &amp; end</span>',
                "js alert: hello DOM",
                "js: window load complete",
            ):
                self.assertIn(expected, out)
            self.assertNotIn("js: never", out)
            self.assertIn("browser text: GO TO HELLO one two 3! tail & end N1 N2 N3", line)
            self.assertNotIn("VISIBLE UNTIL HIDDEN", line)
            # the first line runs location.href = 'hello.html' when clicked
            self.vm.mouse_home()
            self.vm.click(100, PAGE_LINE_1)
            self.vm.expect(f"js: navigate -> http://10.0.2.2:{web.port}/hello.html")
            self.vm.expect("browser text: Hello from the host", timeout=20)

    def test_browser_modern_web_apis(self):
        with HostWebServer() as web:
            self.open_page(web, "modern.html")
            self.vm.expect("js: loaded modern-extra.js", timeout=20)
        out = self.vm.output
        for expected in (
            "js: classes true true true true true [object HTMLUListElement]",
            "js: dom 3 3 3 two two",
            "js: events 7 v true block function first",
            "js: comments 3 8  note  ab a<!-- note -->b",
        ):
            self.assertIn(expected, out)
        self.assertNotIn("Uncaught", out)

    def test_browser_page_survives_garbage_collection(self):
        with HostWebServer() as web:
            line = self.open_page(web, "gc.html")
        out = self.vm.output
        self.assertIn("[klog] js gc: live bytes", out)
        self.assertIn("js: after gc 0,1,2,3,4 GC-4-TEXT", out)
        self.assertIn("browser text: GC-0-TEXT GC-1-TEXT GC-2-TEXT GC-3-TEXT GC-4-TEXT", line)

    def test_browser_timers_promises_fetch(self):
        with HostWebServer() as web:
            self.open_page(web, "async.html")
            self.vm.expect("js: timeout", timeout=20)          # the last one (300 ms)
            self.vm.expect("browser text: TIMER FIRED FETCHED ag", timeout=20)
        out = self.vm.output
        for expected in ("js: sync", "js: microtask", "js: fetched 200 3", "js: xhr 200 33",
                         "js: frames 3", "js: interval 3"):
            self.assertIn(expected, out)
        self.assertLess(out.index("js: sync"), out.index("js: microtask"))
        self.assertLess(out.index("js: interval 3"), out.index("js: timeout"))

    def test_browser_click_events(self):
        with HostWebServer() as web:
            self.open_page(web, "click.html")
            self.vm.mouse_home()
            self.vm.click(100, PAGE_LINE_1)  # the first line: onclick="" plus listeners
            self.vm.expect("js: listener click big big")
            self.vm.expect("js: bubbled to body big")
            self.vm.expect("browser text: CLICKED 1")
            self.vm.click(100, PAGE_LINE_2)  # a link whose handler calls preventDefault()
            self.vm.expect("js: link cancelled")
            time.sleep(1.5)
        self.assertNotIn("Hello from the host", self.vm.output)

    def test_browser_form_fields(self):
        """form.html (tests/test_net.py): tick, pick, type, submit with Enter."""
        with HostWebServer() as web:
            line = self.open_page(web, "form.html")
            self.assertIn("HINT", line, "placeholder of an empty field")
            self.assertIn("a b c", line, "textarea value set by the page's script")
            self.assertIn("two", line, "the selected option")
            self.assertIn('js: form ready "a b\\nc" false', self.vm.output)
            self.vm.mouse_home()
            self.vm.click(88, FORM_LINE_2)          # the check box
            self.vm.expect("js: change true")
            self.vm.click(280, FORM_LINE_3)         # the <select>: the next option
            self.vm.click(100, FORM_LINE_1)         # the first text field
            self.vm.expect("browser: field focused")
            self.vm.type("hi there&x")
            self.vm.expect("js: input hi there&x")
            self.vm.key("backspace")
            self.vm.expect(r"js: input hi there&\r?\n", regex=True)
            self.vm.key("ret")                      # submits, with the first button
            self.vm.expect('js: submit "hi there&" "a b\\nc" three')
            self.vm.expect(f"browser: form -> http://10.0.2.2:{web.port}/formdone.html"
                           "?q=hi+there%26&q2=&c=yes&h=x%26y&t=a+b%0D%0Ac&s=three&go=Go%21\n")
            self.vm.expect("browser text: Form sent", timeout=20)

    def test_browser_scrolls_with_keys_and_wheel(self):
        with HostWebServer() as web:
            self.open_page(web, "features.html")
            self.vm.key("pgdn")
            self.vm.expect("browser scroll: ")
            line = self.vm.expect(r"browser text: [^\r\n]*\r?\n", regex=True)
            self.assertRegex(line, r"browser text: Line \d+")
            self.vm.key("end")              # the last screenful: Line 80 and "The end" at the bottom
            line = self.vm.expect(r"browser text: [^\r\n]*\r?\n", regex=True)
            first = int(re.search(r"browser text: Line (\d+)", line).group(1))
            self.assertGreater(first, 50, line)
            self.vm.key("home")
            line = self.vm.expect(r"browser text: [^\r\n]*\r?\n", regex=True)
            self.assertIn("browser text: Collapsed", line)
            # two wheel notches down over the page: 2 x 3 lines of 18 pixels
            self.vm.mouse_home()
            self.vm.mouse_to(500, 400)
            self.vm.wheel(2)
            self.vm.expect("browser scroll: 108")
            self.vm.wheel(-2)
            self.vm.expect("browser scroll: 0")

    def test_browser_follows_relative_link(self):
        """links.html's first link is href='sub': /links.html -> /sub -> (301) /sub/."""
        with HostWebServer() as web:
            self.open_page(web, "links.html")
            self.vm.mouse_home()
            self.vm.click(100, PAGE_LINE_1)  # first line of the page: "Go to sub"
            self.vm.expect(f"browser: redirect -> http://10.0.2.2:{web.port}/sub/", timeout=20)
            self.vm.expect("browser text: Sub page")

    def test_browser_follows_redirect(self):
        with HostWebServer() as web:
            self.vm.send(f"browser http://10.0.2.2:{web.port}/sub\r")
            self.vm.expect(f"browser: redirect -> http://10.0.2.2:{web.port}/sub/", timeout=20)
            self.vm.expect("browser status: HTTP/1.0 200 OK | 10.0.2.2", timeout=20)
            self.vm.expect("browser text: Sub page")

    @unittest.skipUnless(os.environ.get("AGOS_TEST_INTERNET"), "set AGOS_TEST_INTERNET=1")
    def test_browser_google(self):
        self.vm.send("browser http://www.google.com/\r")
        self.vm.expect("browser status: HTTP/1.0 200 OK | www.google.com", timeout=30)
        line = self.vm.expect(r"browser text: [^\r\n]*\r?\n", regex=True)
        self.assertRegex(line, r"browser text: \S", "something visible was drawn")
        self.assertNotIn("function", line, "script source must not be drawn")


class FontTest(unittest.TestCase):
    """tools/build.py turns kernel/gfx/font.txt into the kernel's font tables."""

    def test_font_tables(self):
        out = OUTPUT / "font.inc"
        OUTPUT.mkdir(parents=True, exist_ok=True)
        agbuild.make_font(ROOT / "kernel" / "gfx" / "font.txt", out)
        text = out.read_text()
        glyphs = re.findall(r"^    db (?:0x[0-9A-F]{2}, ){15}0x[0-9A-F]{2}  ; (\d+)$", text, re.M)
        self.assertEqual([int(c) for c in glyphs], list(range(32, 127)))
        prop = {int(c): (int(left), int(adv))
                for left, adv, c in re.findall(r"^    db (\d+), (\d+)  ; (\d+)$", text, re.M)}
        self.assertEqual(prop[ord(" ")], (0, 4), "a space is 4 pixels")
        self.assertEqual(prop[ord("i")], (1, 4), "'i' is inked in columns 1-3")
        self.assertLess(prop[ord("l")][1], prop[ord("m")][1], "proportional widths")

    def test_bad_glyph_is_reported(self):
        bad = OUTPUT / "bad_font.txt"
        OUTPUT.mkdir(parents=True, exist_ok=True)
        bad.write_text("== A\n" + "..#..\n" * 16)
        with self.assertRaisesRegex(agbuild.BuildError, "glyph 'A' needs 16 rows"):
            agbuild.make_font(bad, OUTPUT / "bad_font.inc")


if __name__ == "__main__":
    unittest.main()
