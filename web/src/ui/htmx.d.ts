/**
 * Merge typed-htmx's `HtmxAttributes` into Hono's JSX `HTMLAttributes` so
 * `hx-get`, `hx-post`, `hx-swap`, etc. are type-checked on every element.
 * See https://github.com/Desdaemon/typed-htmx
 */
import "typed-htmx";

declare module "hono/jsx" {
  namespace JSX {
    interface HTMLAttributes extends HtmxAttributes {}
  }
}
