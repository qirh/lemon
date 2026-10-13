import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CombinedAutocompleteProvider } from "@oh-my-pi/pi-tui/autocomplete";
import { AttachmentList } from "../src/composer/attachment-list.ts";
import { ComposerDrafts } from "../src/composer/drafts.ts";
import { imageFromBytes, MAX_IMAGE_BYTES, readImageFile } from "../src/composer/images.ts";
import { ComposerMedia } from "../src/composer/media.ts";
import { fileMention, parsePastedPaths, resolvePastedPath } from "../src/composer/paths.ts";

const PNG = Buffer.from(
	"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a9sAAAAASUVORK5CYII=",
	"base64",
);
let directory = "";

beforeEach(async () => {
	directory = await mkdtemp(join(tmpdir(), "lemon-composer-"));
});
afterEach(async () => {
	await rm(directory, { recursive: true, force: true });
});

describe("bounded real image payloads", () => {
	test("a file becomes canonical base64 image bytes, never a path payload", async () => {
		const path = join(directory, "screen shot.png");
		await writeFile(path, PNG);
		const image = await readImageFile(path);
		expect(image.content).toEqual({
			type: "image",
			mime_type: "image/png",
			data: PNG.toString("base64"),
		});
		expect(image.byteLength).toBe(PNG.length);
		expect(image.name).toBe("screen shot.png");
		expect(Buffer.from(image.content.data, "base64")).toEqual(PNG);
	});

	test("file extension alone cannot pretend to be an image", async () => {
		const path = join(directory, "pretend.png");
		await writeFile(path, "this is a path, not an image");
		await expect(readImageFile(path)).rejects.toThrow("image bytes");
		expect(() => imageFromBytes(PNG, "wrong.jpg", "image/jpeg")).toThrow("image bytes");
	});

	test("empty, oversized, remaining-budget, and directory reads are refused", async () => {
		await writeFile(join(directory, "empty.png"), "");
		await writeFile(join(directory, "large.png"), Buffer.alloc(MAX_IMAGE_BYTES + 1));
		await writeFile(join(directory, "small.png"), PNG);
		await expect(readImageFile(join(directory, "empty.png"))).rejects.toThrow();
		await expect(readImageFile(join(directory, "large.png"))).rejects.toThrow();
		await expect(readImageFile(join(directory, "small.png"), PNG.length - 1)).rejects.toThrow();
		await expect(readImageFile(directory)).rejects.toThrow("regular files");
	});
});

describe("pasted paths and explicit file references", () => {
	test("quotes, shell escapes, file URLs, and raw Finder spaces preserve actual names", () => {
		expect(parsePastedPaths(`'/tmp/my screenshot.png' "/tmp/other photo.jpg"`)).toEqual([
			"/tmp/my screenshot.png",
			"/tmp/other photo.jpg",
		]);
		expect(parsePastedPaths("/tmp/my\\ screenshot.png")).toEqual(["/tmp/my screenshot.png"]);
		expect(parsePastedPaths("/tmp/my screenshot.png")).toEqual(["/tmp/my screenshot.png"]);
		expect(parsePastedPaths("file:///tmp/screen%20shot.png")).toEqual(["/tmp/screen shot.png"]);
		expect(parsePastedPaths(`"docs/my notes.md"`)).toEqual(["docs/my notes.md"]);
		expect(parsePastedPaths("'/tmp/it'\\''s.png'")).toEqual(["/tmp/it's.png"]);
		expect(parsePastedPaths("/tmp/one.png\n/tmp/two.webp")).toEqual([
			"/tmp/one.png",
			"/tmp/two.webp",
		]);
	});

	test("ordinary prose, remote URLs, malformed quotes, and terminal controls stay text", () => {
		for (const text of [
			"ordinary pasted words",
			"https://example.com/a.png",
			"file://remote/a.png",
			"'/tmp/a.png",
			"/tmp/a\x1b[31m.png",
		]) {
			expect(parsePastedPaths(text)).toBeUndefined();
		}
		expect(fileMention("docs/my notes.md")).toBe('@"docs/my notes.md"');
		expect(resolvePastedPath("./a.png", directory)).toBe(join(directory, "a.png"));
	});

	test("pi autocomplete completes quoted @ paths without opening their content", async () => {
		await mkdir(join(directory, "docs"));
		await writeFile(join(directory, "docs", "my notes.md"), "not silently ingested");
		const provider = new CombinedAutocompleteProvider([], directory);
		const text = 'Review @"docs/my';
		const suggestions = await provider.getSuggestions([text], 0, text.length);
		const item = suggestions?.items.find((candidate) => candidate.value.includes("my notes.md"));
		expect(item).toBeDefined();
		const result = provider.applyCompletion([text], 0, text.length, item!, suggestions!.prefix);
		expect(result.lines[0]).toBe('Review @"docs/my notes.md" ');
		expect(result.lines[0]).not.toContain("not silently ingested");
	});
});

