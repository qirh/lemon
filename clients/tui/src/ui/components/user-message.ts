/**
 * The user's own prompt, echoed into the transcript.
 *
 * Finalized from birth: it never mutates, so it omits the FinalizableBlock
 * methods entirely (the container treats a block without them as final) and its
 * rows commit to native scrollback as soon as they scroll off.
 */

import { Markdown } from "@oh-my-pi/pi-tui/components/markdown";
import { card } from "@oh-my-pi/pi-tui/native/describe";
import type { NativeNode } from "@oh-my-pi/pi-tui/native/node";
import { Container } from "@oh-my-pi/pi-tui/tui";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import { TranscriptMarks } from "../../terminal/marks.ts";
import { getTheme } from "../theme/theme.ts";
import { getMarkdownTheme } from "../theme/tui-adapters.ts";
import { WidthClamp } from "./width-safe.ts";

/** Left gutter reserved for the prompt marker. */
const GUTTER = 2;

export class UserMessageComponent extends Container {
	// Memoized marker overlay keyed on the child render's array reference (same
	// reference ⇒ identical rows ⇒ reuse the wrapped copy). Keeps this component
	// reference-stable for the transcript's incremental assembly, and never
	// mutates the Markdown child's own cached array.
	#source: readonly string[] | undefined;
	#lines: readonly string[] | undefined;
	readonly #clamp = new WidthClamp();
	readonly #marks = new TranscriptMarks();
	#native: NativeNode | undefined;

	constructor(text: string) {
		super();
		const theme = getTheme();
		this.addChild(
			new Markdown(text, GUTTER, 0, getMarkdownTheme(), {
				color: (value) => theme.fg("userText", value),
			}),
		);
	}

	override describe(): NativeNode {
		this.#native ??= card({ role: "omp.user", tone: "user" }, this.children);
		return this.#native;
	}

	override render(width: number): readonly string[] {
		// Clamp before the overlay: the marker swaps padding cells in place, so it
		// must sit on rows that already fit the requested width.
		const lines = this.#clamp.apply(super.render(width), width);
		if (lines.length === 0) return lines;
		if (this.#source === lines && this.#lines !== undefined) return this.#lines;
		const theme = getTheme();
		const first = lines[0]!;
		// Markdown emits the horizontal padding as literal leading spaces, so the
		// marker replaces them in place: same visible width, never wider than the
		// requested width.
		const markerWidth = visibleWidth(theme.cursor);
		const wrapped = lines.slice();
		wrapped[0] =
			markerWidth > 0 && markerWidth <= GUTTER && first.startsWith(" ".repeat(GUTTER))
				? theme.fg("userPrefix", theme.cursor) +
					" ".repeat(GUTTER - markerWidth) +
					first.slice(GUTTER)
				: first;
		this.#source = lines;
		this.#lines = this.#marks.apply(wrapped, "prompt");
		return this.#lines;
	}

	override invalidate(): void {
		this.#source = undefined;
		this.#lines = undefined;
		this.#clamp.reset();
		super.invalidate();
	}
}
