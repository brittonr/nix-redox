// nix-redox landing page behavior: theme, copy buttons, tabs, section
// navigation, code tinting and lazily mounted asciinema players. The page
// stays readable without this file; see the html:not(.js) rules in style.css.
(() => {
  "use strict";

  const root = document.documentElement;
  const $ = (selector, scope = document) => scope.querySelector(selector);
  const $$ = (selector, scope = document) => [...scope.querySelectorAll(selector)];
  const live = $("#live");

  // ── Theme ──────────────────────────────────────────────────────────
  // The inline script in <head> applies a stored choice before first paint.
  const THEME_KEY = "nix-redox-theme";
  const prefersDark = matchMedia("(prefers-color-scheme: dark)");
  const themeToggle = $(".theme-toggle");
  const activeTheme = () => root.dataset.theme ?? (prefersDark.matches ? "dark" : "light");

  const syncTheme = () => {
    const other = activeTheme() === "dark" ? "light" : "dark";
    themeToggle.setAttribute("aria-label", `Switch to ${other} theme`);
    const paper = getComputedStyle(document.body).backgroundColor;
    for (const meta of $$('meta[name="theme-color"]')) meta.content = paper;
  };

  themeToggle.addEventListener("click", () => {
    const next = activeTheme() === "dark" ? "light" : "dark";
    root.dataset.theme = next;
    try {
      localStorage.setItem(THEME_KEY, next);
    } catch {
      // Storage is blocked: the choice still applies to this page view.
    }
    syncTheme();
  });
  prefersDark.addEventListener("change", syncTheme);
  syncTheme();

  // ── Copy buttons ───────────────────────────────────────────────────
  document.addEventListener("click", async (event) => {
    const button = event.target.closest(".copy");
    if (!button) return;
    const command = $(".cmd-text", button.closest(".cmd"));
    try {
      await navigator.clipboard.writeText(command.textContent);
    } catch {
      // No clipboard access: select the command so a manual copy is one key away.
      getSelection().selectAllChildren(command);
      live.textContent = "Clipboard unavailable. The command is selected, ready to copy.";
      return;
    }
    const label = $(".copy-label", button);
    const icon = $("use", button);
    button.classList.add("is-copied");
    icon.setAttribute("href", "#i-check");
    label.textContent = "Copied";
    live.textContent = "Command copied to clipboard.";
    setTimeout(() => {
      button.classList.remove("is-copied");
      icon.setAttribute("href", "#i-copy");
      label.textContent = "Copy";
      live.textContent = "";
    }, 1600);
  });

  // ── Tabs ───────────────────────────────────────────────────────────
  for (const group of $$("[data-tabs]")) {
    const tabs = $$('[role="tab"]', group);
    const select = (tab) => {
      for (const candidate of tabs) {
        const selected = candidate === tab;
        candidate.setAttribute("aria-selected", selected);
        candidate.tabIndex = selected ? 0 : -1;
        document.getElementById(candidate.getAttribute("aria-controls")).classList.toggle("is-active", selected);
      }
    };
    group.addEventListener("click", (event) => {
      const tab = event.target.closest('[role="tab"]');
      if (tab) select(tab);
    });
    group.addEventListener("keydown", (event) => {
      const index = tabs.indexOf(event.target);
      if (index < 0) return;
      const last = tabs.length - 1;
      const next = {
        ArrowRight: index === last ? 0 : index + 1,
        ArrowLeft: index === 0 ? last : index - 1,
        Home: 0,
        End: last,
      }[event.key];
      if (next === undefined) return;
      event.preventDefault();
      select(tabs[next]);
      tabs[next].focus();
    });
  }

  // ── Section navigation ─────────────────────────────────────────────
  const masthead = $(".masthead");
  const nav = $(".nav");
  const navToggle = $(".nav-toggle");
  const setMenu = (open) => {
    masthead.classList.toggle("nav-open", open);
    navToggle.setAttribute("aria-expanded", open);
  };
  // The links come before the button in the document, so opening the menu moves
  // focus to the first one instead of leaving Tab to skip past them.
  navToggle.addEventListener("click", () => {
    const open = !masthead.classList.contains("nav-open");
    setMenu(open);
    if (open) $("a", nav).focus();
  });
  // Leaving the masthead, by focus or by pointer, closes the menu rather than
  // letting the page scroll or take focus behind it.
  for (const type of ["focusin", "pointerdown"]) {
    document.addEventListener(type, (event) => {
      if (!masthead.contains(event.target)) setMenu(false);
    });
  }
  nav.addEventListener("click", (event) => {
    if (event.target.closest("a")) setMenu(false);
  });
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || !masthead.classList.contains("nav-open")) return;
    setMenu(false);
    navToggle.focus();
  });

  // Mark the link of whichever section crosses a line just above mid-viewport.
  const navLinks = new Map($$("a", nav).map((link) => [link.hash.slice(1), link]));
  const spy = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        for (const link of navLinks.values()) link.removeAttribute("aria-current");
        navLinks.get(entry.target.id)?.setAttribute("aria-current", "true");
      }
    },
    { rootMargin: "-45% 0px -55% 0px" },
  );
  for (const section of $$("main > section")) spy.observe(section);

  // ── Code tinting: strings and comments only ────────────────────────
  const escapeHtml = (text) => text.replace(/[&<>]/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[char]);
  for (const code of $$(".code code")) {
    code.innerHTML = escapeHtml(code.textContent).replace(
      // A "#" only starts a comment after whitespace, so ".#attr" flake refs stay intact.
      /("(?:[^"\\]|\\.)*")|(^|\s)(#.*)$/gm,
      (match, string, space, comment) =>
        string ? `<span class="s">${string}</span>` : `${space}<span class="c">${comment}</span>`,
    );
  }

  // ── Recordings ─────────────────────────────────────────────────────
  // The player (about 200 kB) loads when a recording nears the viewport. Until
  // then, and if loading fails, each container keeps its plain MP4 link.
  const PLAYER = "assets/asciinema/asciinema-player.min";
  const loadAsset = (tag, attributes) =>
    new Promise((resolve, reject) => {
      const element = Object.assign(document.createElement(tag), attributes, { onload: resolve, onerror: reject });
      document.head.append(element);
    });
  let playerAssets;
  const loadPlayer = () =>
    (playerAssets ??= Promise.all([
      loadAsset("link", { rel: "stylesheet", href: `${PLAYER}.css` }),
      loadAsset("script", { src: `${PLAYER}.js` }),
    ]));

  // The terminals use the page's monospace stack. The player measures glyphs
  // when it mounts, so the web font has to be loaded first.
  const monoFont = getComputedStyle(root).getPropertyValue("--font-mono").trim();

  const mountPlayer = async (container) => {
    await Promise.all([loadPlayer(), document.fonts.load(`1em ${monoFont}`)]);
    container.replaceChildren();
    container.classList.add("is-ready");
    AsciinemaPlayer.create(container.dataset.cast, container, {
      cols: 120,
      rows: 40,
      fit: "width",
      theme: "nix-redox",
      terminalFontFamily: monoFont,
      poster: `npt:${container.dataset.poster}`,
      preload: true,
    });
  };

  const recordings = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        recordings.unobserve(entry.target);
        mountPlayer(entry.target).catch(() => {});
      }
    },
    { rootMargin: "50% 0px" },
  );
  for (const container of $$(".player")) recordings.observe(container);
})();
