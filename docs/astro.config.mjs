import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import sitemap from "@astrojs/sitemap";
import mermaid from "astro-mermaid";
import { sidebar } from "./src/sidebar.mjs";

export default defineConfig({
  site: "https://snodra.damoreira.com",
  base: "/docs",
  trailingSlash: "always",
  outDir: "dist",
  integrations: [
    starlight({
      title: "Snodra",
      description:
        "The Snodra documentation: concepts, installation, the server, the Kotlin, Rust and Go libraries, add-ons, operations and integrations.",
      logo: {
        src: "./src/assets/snodra-icon.svg",
        alt: "Snodra",
      },
      favicon: "/favicon.svg",
      social: [
        {
          icon: "github",
          label: "GitHub",
          href: "https://github.com/snodra",
        },
      ],
      editLink: {
        baseUrl: "https://github.com/snodra/snodra-site/edit/main/docs/src/content/docs/",
      },
      customCss: ["./src/styles/theme.css"],
      sidebar,
      head: [
        {
          tag: "meta",
          attrs: { name: "theme-color", content: "#07060d" },
        },
      ],
    }),
    mermaid({
      autoTheme: true,
      theme: "dark",
    }),
    sitemap(),
  ],
});
