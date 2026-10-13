import { afterEach, beforeEach, expect, test } from "bun:test";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { TERMINAL } from "@oh-my-pi/pi-tui/terminal-capabilities";
import { fixtureBlock, fixtureByName } from "../src/dev/fixtures/tool-fixtures.ts";
import type { ToolBlock } from "../src/store/transcript-model.ts";
import { fileTarget, toolLocation } from "../src/terminal/links.ts";
import { accordionSettings } from "../src/ui/components/accordion.ts";
import { ToolCardComponent } from "../src/ui/components/tool-card.ts";
import { initTheme, resetTheme } from "../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../src/ui/theme/tui-adapters.ts";

let hyperlinks: boolean;
beforeEach(() => {
	hyperlinks = TERMINAL.hyperlinks;
	TERMINAL.hyperlinks = true;
	accordionSettings.reset();
	initTheme({ colorLevel: 3 });
});
afterEach(() => {
	TERMINAL.hyperlinks = hyperlinks;
	accordionSettings.reset();
	resetTheme();
	invalidateThemeAdapters();
});

function block(
	name: string,
	args: Record<string, unknown>,
	details: Record<string, unknown> = {},
): ToolBlock {
	const fixture = fixtureByName(name);
	if (!fixture) throw new Error(`no fixture ${name}`);
	return fixtureBlock({ ...fixture, completed: { name, args, details, result: "" } }, "success");
}

function expectTarget(tool: ToolBlock, path: string, line?: number): void {
	const url = pathToFileURL(resolve(path));
	if (line !== undefined) url.hash = `L${line}`;
	const card = new ToolCardComponent(tool);
	const native = card.describe();
	if (native.k !== "tool") throw new Error("expected native tool node");
	expect(native.p?.target).toBe(path);
	expect(native.p?.targetKind).toBe("path");
	expect(native.p?.href).toBe(url.href);
	expect(card.render(240).join("\n")).toContain(`\x1b]8;;${url.href}\x07`);
	card.setCompact(true);
	expect(card.render(240).join("\n")).toContain(`\x1b]8;;${url.href}\x07`);
}

test("native edit receipt and both row forms link the tool's actual changed line", () => {
	const fixture = fixtureByName("edit");
	if (!fixture) throw new Error("no edit fixture");
	expectTarget(fixtureBlock(fixture, "success"), "clients/tui/src/store/transcript-model.ts", 121);
});

test("result paths win over relative arguments; read offsets and file_path reach native links", () => {
	expectTarget(
		block(
			"edit",
			{ path: "other.ts", offset: 2 },
			{
				path: "/repo/日本語 space#file.ts",
				first_changed_line: 42,
			},
		),
		"/repo/日本語 space#file.ts",
		42,
	);
	expectTarget(block("read", { file_path: "src/read me.ts", offset: 17 }), "src/read me.ts", 17);
	expectTarget(
		block("write", {}, { path: "/repo/new.ts", oldText: null, newText: "new\n" }),
		"/repo/new.ts",
		1,
	);
});

test("structured paths with fragment-like names stay literal, with controls rejected", () => {
	expectTarget(
		block("edit", { path: "src/name#L42" }, { first_changed_line: 7 }),
		"src/name#L42",
		7,
	);
	expectTarget(block("read", { path: "src/name:42" }), "src/name:42");
	for (const path of ["bad\x1b]9;inject\x07", "bad\nfile", "bad\u009b31m"]) {
		const tool = block("edit", { path }, { first_changed_line: 42 });
		expect(toolLocation(tool)).toBeUndefined();
		expect(fileTarget(path, 42)).toBeUndefined();
		const native = new ToolCardComponent(tool).describe();
		expect(native.p?.href).toBeUndefined();
	}
});

test("patch receipts use the first surviving destination and its bounded snapshot line", () => {
	expectTarget(
		block(
			"patch",
			{},
			{
				changed: ["/repo/deleted.ts", "/repo/moved #日本語.ts", "/repo/other.ts"],
				perFileResults: [
					{ path: "/repo/deleted.ts", oldText: "old\n", newText: null },
					{ path: "/repo/old-name.ts", oldText: "old\n", newText: null },
					{
						path: "/repo/moved #日本語.ts",
						oldText: "one\ntwo\nold\n",
						newText: "one\ntwo\nnew\n",
					},
					{ path: "/repo/other.ts", oldText: "old\n", newText: "new\n" },
				],
			},
		),
		"/repo/moved #日本語.ts",
		3,
	);
	expectTarget(block("patch", {}, { changed: ["/repo/large.ts"] }), "/repo/large.ts");
	expect(
		toolLocation(
			block(
				"patch",
				{},
				{
					changed: ["/repo/deleted.ts"],
					perFileResults: [{ path: "/repo/deleted.ts", oldText: "old", newText: null }],
				},
			),
		),
	).toBeUndefined();
});

test("invalid line metadata is ignored without dropping a valid read offset", () => {
	for (const first_changed_line of [0, -1, 1.5, Number.NaN, Number.POSITIVE_INFINITY, "42"]) {
		expectTarget(
			block("read", { path: "src/read.ts", offset: 9 }, { first_changed_line }),
			"src/read.ts",
			9,
		);
	}
});

test("unstructured result prose never becomes a file target", () => {
	const tool = block("patch", { patch: "*** Update File: /repo/guess.ts\n@@\n-old\n+new" });
	tool.detail = { ...tool.detail, result: "Edited /repo/guess.ts:42 successfully" };
	expect(toolLocation(tool)).toBeUndefined();
	const native = new ToolCardComponent(tool).describe();
	expect(native.p?.href).toBeUndefined();
});
