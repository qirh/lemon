import { TranscriptContainer as RowTranscript } from "@oh-my-pi/pi-tui/chrome/transcript-container";

/**
 * Lemon's transcript uses pi-tui's ordered semantic retirement ledger. The
 * frame provider, not the root Container renderer, owns history transactions.
 * Keep a reset generation so a pending offer cannot survive session replacement.
 */
export class TranscriptContainer extends RowTranscript {
	#generation = 0;
	#rendered: readonly string[] = [];

	get generation(): number {
		return this.#generation;
	}

	override clear(): void {
		super.clear();
		this.#generation++;
		this.#rendered = [];
	}

	/** Full semantic render for exports/tests; terminal frames use renderViewport. */
	override render(width: number): readonly string[] {
		const rows = super.render(Math.max(1, width));
		if (
			rows.length !== this.#rendered.length ||
			rows.some((row, index) => row !== this.#rendered[index])
		) {
			this.#rendered = rows;
		}
		return this.#rendered;
	}
}
