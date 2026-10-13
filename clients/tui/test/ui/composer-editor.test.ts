import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
	ComposerDrafts,
	type ComposerSubmission,
	type SubmissionDisposition,
} from "../../src/composer/drafts.ts";
import { imageFromBytes, type PendingImage } from "../../src/composer/images.ts";
import type { ComposerIO } from "../../src/composer/media.ts";
import { CustomEditor } from "../../src/ui/components/custom-editor.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { getEditorTheme, invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";

const PNG = Buffer.from(
	"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a9sAAAAASUVORK5CYII=",
	"base64",
);

function deferred<T>() {
	let resolve!: (value: T | PromiseLike<T>) => void;
	const promise = new Promise<T>((done) => {
		resolve = done;
	});
	return { promise, resolve };
}

function makeEditor(
	options: {
		io?: ComposerIO;
		submit?: (
			submission: ComposerSubmission,
		) => SubmissionDisposition | Promise<SubmissionDisposition>;
	} = {},
) {
	const drafts = new ComposerDrafts();
	const submitted: ComposerSubmission[] = [];
	const plain: string[] = [];
	const notices: string[] = [];
	let key = "session-a";
	const editor = new CustomEditor({
		theme: getEditorTheme(),
		onSubmit: (text) => {
			plain.push(text);
		},
		notice: (text) => notices.push(text),
		composer: {
			drafts,
			sessionKey: () => key,
			cwd: () => "/project",
			io: options.io ?? {
				readClipboard: async () => ({
					kind: "image",
					image: imageFromBytes(PNG, "Clipboard image"),
				}),
				readImage: async (path) => imageFromBytes(PNG, path),
			},
			submit: (submission) => {
				submitted.push(submission);
				return options.submit?.(submission) ?? "accepted";
			},
		},
	});
	return {
		editor,
		drafts,
		submitted,
		plain,
		notices,
		switchSession: (next: string) => {
			key = next;
			editor.setText("");
		},
	};
}

beforeEach(() => {
	initTheme({ colorLevel: 3 });
});
afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

