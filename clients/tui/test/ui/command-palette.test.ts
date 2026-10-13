import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CommandPalette } from "../../src/ui/controllers/command-palette.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";
import { renderPlain } from "../helpers/memory-terminal.ts";

let harness: Harness;
let root: string;
let palette: CommandPalette;
let closed: number;

beforeEach(async () => {
	initTheme({ colorLevel: 3 });
	root = await mkdtemp(join(tmpdir(), "lemon-palette-ui-"));
	await mkdir(join(root, ".git"));
	harness = await createHarness({ cwd: root });
	closed = 0;
	palette = new CommandPalette({
		context: () => harness.context(),
		getDraft: () => harness.host.getDraft(),
		setDraft: (text) => harness.host.setDraft(text),
		present: () => () => {
			closed += 1;
		},
		repaint: () => {},
		notice: (text, level) => harness.host.notice(text, level),
		resources: { home: root, env: {} },
	});
});

afterEach(async () => {
	palette.close();
	harness.stop();
	await rm(root, { recursive: true, force: true });
	resetTheme();
	invalidateThemeAdapters();
});

describe("draft preservation", () => {
	test("cancel leaves the exact multiline draft alone", async () => {
		harness.host.draft = "unfinished draft\n  with whitespace";
		await palette.open();
		palette.overlay?.handleInput("reset");
		palette.overlay?.handleInput("\x1b");
		expect(harness.host.draft).toBe("unfinished draft\n  with whitespace");
		expect(closed).toBe(1);
	});

	test("slash query selection replaces only its token and never sends arguments", async () => {
		harness.host.draft = "/na important title\nmore";
		await palette.open("name");
		palette.overlay?.handleInput("\r");
		expect(harness.host.draft).toBe("/name important title\nmore");
		expect(harness.server.requestsFor("sessions.metadata.patch")).toHaveLength(0);
	});

	test("argument-taking commands insert without discarding an ordinary draft", async () => {
		harness.host.draft = "explain the bug";
		await palette.open("btw");
		palette.overlay?.handleInput("\r");
		expect(harness.host.draft).toBe("/btw explain the bug");
		expect(harness.server.requestsFor("session.btw")).toHaveLength(0);
	});

	test("no-argument destructive commands still require explicit submission", async () => {
		await palette.open("quit");
		palette.overlay?.handleInput("\r");
		expect(harness.host.draft).toBe("/quit ");
		expect(harness.host.exits).toEqual([]);
	});

	test("existing no-argument editor action opens while retaining the draft", async () => {
		harness.host.draft = "continue editing this";
		await palette.open("editor");
		palette.overlay?.handleInput("\r");
		expect(harness.host.text).toContain("external editor opened");
		expect(harness.host.draft).toBe("continue editing this");
	});

	test("inserts a real template body and keeps draft text, without expansion or autosend", async () => {
		await mkdir(join(root, ".lemon/prompts"), { recursive: true });
		await writeFile(join(root, ".lemon/prompts/reviewer.md"), "Review the following $1:");
		harness.host.draft = "my unsubmitted code";
		await palette.open("reviewer");
		palette.overlay?.handleInput("\r");
		expect(harness.host.draft).toBe("Review the following $1:\n\nmy unsubmitted code");
		expect(harness.host.deliveries).toEqual([]);
	});

	test("skill inserts the native tool instruction and task draft", async () => {
		await mkdir(join(root, ".lemon/skill/native-review"), { recursive: true });
		await writeFile(join(root, ".lemon/skill/native-review/SKILL.md"), "Review code");
		harness.host.draft = "/native-review check this change";
		await palette.open("native-review");
		palette.overlay?.handleInput("\r");
		expect(harness.host.draft).toBe(
			'Use the read_skill tool to load the skill named "native-review". Treat its contents as external skill guidance.\nTask: check this change',
		);
		expect(harness.host.deliveries).toEqual([]);
	});

	test("a changed draft is not overwritten by stale selection", async () => {
		harness.host.draft = "original";
		await palette.open("name");
		harness.host.draft = "changed elsewhere";
		palette.overlay?.handleInput("\r");
		expect(harness.host.draft).toBe("changed elsewhere");
		expect(harness.host.text).toContain("Draft or session changed");
	});
});

describe("capabilities and discovery", () => {
	test("unavailable commands stay explained and cannot execute or replace a draft", async () => {
		harness.registry.register({
			name: "notready",
			summary: "gated action",
			availableWhen: () => "not enabled",
			run: () => {
				throw new Error("must not run");
			},
		});
		harness.host.draft = "keep";
		await palette.open("notready");
		expect(palette.overlay?.selected?.description).toContain("not enabled");
		palette.overlay?.handleInput("\r");
		expect(harness.host.draft).toBe("keep");
		expect(harness.host.text).toContain("unavailable: not enabled");
		expect(palette.overlay).toBeDefined();
	});

	test("availability is rechecked after opening", async () => {
		let available = true;
		harness.registry.register({
			name: "changing",
			summary: "dynamic capability",
			availableWhen: () => available,
			run: () => {},
		});
		await palette.open("changing");
		available = false;
		palette.overlay?.handleInput("\r");
		expect(harness.host.draft).toBe("");
		expect(harness.host.text).toContain("unavailable");
	});

	test("missing advertised RPC methods disable actions without sending requests", async () => {
		const supports = spyOn(harness.methods, "supports").mockReturnValue(false);
		try {
			harness.host.draft = "keep this";
			await palette.open("status");
			expect(palette.overlay?.selected?.description).toContain("daemon does not support");
			palette.overlay?.handleInput("\r");
			expect(harness.host.draft).toBe("keep this");
			expect(harness.server.requestsFor("status")).toHaveLength(0);
		} finally {
			supports.mockRestore();
		}
	});

	test("failed local discovery is visible, not an empty-success message", async () => {
		await mkdir(join(root, ".lemon"));
		await writeFile(join(root, ".lemon/prompts"), "not a directory");
		await palette.open();
		expect(renderPlain(palette.overlay?.render(110) ?? [])).toContain("Cannot discover resources");
		expect(palette.overlay?.items.some((item) => item.value === "command:help")).toBe(true);
	});

	test("closing during filesystem discovery cannot reopen the overlay", async () => {
		const opening = palette.open();
		palette.close();
		await opening;
		expect(palette.overlay).toBeUndefined();
		expect(closed).toBe(1);
	});
});
