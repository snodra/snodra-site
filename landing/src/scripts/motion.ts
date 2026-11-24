const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/* Sticky header: blur and border once the page moves. */
const header = document.getElementById("site-header");
const navShell = document.getElementById("nav-shell");
const onScroll = () => {
  const scrolled = window.scrollY > 12;
  header?.classList.toggle("backdrop-blur-xl", scrolled);
  header?.classList.toggle("bg-ink/70", scrolled);
  header?.classList.toggle("border-b", scrolled);
  header?.classList.toggle("border-line", scrolled);
  navShell?.classList.toggle("bg-panel/70", scrolled);
  navShell?.classList.toggle("border-line", scrolled);
  navShell?.classList.toggle("shadow-2xl", scrolled);
};
onScroll();
window.addEventListener("scroll", onScroll, { passive: true });

/* Mobile menu. */
const menuToggle = document.getElementById("menu-toggle");
const mobileMenu = document.getElementById("mobile-menu");
menuToggle?.addEventListener("click", () => {
  const open = mobileMenu?.classList.toggle("hidden") === false;
  menuToggle.setAttribute("aria-expanded", String(open));
  menuToggle.setAttribute("aria-label", open ? "Close menu" : "Open menu");
  menuToggle.innerHTML = open
    ? '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 6 6 18"/><path d="m6 6 12 12"/></svg>'
    : '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 5h16"/><path d="M4 12h16"/><path d="M4 19h16"/></svg>';
});
mobileMenu?.querySelectorAll("a").forEach((link) =>
  link.addEventListener("click", () => {
    mobileMenu.classList.add("hidden");
    menuToggle?.setAttribute("aria-expanded", "false");
  }),
);

/* Scroll reveals. Elements opt in with data-reveal. */
const revealItems = document.querySelectorAll<HTMLElement>("[data-reveal]");
if (reduceMotion) {
  revealItems.forEach((item) => item.classList.add("is-visible"));
} else {
  const revealObserver = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const el = entry.target as HTMLElement;
        el.classList.add("is-visible");
        revealObserver.unobserve(el);
      }
    },
    { rootMargin: "0px 0px -8% 0px", threshold: 0.08 },
  );
  revealItems.forEach((item) => revealObserver.observe(item));
}

/* Counters: data-count="4" data-suffix=" stores". */
const counters = document.querySelectorAll<HTMLElement>("[data-count]");
const animateCount = (el: HTMLElement) => {
  const target = Number(el.dataset.count ?? "0");
  const suffix = el.dataset.suffix ?? "";
  if (reduceMotion) {
    el.textContent = `${target}${suffix}`;
    return;
  }
  const start = performance.now();
  const duration = 1100;
  const tick = (now: number) => {
    const progress = Math.min((now - start) / duration, 1);
    const eased = 1 - Math.pow(1 - progress, 3);
    el.textContent = `${Math.round(target * eased)}${suffix}`;
    if (progress < 1) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
};
const counterObserver = new IntersectionObserver(
  (entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      animateCount(entry.target as HTMLElement);
      counterObserver.unobserve(entry.target);
    }
  },
  { threshold: 0.6 },
);
counters.forEach((counter) => counterObserver.observe(counter));

/* Code tabs. */
document.querySelectorAll<HTMLElement>("[data-tabs]").forEach((group) => {
  const tabs = group.querySelectorAll<HTMLButtonElement>("[data-tab]");
  const panels = group.querySelectorAll<HTMLElement>("[data-panel]");
  tabs.forEach((tab) => {
    tab.addEventListener("click", () => {
      const name = tab.dataset.tab;
      tabs.forEach((t) => t.setAttribute("aria-selected", String(t === tab)));
      panels.forEach((panel) => panel.classList.toggle("hidden", panel.dataset.panel !== name));
    });
  });
});

/* Copy buttons. */
document.querySelectorAll<HTMLButtonElement>("[data-copy]").forEach((button) => {
  button.addEventListener("click", async () => {
    const target = button.dataset.copy;
    const block = target ? document.getElementById(target) : button.closest("[data-copy-source]");
    const text = block?.textContent ?? "";
    try {
      await navigator.clipboard.writeText(text.replace(/\n{3,}/g, "\n\n").trim());
      const original = button.textContent;
      button.textContent = "Copied";
      window.setTimeout(() => {
        button.textContent = original;
      }, 1600);
    } catch {
      /* clipboard unavailable */
    }
  });
});

/* A gentle pointer tilt on the hero panel. */
const tilt = document.querySelector<HTMLElement>("[data-tilt]");
if (tilt && !reduceMotion && window.matchMedia("(hover: hover) and (pointer: fine)").matches) {
  const strength = 5;
  const inner = tilt.querySelector<HTMLElement>("[data-tilt-inner]") ?? tilt;
  tilt.addEventListener("pointermove", (event) => {
    const rect = tilt.getBoundingClientRect();
    const x = (event.clientX - rect.left) / rect.width - 0.5;
    const y = (event.clientY - rect.top) / rect.height - 0.5;
    inner.style.transform = `perspective(1200px) rotateX(${(-y * strength).toFixed(2)}deg) rotateY(${(
      x * strength
    ).toFixed(2)}deg)`;
  });
  tilt.addEventListener("pointerleave", () => {
    inner.style.transform = "perspective(1200px) rotateX(0deg) rotateY(0deg)";
  });
}

/* A soft glow that follows the pointer behind the hero. */
const glow = document.querySelector<HTMLElement>("[data-pointer-glow]");
if (glow && !reduceMotion && window.matchMedia("(hover: hover) and (pointer: fine)").matches) {
  window.addEventListener(
    "pointermove",
    (event) => {
      glow.style.setProperty("--mx", `${event.clientX}px`);
      glow.style.setProperty("--my", `${event.clientY}px`);
    },
    { passive: true },
  );
}
