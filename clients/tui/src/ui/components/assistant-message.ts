/**
 * A streaming assistant reply.
 *
 * Stable Markdown source boundaries, rather than physical row offsets, identify
 * the streamed head eligible for history. Each publication must remain a byte
 * prefix at every width; pi-tui retires only publications above the live tail.
 */

import {
	isRowPrefix,
	type TranscriptStableRow,
	trimBlankEdges,
} from "@oh-my-pi/pi-tui/chrome/transcript-container";
import { Markdown } from "@oh-my-pi/pi-tui/components/markdown";
import { Text } from "@oh-my-pi/pi-tui/components/text";
import { col } from "@oh-my-pi/pi-tui/native/describe";
import type { NativeNode } from "@oh-my-pi/pi-tui/native/node";
import { Container } from "@oh-my-pi/pi-tui/tui";
import { TranscriptMarks, type TranscriptPhase } from "../../terminal/marks.ts";
import { getTheme } from "../theme/theme.ts";
import { getMarkdownTheme } from "../theme/tui-adapters.ts";
import { WidthClamp } from "./width-safe.ts";

/** Appended to the visible text when the user aborted a run mid-stream. */
export const INTERRUPTED_SUFFIX = "*[interrupted]*";

export interface AssistantFinalizeOptions {
	/** False renders the error line and marks the block failed. */
	ok?: boolean;
	/** Keeps the partial text and appends {@link INTERRUPTED_SUFFIX}. */
	interrupted?: boolean;
	/** Shown under the body when the run failed. */
	error?: string;
}

export class AssistantMessageComponent extends Container {
	readonly #markdown: Markdown;
	/** Holds the post-run error line, if any. Empty renders zero rows. */
	readonly #footer = new Container();
	readonly #clamp = new WidthClamp();
	readonly #marks = new TranscriptMarks();
	#phase: TranscriptPhase = "running";
	#native: NativeNode | undefined;
	#nativeVersion = -1;

	#text = "";
	#finalized = false;
	#transient = true;
	#version = 0;
	readonly transcriptBlockMode = "appendOnly";
	readonly #prefixMarkdown: Markdown;
	readonly #prefixClamp = new WidthClamp();
	readonly #prefixMarks = new TranscriptMarks();
	#stableText = "";
	#stableEnds: number[] = [];
	#stableRows: TranscriptStableRow[] = [];
	#stableRender: { width: number; count: number; rows: readonly string[] } | undefined;

