/**
 * The prompt editor.
 *
 * Everything pi-tui's {@link Editor} already does well (wrapping, undo, paste
 * markers, autocomplete popups, IME) is inherited untouched. What this subclass
 * adds is the key policy the client needs *before* the base editor sees a
 * keystroke:
 *
 *   Ctrl+C   a non-empty draft is cleared; an empty one aborts the live run;
 *            with nothing running, twice in a row quits.
 *   Ctrl+D   quits on an empty draft, deletes forward otherwise.
 *   Ctrl+G   hands the draft to $EDITOR.
 *   Esc      aborts the live run without discarding the draft; while idle,
 *            Esc Esc discards the draft (recoverable with ↑).
 *   ↑ / ↓    recall sent prompts while the draft is empty.
 *   Alt+↵    cycle the submission mode for the next submission only.
 *
 * Submission funnels through one callback, {@link CustomEditorOptions.onSubmit}.
 * That single seam is where the shell layers queue / steer / redirect / interrupt; nothing
 * else in the client sends a prompt.
 */

import { CombinedAutocompleteProvider } from "@oh-my-pi/pi-tui/autocomplete";
import { BracketedPasteHandler } from "@oh-my-pi/pi-tui/bracketed-paste";
import {
	Editor,
	type EditorTheme,
	type NativeEditorLayout,
} from "@oh-my-pi/pi-tui/components/editor";
import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import { text as nativeText } from "@oh-my-pi/pi-tui/native/describe";
import type { DescribeContext, NativeNode, NativeUiEvent } from "@oh-my-pi/pi-tui/native/node";
import { styledSpans } from "@oh-my-pi/pi-tui/native/spans";
import { AttachmentList } from "../../composer/attachment-list.ts";
import type {
	ComposerDrafts,
	ComposerSubmission,
	SubmissionDisposition,
} from "../../composer/drafts.ts";
import type { PendingImage } from "../../composer/images.ts";
import { type ComposerIO, ComposerMedia } from "../../composer/media.ts";
import { IMAGE_PATH, parsePastedPaths } from "../../composer/paths.ts";
import type { NoticeLevel } from "../../store/transcript-model.ts";

/** Window in which a second Ctrl+C quits. */
export const EXIT_CONFIRM_MS = 2000;
/** Window in which a second Esc discards the draft. */
export const ESC_DISCARD_MS = 800;
/** How many sent prompts ↑ can walk back through. */
export const HISTORY_LIMIT = 100;

export interface ComposerEditorOptions {
	drafts: ComposerDrafts;
	sessionKey: () => string;
	cwd?: () => string;
	/** Return queued only after the actual payload has an owning queue item. */
	submit: (
		submission: ComposerSubmission,
	) => SubmissionDisposition | Promise<SubmissionDisposition>;
	io?: ComposerIO;
}

export interface CustomEditorOptions {
	theme: EditorTheme;
	/** The one submission seam. Slash/shell handling happens downstream of it. */
	onSubmit: (text: string) => void | Promise<void>;
	/** Native automation cannot submit until the connection and modal state allow it. */
	canSubmit?: () => boolean;
	/** Abort the run in flight. Return true when there was one. */
	onAbort?: () => boolean;
	onQuit?: (code: number) => void;
	/** Ctrl+G / `/editor`. */
	onExternalEdit?: () => void | Promise<void>;
	/**
	 * Alt+Enter: cycle the submission mode for *this* submission only. The base
	 * editor reserves Alt+Enter for exactly this kind of host hook (it inserts a
	 * newline only when none is installed), and Shift+Enter is already the
	 * newline key, so this is the one free chord next to the submit key.
	 */
	onCycleMode?: () => void;
	notice?: (text: string, level?: NoticeLevel) => void;
	/** Called after a key changed something the host may want repainted. */
	requestRender?: () => void;
	/** Clock seam for the double-press windows. */
	now?: () => number;
	/** Opt in only when the host can route real image payloads. */
	composer?: ComposerEditorOptions;
}

export class CustomEditor extends Editor {
	readonly #options: CustomEditorOptions;
	readonly #now: () => number;

	/** Sent prompts, oldest first. */
	readonly #history: string[] = [];
	/** Position while walking history; undefined when not recalling. */
	#historyIndex: number | undefined;
	/** The draft that was on screen when recall started. */
	#stashed = "";
	#exitArmedAt = 0;
	#escapeAt = 0;
	#nativeSubmitting = false;
	readonly #pasteHandler = new BracketedPasteHandler();
	readonly #attachmentList = new AttachmentList();
	readonly #media: ComposerMedia | undefined;
	readonly #submittingSessions = new Set<string>();
	#renderSource: readonly string[] | undefined;
	#renderAttachments: readonly string[] | undefined;
	#renderRows: readonly string[] = [];
	#nativeAttachmentRows: readonly string[] | undefined;
	#nativeAttachmentNodes: readonly NativeNode[] = [];

