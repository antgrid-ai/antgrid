import { satteriHeadingIdsPlugin } from "@astrojs/markdown-satteri";
import { getBlogImageOptions } from "./blog-image-options.mjs";

// Allocate the slugger per document, before adding links that change heading text.
export default function blogMarkdown() {
  return [satteriHeadingIdsPlugin(), {
    name: "blog-accessibility",
    element: { filter: ["h2", "h3", "h4", "h5", "h6", "pre", "table", "img"], visit(node, ctx) {
      if (node.tagName === "img") {
        const { src, alt } = node.properties ?? {};
        if (typeof src !== "string" || !/^\.\.?\//.test(src)) throw new Error("Blog body images must use paths relative to the article, outside public/");
        if (typeof alt !== "string" || !alt.trim()) throw new Error("Blog body images require meaningful alternative text");
        // Raw HTML figures bypass Markdown's image collector; register them before Astro's image-marker plugin runs.
        ctx.data.astro.localImagePaths.add(decodeURI(src));
        const sourceFormat = decodeURI(src).split(/[?#]/, 1)[0].split(".").at(-1) ?? "";
        for (const [key, value] of Object.entries({ ...getBlogImageOptions(sourceFormat), loading: "lazy", decoding: "async" })) ctx.setProperty(node, key, value);
      }
      if (/^h[2-6]$/.test(node.tagName) && node.properties?.id) {
        ctx.appendChild(node, { type: "element", tagName: "a", properties: { href: `#${node.properties.id}`, className: ["heading-anchor"], ariaLabel: `Link to ${ctx.textContent(node)}` }, children: [{ type: "text", value: "#" }] });
      }
      if (node.tagName === "pre") {
        ctx.setProperty(node, "tabIndex", 0);
        ctx.setProperty(node, "ariaLabel", "Code example");
      }
      if (node.tagName === "table") ctx.wrapNode(node, { type: "element", tagName: "div", properties: { className: ["table-scroll"], tabIndex: 0, role: "region", ariaLabel: "Scrollable table" }, children: [] });
    } },
  }];
}
