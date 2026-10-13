import { type ClipboardContent, readComposerClipboard } from "./clipboard.ts";
import type { ComposerDrafts } from "./drafts.ts";
import { MAX_IMAGE_BYTES, MAX_IMAGES, type PendingImage, readImageFile } from "./images.ts";
import { fileMention, IMAGE_PATH, parsePastedPaths, resolvePastedPath } from "./paths.ts";

export interface ComposerIO {
	readClipboard(): Promise<ClipboardContent | undefined>;
	readImage(path: string, remainingBytes: number): Promise<PendingImage>;
}

export interface ComposerMediaOptions {
	drafts: ComposerDrafts;
	cwd: () => string;
	insertText: (sessionKey: string, text: string) => void;
	notice: (message: string) => void;
	changed: () => void;
	io?: ComposerIO;
}

/** Async reads capture the destination before awaiting; session switches cannot steal media. */
export class ComposerMedia {
	readonly #options: ComposerMediaOptions;
	readonly #io: ComposerIO;
	readonly #pending = new Map<string, Promise<boolean>>();

	constructor(options: ComposerMediaOptions) {
		this.#options = options;
		this.#io = options.io ?? { readClipboard: readComposerClipboard, readImage: readImageFile };
	}

	busy(sessionKey: string): boolean {
		return this.#pending.has(sessionKey);
	}

	async settled(sessionKey: string): Promise<boolean> {
		let ok = true;
		while (this.#pending.has(sessionKey)) {
			if (!(await this.#pending.get(sessionKey))) ok = false;
		}
		return ok;
	}

	pastePaths(sessionKey: string, paths: readonly string[]): Promise<boolean> {
		const cwd = this.#options.cwd();
		const generation = this.#options.drafts.generation(sessionKey);
		return this.#run(sessionKey, () => this.#attachPaths(sessionKey, paths, cwd, generation));
	}

	pasteClipboard(sessionKey: string): Promise<boolean> {
		const cwd = this.#options.cwd();
		const generation = this.#options.drafts.generation(sessionKey);
		return this.#run(sessionKey, async () => {
			if (this.#options.drafts.generation(sessionKey) !== generation) return;
			const clipboard = await this.#io.readClipboard();
			if (this.#options.drafts.generation(sessionKey) !== generation) return;
			if (!clipboard) throw new Error("No image or text is available from the local clipboard.");
			switch (clipboard.kind) {
				case "image":
					this.#options.drafts.add(sessionKey, [clipboard.image]);
					break;
				case "paths":
					await this.#attachPaths(sessionKey, clipboard.paths, cwd, generation);
					break;
				case "text": {
					const paths = parsePastedPaths(clipboard.text);
					if (paths) await this.#attachPaths(sessionKey, paths, cwd, generation);
					else this.#options.insertText(sessionKey, clipboard.text);
					break;
				}
			}
		});
	}

	async #attachPaths(
		sessionKey: string,
		paths: readonly string[],
		cwd: string,
		generation: number,
	): Promise<void> {
		if (this.#options.drafts.generation(sessionKey) !== generation) return;
		const existing = this.#options.drafts.items(sessionKey);
		const imagePaths = paths.filter((path) => IMAGE_PATH.test(path));
		if (existing.length + imagePaths.length > MAX_IMAGES) {
			throw new Error("Attach at most 5 images, totaling at most 10 MiB.");
		}
		if (paths.some((path) => /\.(?:heic|heif|bmp|tiff?|svg|avif)$/i.test(path))) {
			throw new Error("Convert this image to PNG, JPEG, GIF, or WebP before attaching it.");
		}
		let remaining =
			MAX_IMAGE_BYTES - existing.reduce((bytes, image) => bytes + image.byteLength, 0);
		const images: PendingImage[] = [];
		for (const path of imagePaths) {
			const image = await this.#io.readImage(resolvePastedPath(path, cwd), remaining);
			if (this.#options.drafts.generation(sessionKey) !== generation) return;
			remaining -= image.byteLength;
			images.push(image);
		}
		this.#options.drafts.add(sessionKey, images);
		const mentions = paths.filter((path) => !IMAGE_PATH.test(path)).map(fileMention);
		if (mentions.length > 0) this.#options.insertText(sessionKey, `${mentions.join(" ")} `);
	}

	#run(sessionKey: string, operation: () => Promise<void>): Promise<boolean> {
		const previous = this.#pending.get(sessionKey) ?? Promise.resolve(true);
		const pending = previous
			.then(operation)
			.then(
				() => true,
				(error: unknown) => {
					this.#options.notice(
						error instanceof Error ? error.message : "Could not attach the image.",
					);
					return false;
				},
			)
			.finally(() => {
				if (this.#pending.get(sessionKey) === pending) this.#pending.delete(sessionKey);
				this.#options.changed();
			});
		this.#pending.set(sessionKey, pending);
		this.#options.changed();
		return pending;
	}
}
