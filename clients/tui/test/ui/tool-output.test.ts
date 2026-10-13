import { afterEach, beforeEach, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import type { ToolBlock } from "../../src/store/transcript-model.ts";
import { ToolOutputComponent } from "../../src/ui/components/tool-output.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { renderPlain } from "../helpers/memory-terminal.ts";

beforeEach(() => initTheme({ colorLevel: 3 }));
afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});
const base: ToolBlock = {
	id: "tool-1",
	kind: "tool",
	at: 1,
	runId: "run",
	actionId: "a",
	toolKind: "file_change",
	title: "edit change.ts",
	phase: "completed",
	ok: true,
	message: undefined,
	detail: undefined,
};

test("the diff viewer reaches lines beyond the card's 24-row preview and switches to the original receipt", () => {
	const block: ToolBlock = {
		...base,
		detail: {
			name: "edit",
			args: { path: "change.ts" },
			result: "Changed one hundred lines",
			details: {
				diff: Array.from({ length: 100 }, (_, index) => `+${index + 1}\tnew-${index + 1}`).join(
					"\n",
				),
			},
		},
	};
	const view = new ToolOutputComponent(block, {
		rows: () => 12,
		close: () => {},
		repaint: () => {},
		mode: "diff",
	});
	expect(renderPlain(view.render(80))).toContain("new-1");
	view.handleInput("G");
	expect(renderPlain(view.render(80))).toContain("new-100");
	expect(view.totalRows).toBe(100);
	view.handleInput("d");
	expect(renderPlain(view.render(80))).toContain("Changed one hundred lines");
	expect(view.mode).toBe("output");
});

test("raw output is scrollable, width bounded and cannot inject terminal control sequences", () => {
	const output = Array.from({ length: 80 }, (_, index) => `line-${index} ${"界".repeat(30)}`).join(
		"\n",
	);
	const view = new ToolOutputComponent(
		{ ...base, detail: { name: "bash", result: `\x1b]0;INJECTED_TITLE\x07${output}` } },
		{ rows: () => 10, close: () => {}, repaint: () => {} },
	);
	view.render(20);
	view.handleInput("G");
	const rows = view.render(20);
	expect(rows.length).toBeLessThanOrEqual(10);
	expect(rows.every((row) => visibleWidth(row) <= 20)).toBe(true);
	expect(rows.join("\n")).not.toContain("INJECTED_TITLE");
	expect(view.offset).toBeGreaterThan(70);
	view.handleInput("g");
	expect(renderPlain(view.render(20))).toContain("line-0");
});
