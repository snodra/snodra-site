export type Release = {
  project: string;
  version: string;
  date: string;
  iso: string;
  summary: string;
  href: string;
  accent: "emerald" | "pink" | "teal" | "slate" | "lime";
};

export const releases: Release[] = [
  {
    project: "Snodra Server",
    version: "0.6.0",
    date: "23 Nov 2026",
    iso: "2026-11-23",
    summary:
      "The 0.6 line of the stateless router: the public protocol spec settles the hub walk, heartbeats and lock keys, and the CLI probes follow the listen address.",
    href: "https://github.com/snodra/snodra-server/releases/tag/v0.6.0",
    accent: "emerald",
  },
  {
    project: "Snodra Messaging",
    version: "0.6.1",
    date: "24 Nov 2026",
    iso: "2026-11-24",
    summary:
      "The Kotlin starter and its store add-ons at 0.6.1, with the OAuth2 identity provider documented and the released coordinates updated.",
    href: "https://github.com/snodra/snodra-messaging/releases/tag/v0.6.1",
    accent: "pink",
  },
  {
    project: "Snodra Messaging for Rust",
    version: "0.7.1",
    date: "24 Nov 2026",
    iso: "2026-11-24",
    summary:
      "The Rust crate and its Kafka, RabbitMQ, MongoDB and SQL add-ons at 0.7.1: configurable roles claim, the snodra.events topic and refreshed docs.",
    href: "https://github.com/snodra/snodra-messaging-rs/releases/tag/v0.7.1",
    accent: "teal",
  },
  {
    project: "Snodra Event Browser",
    version: "0.3.0",
    date: "24 Nov 2026",
    iso: "2026-11-24",
    summary:
      "The read-only event browser add-on at 0.3.0, aligned with the 0.6 server and shipped as an image and per-platform binaries.",
    href: "https://github.com/snodra/snodra-event-browser/releases/tag/v0.3.0",
    accent: "slate",
  },
  {
    project: "Snodra Conformance",
    version: "0.3.0",
    date: "24 Nov 2026",
    iso: "2026-11-24",
    summary:
      "The conformance runner and reference service at 0.3.0, tracking the current protocol contract with the same check ids.",
    href: "https://github.com/snodra/snodra-conformance/releases/tag/v0.3.0",
    accent: "lime",
  },
];

export const accentClasses: Record<Release["accent"], { text: string; dot: string; ring: string }> = {
  emerald: { text: "text-emerald-300", dot: "bg-emerald-400", ring: "border-emerald-400/25 bg-emerald-400/10" },
  pink: { text: "text-pink-300", dot: "bg-pink-400", ring: "border-pink-400/25 bg-pink-400/10" },
  teal: { text: "text-teal", dot: "bg-teal", ring: "border-teal/25 bg-teal/10" },
  slate: { text: "text-slate-300", dot: "bg-slate-400", ring: "border-slate-400/25 bg-slate-400/10" },
  lime: { text: "text-lime-300", dot: "bg-lime-400", ring: "border-lime-400/25 bg-lime-400/10" },
};