describe("session draft ownership", () => {
	test("reject/offline leave identity intact; queue acceptance transfers only snapshot IDs", () => {
		const drafts = new ComposerDrafts();
		const first = imageFromBytes(PNG, "first.png");
		const later = imageFromBytes(PNG, "later.png");
		drafts.add("a", [first]);
		const submission = drafts.prepare("a", "")!;
		expect(submission.text).toBe("");
		expect(submission.images).toEqual([first.content]);
		drafts.complete(submission, "rejected");
		expect(drafts.items("a")).toEqual([first]);
		drafts.add("a", [later]);
		drafts.add("b", [imageFromBytes(PNG, "other.png")]);
		drafts.complete(submission, "queued");
		expect(drafts.items("a")).toEqual([later]);
		expect(drafts.items("b")).toHaveLength(1);
		// Editing the queue restores exactly the same payload/id, not a reread path.
		drafts.add("a", submission.attachments);
		expect(drafts.items("a")).toEqual([later, first]);
		drafts.remove("a", first.id);
		expect(drafts.items("a")).toEqual([later]);
	});

	test("blank input is invalid without images; count and aggregate limits are atomic", () => {
		const drafts = new ComposerDrafts();
		expect(drafts.prepare("a", " \n")).toBeUndefined();
		const images = Array.from({ length: 6 }, (_, index) => imageFromBytes(PNG, `${index}.png`));
		drafts.add("a", images.slice(0, 5));
		expect(() => drafts.add("a", images.slice(5))).toThrow("5 images");
		expect(drafts.items("a")).toHaveLength(5);
		const bytes = Buffer.alloc(MAX_IMAGE_BYTES);
		PNG.copy(bytes);
		drafts.add("b", [imageFromBytes(bytes, "full.png")]);
		expect(() => drafts.add("b", [images[0]!])).toThrow("10 MiB");
		expect(drafts.items("b")).toHaveLength(1);
	});

	test("verified session deletion clears only that session's attachments", () => {
		const drafts = new ComposerDrafts();
		drafts.add("a", [imageFromBytes(PNG, "a.png")]);
		const retained = imageFromBytes(PNG, "b.png");
		drafts.add("b", [retained]);
		drafts.clear("a");
		expect(drafts.items("a")).toEqual([]);
		expect(drafts.items("b")).toEqual([retained]);
	});

	test("a rejected multi-file paste attaches none, and file mentions never read text files", async () => {
		const drafts = new ComposerDrafts();
		const inserted: string[] = [];
		const notices: string[] = [];
		await writeFile(join(directory, "good.png"), PNG);
		await writeFile(join(directory, "bad.png"), "bad");
		const media = new ComposerMedia({
			drafts,
			cwd: () => directory,
			changed: () => {},
			insertText: (_key, text) => inserted.push(text),
			notice: (text) => notices.push(text),
		});
		expect(await media.pastePaths("a", ["./good.png", "./bad.png"])).toBe(false);
		expect(drafts.items("a")).toHaveLength(0);
		expect(notices).toHaveLength(1);
		expect(await media.pastePaths("a", ["./good.png", "./nonexistent.md", "./directory/"])).toBe(
			true,
		);
		expect(drafts.items("a")).toHaveLength(1);
		expect(inserted).toEqual(["@./nonexistent.md @./directory/ "]);
	});
});

test("attachment rows are stable, width bounded, and strip filename control bytes", () => {
	const list = new AttachmentList();
	const images = [imageFromBytes(PNG, "name\x1b\x07\n画像.png")];
	for (const width of [0, 1, 4, 20, 80]) {
		const rows = list.render(images, false, width);
		expect(list.render(images, false, width)).toBe(rows);
		for (const row of rows) {
			expect(Bun.stringWidth(row)).toBeLessThanOrEqual(width);
			// biome-ignore lint/suspicious/noControlCharactersInRegex: Verify terminal control bytes are removed.
			expect(row).not.toMatch(/[\x1b\x07\n]/);
		}
	}
});
