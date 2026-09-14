import { expect, test } from "bun:test";
import { SALESIQ_CONTROLLER_SCRIPT } from "../../src/ui/salesiq.js";

test("a failed widget request can be retried without reloading the page", async () => {
  const listeners = new Map<string, (event: any) => void>();
  let appended = 0;
  const button = {
    dataset: {
      salesiqWidgetUrl: "https://salesiq.zohopublic.com/widget",
      salesiqUserId: "user-1",
      salesiqUserEmail: "gita@example.com",
    },
    disabled: false,
  };
  const document = {
    addEventListener(type: string, listener: (event: any) => void) {
      listeners.set(type, listener);
    },
    createElement() {
      return { remove() {} } as {
        id: string;
        src: string;
        defer: boolean;
        remove: () => void;
        onload?: () => void;
        onerror?: () => void;
      };
    },
    head: {
      appendChild(script: { onerror?: () => void }) {
        appended += 1;
        queueMicrotask(() => script.onerror?.());
      },
    },
  };
  const window = {};
  new Function("window", "document", SALESIQ_CONTROLLER_SCRIPT)(window, document);
  const click = listeners.get("click");
  const event = { target: { closest: () => button } };

  click?.(event);
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(button.disabled).toBe(false);
  click?.(event);
  await new Promise((resolve) => setTimeout(resolve, 0));

  expect(appended).toBe(2);
});

test("clicking while the chat window is open closes it instead of reopening", () => {
  const listeners = new Map<string, (event: any) => void>();
  const attrs: Record<string, string> = {};
  const calls: string[] = [];
  let open = false;
  const button = {
    dataset: { salesiqWidgetUrl: "https://salesiq.zohopublic.com/widget" },
    disabled: false,
    setAttribute(name: string, value: string) {
      attrs[name] = value;
    },
  };
  const document = {
    addEventListener(type: string, listener: (event: any) => void) {
      listeners.set(type, listener);
    },
    // Zoho marks its own wrapper open; the controller reads that rather than
    // tracking state the widget can change from inside its iframe.
    querySelector(selector: string) {
      return selector === "#zsiq_chat_wrap.chat-iframe-open" && open ? {} : null;
    },
  };
  const window = {
    $zoho: {
      salesiq: {
        chatwindow: {
          visible(value: string) {
            calls.push(value);
            open = value === "show";
          },
        },
      },
    },
  };
  new Function("window", "document", SALESIQ_CONTROLLER_SCRIPT)(window, document);
  const click = listeners.get("click");
  const event = { target: { closest: () => button } };

  click?.(event);
  expect(attrs["aria-expanded"]).toBe("true");
  click?.(event);

  expect(calls).toEqual(["show", "hide"]);
  expect(attrs["aria-expanded"]).toBe("false");
});
