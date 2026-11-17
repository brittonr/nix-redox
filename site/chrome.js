// Shared project navigation and theme; independent of the live guest lifecycle.
const root = document.documentElement;
const header = document.querySelector(".masthead");
const nav = header.querySelector(".nav");
const navToggle = header.querySelector(".nav-toggle");
const themeToggle = header.querySelector(".theme-toggle");
const prefersDark = matchMedia("(prefers-color-scheme: dark)");
const activeTheme = () => root.dataset.theme ?? (prefersDark.matches ? "dark" : "light");
const syncTheme = () => {
  const other = activeTheme() === "dark" ? "light" : "dark";
  const label = `Switch to ${other} theme`;
  themeToggle.setAttribute("aria-label", label);
  themeToggle.title = label;
  const paper = getComputedStyle(document.body).backgroundColor;
  for (const meta of document.querySelectorAll('meta[name="theme-color"]')) meta.content = paper;
};
themeToggle.hidden = false;
themeToggle.addEventListener("click", () => {
  const next = activeTheme() === "dark" ? "light" : "dark";
  root.dataset.theme = next;
  try { localStorage.setItem("nix-redox-theme", next); } catch {
    // The choice still applies to this page when storage is blocked.
  }
  syncTheme();
});
prefersDark.addEventListener("change", syncTheme);
syncTheme();

const setMenu = open => {
  header.classList.toggle("nav-open", open);
  navToggle.setAttribute("aria-expanded", String(open));
};
navToggle.addEventListener("click", () => {
  const open = !header.classList.contains("nav-open");
  setMenu(open);
  if (open) nav.querySelector("a").focus();
});
for (const type of ["focusin", "pointerdown"]) {
  document.addEventListener(type, event => {
    if (!header.contains(event.target)) setMenu(false);
  });
}
nav.addEventListener("click", event => {
  if (event.target.closest("a")) setMenu(false);
});
document.addEventListener("keydown", event => {
  if (event.key !== "Escape" || !header.classList.contains("nav-open")) return;
  setMenu(false);
  navToggle.focus();
});
matchMedia("(min-width: 64rem)").addEventListener("change", () => setMenu(false));