describe("composer consumer", () => {
	test("ordinary bracketed paste and history still go through pi editor", () => {
		const h = makeEditor();
		const text = Array.from({ length: 20 }, (_, i) => `line ${i}`).join("\n");
		h.editor.handleInput(`\x1b[200~${text}\x1b[201~`);
		h.editor.handleInput("\x03");
		h.editor.handleInput("hello");
		h.editor.handleInput("\r");
		h.editor.handleInput("\x1b[A");
		h.editor.handleInput("\x1b[A");
		h.editor.handleInput("\r");
		expect(h.plain).toEqual(["hello", text]);
		expect(h.submitted).toEqual([]);
	});

	test("pasting a slash command is still ordinary text", () => {
		const h = makeEditor();
		h.editor.handleInput("\x1b[200~/help\x1b[201~");
		expect(h.editor.getText()).toBe("/help");
		h.editor.handleInput("\r");
		expect(h.plain).toEqual(["/help"]);
	});

	test("clipboard text followed by Enter retains the ordinary slash-command submission seam", async () => {
		const h = makeEditor({
			io: {
				readClipboard: async () => ({ kind: "text", text: "/help" }),
				readImage: async () => imageFromBytes(PNG, "unused.png"),
			},
		});
		h.editor.handleInput("\x16");
		await h.editor.submitComposer();
		expect(h.plain).toEqual(["/help"]);
		expect(h.submitted).toEqual([]);
	});

	test("a pasted image and Enter in one terminal burst do not send before loading", async () => {
		const read = deferred<PendingImage>();
		const dispatched = deferred<ComposerSubmission>();
		const h = makeEditor({
			io: {
				readClipboard: async () => undefined,
				readImage: () => read.promise,
			},
			submit: (submission) => {
				dispatched.resolve(submission);
				return "accepted";
			},
		});
		h.editor.handleInput("\x1b[200~/tmp/image.png\x1b[201~\r");
		expect(h.submitted).toHaveLength(0);
		const image = imageFromBytes(PNG, "image.png");
		read.resolve(image);
		expect((await dispatched.promise).images).toEqual([image.content]);
		expect(h.plain).toEqual([]);
	});

	test("clearing a deleted session invalidates its in-flight attachment read", async () => {
		const read = deferred<PendingImage>();
		const h = makeEditor({
			io: {
				readClipboard: async () => undefined,
				readImage: () => read.promise,
			},
		});
		const pasting = h.editor.pasteContent("/tmp/image.png");
		const sending = h.editor.submitComposer();
		h.drafts.clear("session-a");
		read.resolve(imageFromBytes(PNG, "image.png"));
		await pasting;
		await sending;
		expect(h.drafts.items("session-a")).toEqual([]);
		expect(h.submitted).toEqual([]);
	});

	test("fragmented bracketed drag and immediate Enter await the actual image", async () => {
		const read = deferred<PendingImage>();
		const paths: string[] = [];
		const h = makeEditor({
			io: {
				readClipboard: async () => undefined,
				readImage: async (path) => {
					paths.push(path);
					return read.promise;
				},
			},
		});
		h.editor.handleInput('\x1b[200~"/tmp/my');
		h.editor.handleInput(' screenshot.png"\x1b[201~');
		const sending = h.editor.submitComposer();
		expect(h.submitted).toHaveLength(0);
		expect(h.editor.mediaBusy).toBe(true);
		read.resolve(imageFromBytes(PNG, "my screenshot.png"));
		await sending;
		expect(paths).toEqual(["/tmp/my screenshot.png"]);
		expect(h.submitted).toHaveLength(1);
		expect(h.submitted[0]!.text).toBe("");
		expect(h.submitted[0]!.images).toEqual([
			{ type: "image", mime_type: "image/png", data: PNG.toString("base64") },
		]);
		expect(h.editor.pendingAttachments).toHaveLength(0);
		expect(h.plain).toEqual([]);
	});

	test("Enter sends image-only input through the multimodal callback", async () => {
		const h = makeEditor();
		await h.editor.pasteContent("'/tmp/a.png'");
		h.editor.handleInput("\r");
		await Promise.resolve();
		expect(h.submitted).toHaveLength(1);
		expect(h.submitted[0]!.text).toBe("");
		expect(h.editor.pendingAttachments).toHaveLength(0);
	});

	test("rejected and thrown submissions retain both image identity and text", async () => {
		for (const submit of [
			() => "rejected" as const,
			() => {
				throw new Error("offline");
			},
		]) {
			const h = makeEditor({ submit });
			await h.editor.pasteContent("'/tmp/a.png'");
			const image = h.editor.pendingAttachments[0];
			h.editor.setText("explain this image");
			await h.editor.submitComposer();
			expect(h.editor.getText()).toBe("explain this image");
			expect(h.editor.pendingAttachments[0]).toBe(image);
			expect(h.editor.mediaBusy).toBe(false);
		}
	});

	test("queued disposition removes captured images only after ownership transfer", async () => {
		const receipt = deferred<SubmissionDisposition>();
		const h = makeEditor({ submit: () => receipt.promise });
		await h.editor.pasteContent("'/tmp/first.png'");
		h.editor.setText("look");
		const sending = h.editor.submitComposer();
		expect(h.editor.pendingAttachments).toHaveLength(1);
		expect(h.editor.getText()).toBe("look");
		await h.editor.submitComposer(); // duplicate Enter while awaiting the receipt
		expect(h.submitted).toHaveLength(1);
		await h.editor.pasteContent("'/tmp/next.png'");
		h.editor.setText("next prompt");
		receipt.resolve("queued");
		await sending;
		expect(h.editor.pendingAttachments.map((image) => image.name)).toEqual(["/tmp/next.png"]);
		expect(h.editor.getText()).toBe("next prompt");
		expect(h.submitted[0]!.attachments).toHaveLength(1);
	});

	test("a session switch during clipboard read cannot attach to the new session", async () => {
		const clipboard = deferred<{ kind: "image"; image: PendingImage }>();
		const h = makeEditor({
			io: {
				readClipboard: () => clipboard.promise,
				readImage: async () => imageFromBytes(PNG, "file.png"),
			},
		});
		h.editor.handleInput("\x16"); // Ctrl+V: real clipboard helper in production
		const pending = h.editor.submitComposer();
		h.switchSession("session-b");
		const image = imageFromBytes(PNG, "captured.png");
		clipboard.resolve({ kind: "image", image });
		await pending;
		expect(h.drafts.items("session-a")).toEqual([image]);
		expect(h.drafts.items("session-b")).toEqual([]);
		expect(h.submitted).toHaveLength(0);
		h.switchSession("session-a");
		expect(h.editor.pendingAttachments).toEqual([image]);
	});

	test("acceptance while another session is focused leaves its input and images intact", async () => {
		const receipt = deferred<SubmissionDisposition>();
		const h = makeEditor({ submit: () => receipt.promise });
		await h.editor.pasteContent("'/tmp/a.png'");
		const sending = h.editor.submitComposer();
		h.switchSession("session-b");
		await h.editor.pasteContent("'/tmp/b.png'");
		h.editor.setText("keep me");
		receipt.resolve("accepted");
		await sending;
		expect(h.drafts.items("session-a")).toHaveLength(0);
		expect(h.editor.pendingAttachments).toHaveLength(1);
		expect(h.editor.getText()).toBe("keep me");
	});

	test("pending image rows can be removed without changing prompt text", async () => {
		const h = makeEditor();
		await h.editor.pasteContent("'/tmp/a.png' '/tmp/b.png'");
		h.editor.setText("keep text");
		expect(h.editor.render(80).join("\n")).toContain("ctrl+shift+backspace");
		h.editor.handleInput("\x1b[127;6u"); // Kitty Ctrl+Shift+Backspace
		expect(h.editor.pendingAttachments).toHaveLength(1);
		h.editor.removeAttachment(h.editor.pendingAttachments[0]!.id);
		expect(h.editor.pendingAttachments).toHaveLength(0);
		expect(h.editor.getText()).toBe("keep text");
	});

	test("non-image paths become explicit mentions without file-content ingestion", async () => {
		const reads: string[] = [];
		const h = makeEditor({
			io: {
				readClipboard: async () => undefined,
				readImage: async (path) => {
					reads.push(path);
					return imageFromBytes(PNG, path);
				},
			},
		});
		h.editor.setText("Review");
		await h.editor.pasteContent('"/tmp/source file.ts"');
		expect(h.editor.getExpandedText()).toBe('Review @"/tmp/source file.ts" ');
		expect(reads).toEqual([]);
		expect(h.editor.pendingAttachments).toHaveLength(0);
	});

	test("Shift+Enter stays newline and Ctrl+C does not discard images", async () => {
		const h = makeEditor();
		await h.editor.pasteContent("'/tmp/a.png'");
		h.editor.handleInput("text");
		h.editor.handleInput("\x1b[13;2u");
		expect(h.editor.getText()).toBe("text\n");
		expect(h.submitted).toHaveLength(0);
		h.editor.handleInput("\x03");
		expect(h.editor.getText()).toBe("");
		expect(h.editor.pendingAttachments).toHaveLength(1);
	});
});