	constructor(options: CustomEditorOptions) {
		super(options.theme);
		this.#options = options;
		this.#now = options.now ?? Date.now;
		// Base Editor exposes submission as a property; ours is the only writer.
		this.onSubmit = (text: string) => this.#submit(text);
		if (options.onCycleMode) {
			// Installing the hook is what stops Alt+Enter inserting a newline.
			this.onAltEnter = () => options.onCycleMode?.();
		}
		if (options.composer) {
			this.#media = new ComposerMedia({
				drafts: options.composer.drafts,
				cwd: options.composer.cwd ?? process.cwd,
				io: options.composer.io,
				insertText: (sessionKey, text) => {
					if (options.composer?.sessionKey() !== sessionKey) {
						options.notice?.(
							"Clipboard text belongs to another session; paste it there again.",
							"warning",
						);
						return;
					}
					const cursor = this.getCursor();
					const before = this.getLines()[cursor.line]?.slice(0, cursor.col) ?? "";
					super.pasteText(before && !/\s$/.test(before) ? ` ${text}` : text);
				},
				notice: (message) => options.notice?.(message, "warning"),
				changed: () => options.requestRender?.(),
			});
		}
	}

	/** Sent prompts, oldest first (the ↑ ring). */
	get history(): readonly string[] {
		return this.#history;
	}

	/** Install slash-command and file-path completion. */
	setCommands(
		commands: Array<{ name: string; description?: string; argumentHint?: string }>,
		basePath = process.cwd(),
	): void {
		this.setAutocompleteProvider(
			new CombinedAutocompleteProvider(
				commands.map((command) => ({
					name: command.name,
					description: command.description,
					argumentHint: command.argumentHint,
					allowArgs: true,
				})),
				basePath,
			),
		);
	}

	/** Reset the double-press arms — used after any state-changing event. */
	disarm(): void {
		this.#exitArmedAt = 0;
		this.#escapeAt = 0;
	}

	/** Push a prompt onto the recall ring without sending it. */
	#rememberPrompt(text: string): void {
		const trimmed = text.trim();
		if (trimmed.length === 0) return;
		if (this.#history[this.#history.length - 1] === text) return;
		this.#history.push(text);
		if (this.#history.length > HISTORY_LIMIT) this.#history.shift();
	}

	protected override get nativeSendable(): boolean {
		return (
			!this.disableSubmit &&
			!this.#nativeSubmitting &&
			!this.mediaBusy &&
			this.pendingAttachments.length === 0 &&
			(this.#options.canSubmit?.() ?? true)
		);
	}

	// Tern discovers the delegatable composer by this role, not merely by an
	// editable node: ordinary picker/search fields must never receive prompts.
	override describeLayout = (input: NativeNode, context: DescribeContext): NativeEditorLayout => {
		const rows = this.#attachmentList.render(this.pendingAttachments, this.mediaBusy, context.cols);
		if (rows !== this.#nativeAttachmentRows) {
			this.#nativeAttachmentRows = rows;
			this.#nativeAttachmentNodes = rows.map((row) =>
				nativeText(styledSpans(row), { wrap: "word" }),
			);
		}
		return {
			role: "omp.editor",
			children: [...this.#nativeAttachmentNodes, input],
			caret: "input",
		};
	};

	override handleNativeEvent(event: NativeUiEvent): void {
		if (event.type !== "send") {
			super.handleNativeEvent(event);
			return;
		}
		if (!event.text.trim() || !this.nativeSendable) return;
		// Carly's prompt is atomic: a human's unsent draft belongs in recall,
		// never concatenated with the delegated prompt.
		this.#rememberPrompt(this.getExpandedText());
		this.setText("");
		this.#nativeSubmitting = true;
		this.#options.requestRender?.();
		void this.#submit(event.text)
			.catch((error: unknown) => {
				this.#options.notice?.(`Prompt failed: ${String(error)}`, "error");
			})
			.finally(() => {
				this.#nativeSubmitting = false;
				this.#options.requestRender?.();
			});
	}

	override handleInput(data: string): void {
		if (this.#media) {
			let next = data;
			while (next.length > 0) {
				const paste = this.#pasteHandler.process(next);
				if (!paste.handled) break;
				if (paste.pasteContent !== undefined) void this.pasteContent(paste.pasteContent);
				next = paste.remaining;
			}
			if (!next) return;
			data = next;
			// Non-bracketed terminal drag/drop arrives as one path-sized burst.
			if (data.length > 1) {
				const paths = parsePastedPaths(data);
				if (paths?.some((path) => IMAGE_PATH.test(path))) {
					void this.#media.pastePaths(this.#options.composer!.sessionKey(), paths);
					return;
				}
			}
		}
		if (this.#intercept(data)) {
			this.#options.requestRender?.();
			return;
		}
		// Any other key ends a history walk: the buffer is the user's again.
		if (this.#historyIndex !== undefined && !isHistoryKey(data)) {
			this.#historyIndex = undefined;
		}
		if (!matchesKey(data, "escape")) this.#escapeAt = 0;
		if (!matchesKey(data, "ctrl+c")) this.#exitArmedAt = 0;
		super.handleInput(data);
	}

	get pendingAttachments(): readonly PendingImage[] {
		const composer = this.#options.composer;
		return composer ? composer.drafts.items(composer.sessionKey()) : NO_ATTACHMENTS;
	}

	/** Native send should remain unavailable while upload/submission owns the input. */
	get mediaBusy(): boolean {
		const sessionKey = this.#options.composer?.sessionKey();
		return (
			sessionKey !== undefined &&
			(Boolean(this.#media?.busy(sessionKey)) || this.#submittingSessions.has(sessionKey))
		);
	}

	/** Also serves a host attachment picker; IDs remain stable through session switches. */
	removeAttachment(id: string): void {
		const composer = this.#options.composer;
		if (!composer) return;
		composer.drafts.remove(composer.sessionKey(), id);
		this.#options.requestRender?.();
	}

	async pasteContent(text: string): Promise<boolean> {
		const paths = this.#media ? parsePastedPaths(text) : undefined;
		if (paths) return this.#media!.pastePaths(this.#options.composer!.sessionKey(), paths);
		// Preserve pi's large-paste markers, sanitization, undo, and prompt history.
		super.pasteText(text);
		this.#options.requestRender?.();
		return true;
	}

	override pasteText(text: string): void {
		void this.pasteContent(text);
	}

	override submit(): void {
		if (this.disableSubmit) return;
		if (this.pendingAttachments.length > 0 || this.mediaBusy) void this.submitComposer();
		else super.submit();
	}

	/** Submit this human draft; external native sends must not inherit its images. */
	async submitComposer(): Promise<void> {
		const composer = this.#options.composer;
		if (!composer || this.disableSubmit) return;
		const sessionKey = composer.sessionKey();
		const generation = composer.drafts.generation(sessionKey);
		if (this.#submittingSessions.has(sessionKey)) return;
		this.#submittingSessions.add(sessionKey);
		this.#options.requestRender?.();
		try {
			if (this.#media?.busy(sessionKey) && !(await this.#media.settled(sessionKey))) return;
			if (
				composer.sessionKey() !== sessionKey ||
				composer.drafts.generation(sessionKey) !== generation
			)
				return;
			const original = this.getExpandedText();
			const submission = composer.drafts.prepare(sessionKey, original);
			if (!submission) return;
			if (submission.images.length === 0) {
				// Ctrl+V may finish as ordinary text or file mentions, not an image.
				this.setText("");
				await this.#submitPlain(submission.text);
				return;
			}
			const disposition = await composer.submit(submission);
			composer.drafts.complete(submission, disposition);
			if (disposition === "accepted" || disposition === "queued") {
				this.#rememberPrompt(submission.text);
				this.addToHistory(submission.text);
				if (
					composer.sessionKey() === sessionKey &&
					composer.drafts.generation(sessionKey) === generation &&
					this.getExpandedText() === original
				) {
					this.setText("");
				}
				this.#historyIndex = undefined;
				this.disarm();
			}
		} catch {
			this.#options.notice?.(
				"Image submission was not accepted; the attachment draft is retained.",
				"error",
			);
		} finally {
			this.#submittingSessions.delete(sessionKey);
			this.#options.requestRender?.();
		}
	}

	override render(width: number): readonly string[] {
		const source = super.render(width);
		const attachments = this.#attachmentList.render(this.pendingAttachments, this.mediaBusy, width);
		if (attachments.length === 0) return source;
		if (source !== this.#renderSource || attachments !== this.#renderAttachments) {
			this.#renderSource = source;
			this.#renderAttachments = attachments;
			this.#renderRows = [...source, ...attachments];
		}
		return this.#renderRows;
	}

	/** Returns true when the key was consumed and must not reach the editor. */
	#intercept(data: string): boolean {
		if (this.#media && matchesKey(data, "ctrl+v")) {
			void this.#media.pasteClipboard(this.#options.composer!.sessionKey());
			return true;
		}
		if (this.#media && matchesKey(data, "ctrl+shift+backspace")) {
			const last = this.pendingAttachments.at(-1);
			if (last) this.removeAttachment(last.id);
			return true;
		}
		if (
			(matchesKey(data, "enter") || data === "\n") &&
			!this.isShowingAutocomplete() &&
			(this.pendingAttachments.length > 0 || this.mediaBusy)
		) {
			void this.submitComposer();
			return true;
		}
		if (matchesKey(data, "ctrl+c")) {
			this.#onCtrlC();
			return true;
		}
		if (matchesKey(data, "ctrl+d")) {
			if (this.getText().length > 0) return false;
			if (this.pendingAttachments.length > 0 || this.mediaBusy) {
				this.#options.notice?.("Remove pending images with ctrl+shift+backspace before quitting.");
				return true;
			}
			this.#options.onQuit?.(0);
			return true;
		}
		if (matchesKey(data, "ctrl+g")) {
			void this.#options.onExternalEdit?.();
			return true;
		}
		if (matchesKey(data, "escape")) {
			return this.#onEscape();
		}
		if (matchesKey(data, "up")) {
			return this.#recall(-1);
		}
		if (matchesKey(data, "down")) {
			return this.#recall(1);
		}
		return false;
	}

	#onCtrlC(): void {
		const draft = this.getExpandedText();
		if (draft.length > 0) {
			// Not lost: a cleared draft is still recallable with ↑.
			this.#rememberPrompt(draft);
			this.setText("");
			this.#historyIndex = undefined;
			this.#exitArmedAt = 0;
			return;
		}
		if (this.#options.onAbort?.()) {
			this.#exitArmedAt = 0;
			return;
		}
		if (this.pendingAttachments.length > 0 || this.mediaBusy) {
			this.#options.notice?.(
				"Pending images retained; ctrl+shift+backspace removes the last image.",
			);
			return;
		}
		const now = this.#now();
		if (now - this.#exitArmedAt < EXIT_CONFIRM_MS) {
			this.#options.onQuit?.(0);
			return;
		}
		this.#exitArmedAt = now;
		this.#options.notice?.("press Ctrl+C again to quit");
	}

	#onEscape(): boolean {
		// An open autocomplete popup owns Escape.
		if (this.isShowingAutocomplete()) return false;
		// Interrupt is independent of the draft: an in-flight correction is
		// valuable input, not something the user should clear just to stop a run.
		if (this.#options.onAbort?.()) {
			this.disarm();
			return true;
		}
		const now = this.#now();
		if (now - this.#escapeAt < ESC_DISCARD_MS && this.getText().length > 0) {
			this.#rememberPrompt(this.getExpandedText());
			this.setText("");
			this.#historyIndex = undefined;
			this.#escapeAt = 0;
			this.#options.notice?.("draft discarded (↑ to bring it back)");
			return true;
		}
		this.#escapeAt = now;
		return false;
	}

	/** Walk the recall ring. `-1` is older, `+1` newer. */
	#recall(direction: -1 | 1): boolean {
		if (this.#history.length === 0) return false;
		if (this.#historyIndex === undefined) {
			// Only an empty draft opts into recall; otherwise ↑ moves the cursor.
			if (direction !== -1 || this.getText().length > 0) return false;
			this.#stashed = this.getText();
			this.#historyIndex = this.#history.length - 1;
			this.setText(this.#history[this.#historyIndex]);
			return true;
		}
		const next = this.#historyIndex + direction;
		if (next < 0) return true;
		if (next >= this.#history.length) {
			this.#historyIndex = undefined;
			this.setText(this.#stashed);
			return true;
		}
		this.#historyIndex = next;
		this.setText(this.#history[next]);
		return true;
	}

	/**
	 * The base editor has already expanded paste markers, trimmed, and emptied
	 * the buffer by the time this runs — `text` is the real prompt bytes.
	 */
	async #submit(text: string): Promise<void> {
		if (this.pendingAttachments.length > 0 || this.mediaBusy) {
			// Autocomplete/native callers can reach the base submit callback after it clears.
			this.setText(text);
			await this.submitComposer();
			return;
		}
		await this.#submitPlain(text);
	}

	async #submitPlain(text: string): Promise<void> {
		this.#historyIndex = undefined;
		this.disarm();
		if (text.trim().length === 0) return;
		this.#rememberPrompt(text);
		this.addToHistory(text);
		await this.#options.onSubmit(text);
	}
}

function isHistoryKey(data: string): boolean {
	return matchesKey(data, "up") || matchesKey(data, "down");
}

const NO_ATTACHMENTS: readonly PendingImage[] = Object.freeze([]);
