import { detectTerminalCapabilities } from "./capabilities.ts";

export type TranscriptPhase = "prompt" | "running" | "success" | "error";

/** Marks travel with transcript rows, never with the editor's current cursor. */
export class TranscriptMarks {
	readonly #enabled: boolean;
	#source: readonly string[] | undefined;
	#phase: TranscriptPhase | undefined;
	#lines: readonly string[] = [];

	constructor(enabled = detectTerminalCapabilities().enabled) {
		this.#enabled = enabled;
	}

	apply(lines: readonly string[], phase: TranscriptPhase): readonly string[] {
		if (!this.#enabled) return lines;
		if (lines.length === 0 && (phase === "prompt" || phase === "running")) return lines;
		if (lines === this.#source && phase === this.#phase) return this.#lines;
		const marked = lines.length > 0 ? lines.slice() : [""];
		marked[0] = `\x1b]133;${phase === "prompt" ? "A" : "C"}\x07${marked[0]}`;
		const last = marked.length - 1;
		if (phase === "prompt") marked[last] += "\x1b]133;B\x07";
		else if (phase !== "running") marked[last] += `\x1b]133;D;${phase === "error" ? 1 : 0}\x07`;
		this.#source = lines;
		this.#phase = phase;
		this.#lines = marked;
		return marked;
	}
}
