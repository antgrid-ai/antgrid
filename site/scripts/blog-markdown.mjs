import { satteriHeadingIdsPlugin } from "@astrojs/markdown-satteri";

// Allocate the slugger per document, before adding links that change heading text.
export default function blogMarkdown() {
  return [satteriHeadingIdsPlugin(), {
    name: "blog-accessibility",
    element: { filter: ["h2", "h3", "h4", "h5", "h6", "pre", "table"], visit(node, ctx) {
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
