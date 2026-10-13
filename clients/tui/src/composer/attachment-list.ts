import { truncateToWidth } from "@oh-my-pi/pi-tui/utils";
import type { PendingImage } from "./images.ts";

/** Stable rows; filenames cannot inject terminal controls or extra screen lines. */
export class AttachmentList {
	#images: readonly PendingImage[] | undefined;
	#busy = false;
	#width = -1;
	#rows: readonly string[] = [];

	render(images: readonly PendingImage[], busy: boolean, width: number): readonly string[] {
		if (this.#images === images && this.#busy === busy && this.#width === width) return this.#rows;
		this.#images = images;
		this.#busy = busy;
		this.#width = width;
		if (width < 1 || (images.length === 0 && !busy)) {
			this.#rows = [];
			return this.#rows;
		}
		const rows = images.map((image, index) => {
			// biome-ignore lint/suspicious/noControlCharactersInRegex: Filenames must not inject terminal controls.
			const name = image.name.replace(/[\x00-\x1f\x7f-\x9f]/g, " ");
			const size = Math.max(1, Math.ceil(image.byteLength / 1024));
			return truncateToWidth(
				`[${index + 1}] ${name} · ${image.content.mime_type} · ${size} KiB`,
				width,
				"",
			);
		});
		rows.push(
			truncateToWidth(
				busy
					? "Attaching/sending images…"
					: "ctrl+shift+backspace removes last image · ctrl+v pastes",
				width,
				"",
			),
		);
		this.#rows = rows;
		return this.#rows;
	}
}
