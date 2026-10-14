/**
 * Native (Tern Surface Protocol) chrome shared by transcript blocks. Roles are
 * the shared Tern vocabulary omp's own components emit; rows never use these.
 */

import { hasTranscriptActions } from "@oh-my-pi/pi-tui/chat/transcript-actions";
import { card, kbd, node, span, text } from "@oh-my-pi/pi-tui/native/describe";
import type { NativeChild, NativeNode } from "@oh-my-pi/pi-tui/native/node";

/** One control in an error frame's action row; the click comes back as `act`. */
export interface ErrorFrameAction {
	readonly act: string;
	readonly label: string;
	readonly title: string;
	/** Key id of the keyboard path the control mirrors, drawn as a keycap. */
	readonly keys?: string;
}

/**
 * omp's error frame (`omp.error`): a head, the message once
 * (`omp.error.message`), then its actions (`omp.error.actions`) when the host
 * handles transcript actions.
 */
export function describeErrorFrame(
	head: string,
	message: string,
	actions: readonly ErrorFrameAction[],
): NativeNode {
	const children: NativeChild[] = [
		node("row", { gap: "sm" }, [text([span(head, "error strong")])], "head"),
		text([span(message, "mono")], { wrap: "word", role: "omp.error.message", key: "message" }),
	];
	if (actions.length > 0 && hasTranscriptActions()) {
		children.push(
			node(
				"row",
				{ gap: "sm", role: "omp.error.actions" },
				actions.map(({ act, label, title, keys }) =>
					node(
						"row",
						{ gap: "xs", role: "omp.error.action", actions: { click: act }, title },
						keys ? [text(label), kbd(keys)] : [text(label)],
						act,
					),
				),
				"actions",
			),
		);
	}
	return card({ role: "omp.error", tone: "error" }, children);
}
