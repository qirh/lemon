/**
 * The editor's key policy, driven the way the terminal drives it: raw bytes
 * into `handleInput`.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { DescribeContext, NativeNode } from "@oh-my-pi/pi-tui/native/node";
import { ComposerDrafts } from "../../src/composer/drafts.ts";
import { imageFromBytes } from "../../src/composer/images.ts";
import {
	type ComposerNativeState,
	CustomEditor,
	ESC_DISCARD_MS,
	EXIT_CONFIRM_MS,
} from "../../src/ui/components/custom-editor.ts";
import { StatusBar, type StatusBarData } from "../../src/ui/components/status-bar.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { getEditorTheme, invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";

const CTRL_C = "\x03";
const CTRL_D = "\x04";
const CTRL_G = "\x07";
const ESC = "\x1b";
const UP = "\x1b[A";
const DOWN = "\x1b[B";
const ENTER = "\r";

interface Recorded {
	editor: CustomEditor;
	submitted: string[];
	notices: string[];
	quits: number[];
	aborts: number;
	edits: number;
	setNow: (value: number) => void;
	setRunning: (running: boolean) => void;
}

function makeEditor(): Recorded {
	const submitted: string[] = [];
	const notices: string[] = [];
	const quits: number[] = [];
	let aborts = 0;
	let edits = 0;
	let now = 1_000_000;
	let running = false;

	const editor = new CustomEditor({
		theme: getEditorTheme(),
		onSubmit: (text) => {
			submitted.push(text);
		},
		onAbort: () => {
			if (!running) return false;
			aborts += 1;
			return true;
		},
		onQuit: (code) => quits.push(code),
		onExternalEdit: () => {
			edits += 1;
		},
		notice: (text) => notices.push(text),
		now: () => now,
	});

	return {
		editor,
		submitted,
		notices,
		quits,
		get aborts() {
			return aborts;
		},
		get edits() {
			return edits;
		},
		setNow: (value: number) => {
			now = value;
		},
		setRunning: (value: boolean) => {
			running = value;
		},
	} as Recorded;
}

beforeEach(() => {
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

test("native delegation preserves drafts and waits for submission readiness", async () => {
	const submitted: string[] = [];
	let ready = false;
	const pending = Promise.withResolvers<void>();
	const settled = Promise.withResolvers<void>();
	const editor = new CustomEditor({
		theme: getEditorTheme(),
		canSubmit: () => ready,
		onSubmit: async (text) => {
			submitted.push(text);
			await pending.promise;
		},
		requestRender: () => {
			if (submitted.length === 1 && editor.getText() === "") settled.resolve();
		},
	});
	editor.setText("human draft");
	const prompt = { type: "send" as const, key: "", text: "delegated prompt" };
	editor.handleNativeEvent(prompt);
	expect(submitted).toEqual([]);
	expect(editor.getText()).toBe("human draft");
	ready = true;
	editor.handleNativeEvent({ ...prompt, text: "   " });
	expect(editor.getText()).toBe("human draft");
	editor.handleNativeEvent(prompt);
	expect(submitted).toEqual(["delegated prompt"]);
	expect(editor.history).toEqual(["human draft", "delegated prompt"]);
	editor.handleNativeEvent({ ...prompt, text: "concurrent duplicate" });
	expect(submitted).toHaveLength(1);
	pending.resolve();
	await settled.promise;
});

describe("typing and submitting", () => {
	test("plain text reaches the buffer and Enter submits it", () => {
		const h = makeEditor();
		h.editor.handleInput("hi");
		expect(h.editor.getText()).toBe("hi");
		h.editor.handleInput(ENTER);
		expect(h.submitted).toEqual(["hi"]);
		expect(h.editor.getText()).toBe("");
	});

	test("an empty submission is dropped", () => {
		const h = makeEditor();
		h.editor.handleInput(ENTER);
		expect(h.submitted).toEqual([]);
	});

	test("submitted prompts join the recall ring", () => {
		const h = makeEditor();
		h.editor.handleInput("first");
		h.editor.handleInput(ENTER);
		expect(h.editor.history).toEqual(["first"]);
	});
});

describe("Ctrl+C", () => {
	test("clears a non-empty draft without quitting", () => {
		const h = makeEditor();
		h.editor.handleInput("half a thought");
		h.editor.handleInput(CTRL_C);
		expect(h.editor.getText()).toBe("");
		expect(h.quits).toEqual([]);
		// The cleared draft is recoverable.
		expect(h.editor.history).toEqual(["half a thought"]);
	});

	test("aborts a live run when the draft is empty", () => {
		const h = makeEditor();
		h.setRunning(true);
		h.editor.handleInput(CTRL_C);
		expect(h.aborts).toBe(1);
		expect(h.quits).toEqual([]);
	});

	test("twice in a row quits when nothing is running", () => {
		const h = makeEditor();
		h.editor.handleInput(CTRL_C);
		expect(h.notices).toContain("press Ctrl+C again to quit");
		expect(h.quits).toEqual([]);
		h.editor.handleInput(CTRL_C);
		expect(h.quits).toEqual([0]);
	});

	test("the confirm window expires", () => {
		const h = makeEditor();
		h.editor.handleInput(CTRL_C);
		h.setNow(1_000_000 + EXIT_CONFIRM_MS + 1);
		h.editor.handleInput(CTRL_C);
		expect(h.quits).toEqual([]);
		expect(h.notices).toHaveLength(2);
	});

	test("an abort disarms the quit confirmation", () => {
		const h = makeEditor();
		h.editor.handleInput(CTRL_C);
		h.setRunning(true);
		h.editor.handleInput(CTRL_C);
		h.setRunning(false);
		h.editor.handleInput(CTRL_C);
		expect(h.quits).toEqual([]);
	});

	test("discarded paste stays recoverable after another submission clears paste storage", () => {
		const h = makeEditor();
		const paste = Array.from({ length: 20 }, (_, index) => `line ${index}`).join("\n");
		h.editor.handleInput(`\x1b[200~${paste}\x1b[201~`);
		h.editor.handleInput(CTRL_C);
		h.editor.handleInput("another prompt");
		h.editor.handleInput(ENTER);
		h.editor.handleInput(UP);
		h.editor.handleInput(UP);
		h.editor.handleInput(ENTER);
		expect(h.submitted[1]).toBe(paste);
	});
});

describe("Ctrl+D and Ctrl+G", () => {
	test("Ctrl+D quits on an empty draft", () => {
		const h = makeEditor();
		h.editor.handleInput(CTRL_D);
		expect(h.quits).toEqual([0]);
	});

	test("Ctrl+D deletes forward when there is text", () => {
		const h = makeEditor();
		h.editor.handleInput("abc");
		h.editor.moveToLineStart();
		h.editor.handleInput(CTRL_D);
		expect(h.quits).toEqual([]);
		expect(h.editor.getText()).toBe("bc");
	});

	test("Ctrl+G hands off to the external editor", () => {
		const h = makeEditor();
		h.editor.handleInput(CTRL_G);
		expect(h.edits).toBe(1);
	});
});

describe("Esc Esc", () => {
	test("a double press discards the draft, recoverable with up", () => {
		const h = makeEditor();
		h.editor.handleInput("draft text");
		h.editor.handleInput(ESC);
		expect(h.editor.getText()).toBe("draft text");
		h.editor.handleInput(ESC);
		expect(h.editor.getText()).toBe("");
		h.editor.handleInput(UP);
		expect(h.editor.getText()).toBe("draft text");
	});

	test("a slow second press does not discard", () => {
		const h = makeEditor();
		h.editor.handleInput("draft text");
		h.editor.handleInput(ESC);
		h.setNow(1_000_000 + ESC_DISCARD_MS + 1);
		h.editor.handleInput(ESC);
		expect(h.editor.getText()).toBe("draft text");
	});

	test("Escape interrupts without discarding a multiline correction", () => {
		const h = makeEditor();
		h.setRunning(true);
		h.editor.setText("keep this\ncorrection");
		h.editor.handleInput(ESC);
		expect(h.aborts).toBe(1);
		expect(h.editor.getExpandedText()).toBe("keep this\ncorrection");
		expect(h.quits).toEqual([]);
	});
});

describe("history recall", () => {
	test("up walks back through sent prompts and down returns", () => {
		const h = makeEditor();
		for (const text of ["one", "two"]) {
			h.editor.handleInput(text);
			h.editor.handleInput(ENTER);
		}
		h.editor.handleInput(UP);
		expect(h.editor.getText()).toBe("two");
		h.editor.handleInput(UP);
		expect(h.editor.getText()).toBe("one");
		h.editor.handleInput(DOWN);
		expect(h.editor.getText()).toBe("two");
		h.editor.handleInput(DOWN);
		expect(h.editor.getText()).toBe("");
	});

	test("up with a non-empty draft moves the cursor instead of recalling", () => {
		const h = makeEditor();
		h.editor.handleInput("sent");
		h.editor.handleInput(ENTER);
		h.editor.handleInput("in progress");
		h.editor.handleInput(UP);
		expect(h.editor.getText()).toBe("in progress");
	});

	test("recall does nothing with an empty ring", () => {
		const h = makeEditor();
		h.editor.handleInput(UP);
		expect(h.editor.getText()).toBe("");
	});
});

describe("rendering", () => {
	test("no rendered row is wider than the terminal", () => {
		const h = makeEditor();
		h.editor.handleInput("a prompt long enough that it has to wrap at narrow widths, 日本語 too");
		for (const width of [40, 60, 80, 120]) {
			for (const line of h.editor.render(width)) {
				expect(Bun.stringWidth(line)).toBeLessThanOrEqual(width);
			}
		}
	});
});

describe("the TSP composer", () => {
	const PNG = Buffer.from(
		"89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da63f8ffff3f0005fe02fea7d6a4530000000049454e44ae426082",
		"hex",
	);
	const context: DescribeContext = {
		cols: 100,
		reduceMotion: false,
		dark: true,
		supports: () => true,
		feature: () => false,
	};
	const status: StatusBarData = {
		sessionKey: "main",
		model: "anthropic:claude-sonnet-4",
		contextTokens: 50_000,
		contextWindow: 200_000,
		contextSource: "context",
		sessionCount: 1,
		busy: false,
		unread: 0,
		approvals: 0,
		connection: "online",
		mode: "queue",
		queued: 0,
	};

	function find(root: NativeNode, role: string): NativeNode | undefined {
		if (root.p?.role === role) return root;
		for (const child of root.c ?? []) {
			if (!("k" in child)) continue;
			const found = find(child, role);
			if (found) return found;
		}
		return undefined;
	}

	function composer() {
		const log: string[] = [];
		const state: { -readonly [K in keyof ComposerNativeState]: ComposerNativeState[K] } = {
			running: false,
		};
		const drafts = new ComposerDrafts();
		const editor = new CustomEditor({
			theme: getEditorTheme(),
			onSubmit: (text) => void log.push(`submit:${text}`),
			onAbort: () => state.running && log.push("abort") > 0,
			composerState: () => state,
			onSelectModel: () => log.push("model"),
			onSelectThinking: () => log.push("thinking"),
			composer: { drafts, sessionKey: () => "main", submit: () => "accepted" },
		});
		editor.composerFacts = new StatusBar({
			data: () => ({ ...status, busy: state.running }),
			onNativeAction: (action) => log.push(`status:${action}`),
		});
		const click = (act: string) =>
			editor.handleNativeEvent({ type: "action", key: "", act, mods: [] });
		return { editor, state, drafts, log, click };
	}

	test("describes omp's composer and keeps its identity while unchanged", () => {
		const { editor } = composer();
		const root = editor.describe(context);
		expect(root.p).toMatchObject({ role: "omp.editor" });
		expect(root.p?.tone).toBeUndefined();
		for (const role of [
			"omp.composer.context",
			"omp.composer.chips",
			"omp.composer.line",
			"omp.composer.bar",
			"omp.composer.model",
			"omp.composer.effort",
			"omp.composer.extras",
			"omp.composer.send",
		]) {
			expect(find(root, role)).toBeDefined();
		}
		expect(find(root, "omp.composer.line")?.c?.[0]).toMatchObject({ k: "editor", key: "input" });
		expect(find(root, "omp.composer.stop")).toBeUndefined();
		expect(editor.describe(context)).toBe(root);
	});

	test("a live run turns the composer pending with Stop, and the title becomes the placeholder", () => {
		const { editor, state } = composer();
		state.running = true;
		state.title = "Fix the build";
		const root = editor.describe(context);
		expect(root.p?.tone).toBe("pending");
		expect(find(root, "omp.composer.send")).toBeUndefined();
		expect(find(root, "omp.composer.stop")).toBeDefined();
		expect(find(root, "omp.composer.line")?.c?.[0]).toMatchObject({
			p: { placeholder: [{ t: "\u201cFix the build\u201d", s: "em" }] },
		});
	});

	test("clicks take the same paths as their keys", () => {
		const { editor, state, log, click } = composer();
		click("status.model");
		click("thinking.select");
		click("interrupt");
		state.running = true;
		click("interrupt");
		click("status.mode");
		editor.setText("hello");
		click("submit");
		expect(log).toEqual(["model", "thinking", "abort", "status:mode", "submit:hello"]);
	});

	test("attachments become removable chips", () => {
		const { editor, drafts, click } = composer();
		drafts.add("main", [imageFromBytes(PNG, "shot.png")]);
		const chips = find(editor.describe(context), "omp.composer.chips");
		expect(chips?.p?.hidden).toBe(false);
		const remove = find(chips!, "omp.composer.chipRemove");
		click(String(remove?.p?.actions?.click));
		expect(drafts.items("main")).toHaveLength(0);
	});
});
