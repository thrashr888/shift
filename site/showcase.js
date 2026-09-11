"use strict";

const terminal = document.getElementById("terminal");
const theme = document.getElementById("theme");
const placement = document.getElementById("placement");
const identity = document.getElementById("identity");
const identityError = document.getElementById("identity-error");
const undo = document.getElementById("undo");
const reset = document.getElementById("reset");
const appearanceNotice = document.getElementById("appearance-notice");
const notice = document.getElementById("demo-notice");
const simulate = document.getElementById("simulate");
const motion = document.getElementById("motion");
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
const narrowScreen = window.matchMedia("(max-width: 760px)");
const themeNames = { acid: "Acid Garage", paddock: "Paddock", blueprint: "Blueprint" };
const defaults = Object.freeze({ theme: "acid", placement: "bottom", identity: "shift" });
let config = { ...defaults };
const history = [];
let working = false;
let motionEnabled = true;

function renderLayout() {
  const adapted = config.placement === "right" && narrowScreen.matches;
  document.getElementById("inspector-placement").textContent = adapted
    ? "Bottom (small screen)"
    : config.placement[0].toUpperCase() + config.placement.slice(1);
  placement.options[1].textContent = narrowScreen.matches ? "Right (bottom on mobile)" : "Right";
}

function render(syncIdentity = true) {
  document.documentElement.dataset.theme = config.theme;
  terminal.dataset.placement = config.placement;
  theme.value = config.theme;
  placement.value = config.placement;
  if (syncIdentity) {
    identity.value = config.identity;
    identityError.textContent = "";
    identity.removeAttribute("aria-invalid");
  }
  document.querySelectorAll("[data-display-name]").forEach((element) => {
    element.textContent = config.identity;
    element.title = config.identity;
  });
  document.querySelectorAll("[data-brand-link]").forEach((link) => {
    link.setAttribute("aria-label", `${config.identity} home — Shift showcase`);
  });
  document.title = config.identity === defaults.identity
    ? "Shift — an agent, made yours."
    : `${config.identity} — made yours | Shift`;
  document.querySelector('meta[name="theme-color"]').content =
    getComputedStyle(document.documentElement).getPropertyValue("--bg").trim();
  document.getElementById("theme-name").textContent = themeNames[config.theme].toUpperCase();
  document.getElementById("inspector-theme").textContent = themeNames[config.theme];
  document.getElementById("inspector").hidden = config.placement === "hidden";
  undo.disabled = history.length === 0;
  renderLayout();
}

function apply(patch, message, status = appearanceNotice) {
  if (Object.entries(patch).every(([key, value]) => config[key] === value)) {
    render(Object.hasOwn(patch, "identity"));
    status.textContent = "Already using that setting. Try another change.";
    return;
  }
  history.push({ ...config });
  if (history.length > 50) history.shift();
  config = { ...config, ...patch };
  render(Object.hasOwn(patch, "identity"));
  status.textContent = message;
}

theme.addEventListener("change", () => {
  apply({ theme: theme.value }, `${themeNames[theme.value]} applied across the whole site and terminal preview.`);
});
placement.addEventListener("change", () => {
  apply({ placement: placement.value }, "Demo inspector updated. Undo is available in site appearance above.", notice);
});
document.getElementById("identity-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const value = identity.value.trim();
  if (!value || value.length > 24 || /[\u0000-\u001f\u007f-\u009f]/u.test(value)) {
    identityError.textContent = "Use 1–24 visible, printable characters.";
    identity.setAttribute("aria-invalid", "true");
    identity.focus();
    return;
  }
  identityError.textContent = "";
  identity.removeAttribute("aria-invalid");
  apply({ identity: value }, `Made yours: ${value}. Display branding updated; Shift commands and links are unchanged.`);
});
identity.addEventListener("input", () => {
  identityError.textContent = "";
  identity.removeAttribute("aria-invalid");
});
undo.addEventListener("click", () => {
  if (history.length === 0) return;
  config = history.pop();
  identityError.textContent = "";
  identity.removeAttribute("aria-invalid");
  render();
  appearanceNotice.textContent = "Previous site and demo appearance restored. Undo history lasts until you reload.";
  if (undo.disabled) theme.focus();
});
reset.addEventListener("click", () => {
  identityError.textContent = "";
  identity.removeAttribute("aria-invalid");
  apply(
    { theme: defaults.theme, identity: defaults.identity },
    "Original Shift appearance restored. Demo layout and work state are unchanged. You can undo this reset."
  );
});

function renderMotion() {
  const enabled = motionEnabled && !reducedMotion.matches;
  motion.checked = enabled;
  motion.disabled = reducedMotion.matches;
  motion.title = reducedMotion.matches ? "Animation disabled by your system’s reduced-motion preference." : "";
  terminal.dataset.motion = String(enabled);
}

simulate.addEventListener("click", () => {
  working = !working;
  terminal.dataset.working = String(working);
  simulate.setAttribute("aria-pressed", String(working));
  simulate.replaceChildren(document.createTextNode(working ? "Stop simulation" : "Simulate work"));
  const mark = document.createElement("span");
  mark.setAttribute("aria-hidden", "true");
  mark.textContent = "///";
  simulate.append(mark);
  document.getElementById("work-state").textContent = working ? "WORKING" : "READY";
  notice.textContent = working
    ? "Simulated work only. No requests, tools, or model calls are running."
    : "Simulation stopped. The busy mark is now still.";
});
motion.addEventListener("change", () => {
  motionEnabled = motion.checked;
  renderMotion();
});
reducedMotion.addEventListener("change", renderMotion);
narrowScreen.addEventListener("change", renderLayout);

let intersecting = false;
function renderVisibility() {
  terminal.dataset.visible = String(intersecting && !document.hidden);
}
const observer = new IntersectionObserver(([entry]) => {
  intersecting = entry.isIntersecting;
  renderVisibility();
});
observer.observe(document.querySelector(".slashes"));
document.addEventListener("visibilitychange", renderVisibility);

// Make horizontally scrollable code examples keyboard-reachable only when needed.
const codeObserver = new ResizeObserver((entries) => {
  for (const { target } of entries) {
    if (target.scrollWidth > target.clientWidth) target.tabIndex = 0;
    else target.removeAttribute("tabindex");
  }
});
document.querySelectorAll("pre").forEach((block) => codeObserver.observe(block));

render();
renderMotion();
document.getElementById("appearance").hidden = false;
document.getElementById("demo-controls").hidden = false;
document.getElementById("motion-controls").hidden = false;