	constructor(text = "") {
		super();
		const theme = getTheme();
		this.#markdown = new Markdown(text, 1, 0, getMarkdownTheme(), {
			color: (value) => theme.fg("assistantText", value),
		});
		this.#prefixMarkdown = new Markdown("", 1, 0, getMarkdownTheme(), {
			color: (value) => theme.fg("assistantText", value),
		});
		// Streaming renders bypass the markdown module LRU and expose a frozen
		// prefix; the finalize render flips this off so the final bytes are the
		// cached, fully highlighted ones.
		this.#markdown.transientRenderCache = true;
		this.#text = text;
		this.addChild(this.#markdown);
		this.addChild(this.#footer);
	}

	get text(): string {
		return this.#text;
	}

	/**
	 * Replace the visible text. `transient` marks an in-flight streaming
	 * snapshot (the default while unfinalized); the finalize path is the only
	 * non-transient render.
	 */
	updateContent(fullText: string, options: { transient?: boolean } = {}): void {
		const transient = options.transient ?? !this.#finalized;
		this.#version++;
		this.#text = fullText;
		if (this.#transient !== transient) {
			this.#transient = transient;
			this.#markdown.transientRenderCache = transient;
		}
		this.#markdown.setText(fullText);
	}

	/**
	 * Seal the block: no further streaming, rows become commit-eligible as a
	 * whole. Keeps whatever text was revealed — an interrupted run's partial
	 * answer is history too, just marked as such.
	 */
	finalize(options: AssistantFinalizeOptions = {}): void {
		const theme = getTheme();
		// The marker is markdown source, not pre-styled text: the Markdown child
		// renders the emphasis itself, the same way it does for the reply body.
		const body = options.interrupted
			? `${this.#text}${this.#text.length === 0 || this.#text.endsWith("\n") ? "" : "\n\n"}${INTERRUPTED_SUFFIX}`
			: this.#text;
		this.updateContent(body, { transient: false });
		this.#finalized = true;
		this.#phase = options.ok === false || options.interrupted ? "error" : "success";
		this.#footer.clear();
		if (options.ok === false && options.error) {
			this.#footer.addChild(new Text(theme.fg("error", `Error: ${options.error}`), 1, 0));
			this.#version++;
		}
	}

	override describe(): NativeNode {
		if (this.#nativeVersion !== this.#version || !this.#native) {
			// These semantic roles are Tern's chat/transcript contract, shared
			// by Carly's wait/transcript API and native reply navigation.
			this.#native = col(this.children, { role: "omp.assistant" });
			this.#nativeVersion = this.#version;
		}
		return this.#native;
	}

	override render(width: number): readonly string[] {
		// Markdown keeps its horizontal padding at any width, so very narrow
		// renders would otherwise emit rows wider than requested.
		const rows = this.#marks.apply(this.#clamp.apply(super.render(width), width), this.#phase);
		if (!this.#finalized && this.#transient) {
			const text = this.#markdown.getLastRenderStableText();
			if (text.length > this.#stableText.length && text.startsWith(this.#stableText)) {
				const previous = this.renderTranscriptStableRows(this.#stableEnds.length, width);
				this.#prefixMarkdown.setText(text);
				const prefix = trimBlankEdges(
					this.#prefixMarks.apply(
						this.#prefixClamp.apply(this.#prefixMarkdown.render(width), width),
						"running",
					),
				);
				// Keep the final row mutable: finalization can attach OSC 133 D.
				if (
					prefix.length > previous.length &&
					prefix.length < trimBlankEdges(rows).length &&
					isRowPrefix(previous, prefix) &&
					isRowPrefix(prefix, trimBlankEdges(rows))
				) {
					this.#stableText = text;
					this.#stableEnds.push(text.length);
					this.#stableRows.push({ key: `text:${text.length}` });
					this.#stableRender = { width, count: this.#stableEnds.length, rows: prefix };
				}
			}
		}
		return rows;
	}

	override invalidate(): void {
		this.#clamp.reset();
		this.#prefixClamp.reset();
		this.#prefixMarkdown.invalidate();
		this.#stableRender = undefined;
		super.invalidate();
	}

	// -- FinalizableBlock ----------------------------------------------------

	isTranscriptBlockFinalized(): boolean {
		return this.#finalized;
	}

	getTranscriptBlockVersion(): number {
		return this.#version;
	}

	getTranscriptStableRows(): readonly TranscriptStableRow[] {
		return this.#stableRows;
	}

	renderTranscriptStableRows(count: number, width: number): readonly string[] {
		const end = this.#stableEnds[Math.min(Math.trunc(count), this.#stableEnds.length) - 1];
		if (end === undefined) return [];
		if (this.#stableRender?.width === width && this.#stableRender.count === count) {
			return this.#stableRender.rows;
		}
		this.#prefixMarkdown.setText(this.#stableText.slice(0, end));
		const rows = trimBlankEdges(
			this.#prefixMarks.apply(
				this.#prefixClamp.apply(this.#prefixMarkdown.render(width), width),
				"running",
			),
		);
		this.#stableRender = { width, count, rows };
		return rows;
	}

	resetTranscriptStableRows(): void {
		this.#stableText = "";
		this.#stableEnds = [];
		this.#stableRows = [];
		this.#stableRender = undefined;
	}
}
