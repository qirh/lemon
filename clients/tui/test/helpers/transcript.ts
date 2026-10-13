import type { Component } from "@oh-my-pi/pi-tui/tui";
import type { TranscriptContainer } from "../../src/ui/components/transcript-container.ts";

/** Lifecycle assertions do not offer/acknowledge the renderer's history batches. */
export function unfinalizedBlocks(transcript: TranscriptContainer): readonly Component[] {
	return transcript.children.filter(
		(child) =>
			(
				child as Component & { isTranscriptBlockFinalized?(): boolean }
			).isTranscriptBlockFinalized?.() === false,
	);
}
