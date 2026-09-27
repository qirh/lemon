/**
 * Tests for the browser formatter.
 */

import { describe, expect, it } from "bun:test";
import { browserFormatter } from "../../src/formatters/browser.js";

describe("browserFormatter.formatArgs", () => {
	it("summarizes each tool by its key argument", () => {
		const cases: Array<[Record<string, unknown>, string]> = [
			[{ url: "https://example.com/docs?page=2", timeoutMs: 5000 }, "example.com/docs?page=2"],
			[{ selector: "#email", text: "a@b.c" }, '#email ← "a@b.c"'],
			[{ key: "Enter", selector: "form" }, "Enter on form"],
			[{ key: "Escape" }, "Escape"],
			[{ selector: "select#size", values: ["m", "l"] }, "select#size = m, l"],
			[{ selector: "input[type=file]", paths: ["a.png"] }, "input[type=file] ← a.png"],
			[{ selector: "button.submit" }, "button.submit"],
			[{ expression: "document.title" }, "document.title"],
			[{ targetId: "T1" }, "tab T1"],
			[{ cookies: [{ name: "a" }, { name: "b" }] }, "2 cookies"],
			[{ path: "shots/home.png", fullPage: true }, "shots/home.png"],
			[{ deltaY: 400 }, "deltaY=400"],
			[{}, ""],
		];

		for (const [args, summary] of cases) {
			expect(browserFormatter.formatArgs(args).summary).toBe(summary);
		}
	});

	it("summarizes browser_exec programs by their steps", () => {
		const result = browserFormatter.formatArgs({
			steps: [
				{ action: "navigate", args: { url: "https://example.com" } },
				{ action: "click", args: { selector: "a.more" } },
			],
		});

		expect(result.summary).toBe("2 steps: navigate → click");
		expect(result.details).toContain('1. navigate {"url":"https://example.com"}');
		expect(result.details).toContain('2. click {"selector":"a.more"}');
	});
});

describe("browserFormatter.formatResult", () => {
	it("shows page title and url after navigation", () => {
		const payload = {
			url: "https://example.com/",
			title: "Example Domain",
			tool: "browser_navigate",
		};
		const result = browserFormatter.formatResult({
			content: [{ type: "text", text: JSON.stringify(payload) }],
			details: payload,
			is_error: false,
		});

		expect(result.summary).toBe("Example Domain · example.com");
		expect(result.isError).toBe(false);
	});

	it("parses the JSON text when details are missing", () => {
		const result = browserFormatter.formatResult({
			content: [{ type: "text", text: JSON.stringify({ tabs: [{}, {}, {}] }) }],
		});

		expect(result.summary).toBe("3 tabs");
	});

	it("shows the saved screenshot path and size", () => {
		const payload = { path: "/p/.lemon/browser-artifacts/shot.png", bytes: 2048 };
		const result = browserFormatter.formatResult({
			content: [{ type: "text", text: JSON.stringify(payload) }, { type: "image" }],
			details: payload,
			is_error: false,
		});

		expect(result.summary).toBe("saved /p/.lemon/browser-artifacts/shot.png (2.0 KB)");
		expect(result.details).toContain("path: /p/.lemon/browser-artifacts/shot.png");
	});

	it("reads the nested screenshot of browser_analyze", () => {
		const result = browserFormatter.formatResult({
			content: [],
			details: { screenshot: { path: "a.png" }, analysis: { provider: "local_vision" } },
			is_error: false,
		});

		expect(result.summary).toBe("saved a.png");
	});

	it("previews snapshot text", () => {
		const result = browserFormatter.formatResult({
			content: [],
			details: { url: "https://x.dev/", snapshot: "heading Welcome\nbutton Sign in" },
			is_error: false,
		});

		expect(result.summary).toBe("x.dev");
		expect(result.details).toContain("heading Welcome");
		expect(result.details).toContain("button Sign in");
	});

	it("summarizes a completed browser_exec program", () => {
		const result = browserFormatter.formatResult({
			content: [],
			details: {
				ok: true,
				completedSteps: 2,
				results: [
					{ index: 0, action: "navigate", output: {} },
					{ index: 1, action: "snapshot", output: {} },
				],
				tool: "browser_exec",
			},
			is_error: false,
		});

		expect(result.summary).toBe("2 steps completed");
		expect(result.details).toEqual(["1. ✓ navigate", "2. ✓ snapshot"]);
		expect(result.isError).toBe(false);
	});

	it("reports the failing browser_exec step", () => {
		const result = browserFormatter.formatResult({
			content: [],
			details: {
				ok: false,
				completedSteps: 1,
				results: [{ index: 0, action: "navigate", output: {} }],
				failedStep: 1,
				failedAction: "click",
				error: "selector not found",
				tool: "browser_exec",
			},
			is_error: false,
		});

		expect(result.summary).toBe("failed at step 2 (click): selector not found");
		expect(result.isError).toBe(true);
	});

	it("marks tool errors with the error text", () => {
		const result = browserFormatter.formatResult({
			content: [{ type: "text", text: "browser navigation blocked metadata endpoint" }],
			details: {},
			is_error: true,
		});

		expect(result.summary).toBe("browser navigation blocked metadata endpoint");
		expect(result.isError).toBe(true);
	});

	it("never renders undefined for an empty payload", () => {
		const result = browserFormatter.formatResult({ content: [], details: {}, is_error: false });

		expect(result.summary).toBe("done");
		expect(result.details).toEqual([]);
	});
});

describe("browserFormatter.formatPartial", () => {
	it("shows the progress title and phase", () => {
		const result = browserFormatter.formatPartial!({
			content: [],
			details: {
				tool: "browser_click",
				method: "browser.click",
				phase: "started",
				current_action: { title: "Browser click", kind: "browser", phase: "started" },
			},
		});

		expect(result.summary).toBe("Browser click (started)");
		expect(result.isError).toBe(false);
	});
});
