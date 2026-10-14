/**
 * Startup banner: a block-glyph lemon beside the product name and key hints.
 *
 * The mark is plain `█ ▀ ▄` cells painted with a per-cell foreground, so every
 * UTF-8 terminal font draws it. Terminals on the ASCII glyph preset, and frames
 * too narrow for logo plus text, get the single-line banner instead.
 *
 * A TSP terminal gets the shared welcome card instead (`omp.welcome`): the
 * same cells drawn as an SVG image beside the wordmark and version, then the
 * key hints as keycaps. The terminal's own `omp` logo image is omp's mark, not
 * ours.
 */

import { nativeImageNode } from "@oh-my-pi/pi-tui/native/blobs";
import { col, kbd, keyed, node, row, span, text } from "@oh-my-pi/pi-tui/native/describe";
import type { NativeNode } from "@oh-my-pi/pi-tui/native/node";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth } from "@oh-my-pi/pi-tui/utils";
import { getTheme, type Theme } from "../theme/theme.ts";

/** The banner's key hints as keycaps; `/help` is typed, not a key. */
const NATIVE_HINTS: readonly { keys?: string; label: string }[] = [
	{ label: "/help" },
	{ keys: "ctrl+p", label: "commands" },
	{ keys: "ctrl+x", label: "sessions" },
	{ keys: "ctrl+o", label: "model" },
	{ keys: "ctrl+c", label: "abort/quit" },
];

/** Leaf on the first row, a pointed lemon body on the rest. */
const LEMON_LOGO: readonly string[] = [
	"           ▄▄▄█▀▀",
	"    ▄▄▄████████▄▄▄",
	"▄▄██████████████████▄▄",
	"▀▀██████████████████▀▀",
	"    ▀▀▀████████▀▀▀",
];

/** Rows of {@link LEMON_LOGO} painted as leaf rather than fruit. */
const LEAF_ROWS = 1;
const LOGO_WIDTH = Math.max(...LEMON_LOGO.map((row) => row.length));
const GAP = "   ";
/** Below this the hints would truncate to nothing useful beside the logo. */
const MIN_LOGO_LAYOUT_WIDTH = 1 + LOGO_WIDTH + GAP.length + 24;

interface LogoColors {
	/** Fruit gradient, top-left highlight to bottom-right shadow. */
	fruit: readonly string[];
	/** Leaf gradient, stem to tip. */
	leaf: readonly string[];
}

const DARK_COLORS: LogoColors = {
	fruit: ["#fff6b0", "#f7d84a", "#e9a92a"],
	leaf: ["#5fb85a", "#9be27a"],
};

/** Deeper stops: the dark palette's pale highlight vanishes on white. */
const LIGHT_COLORS: LogoColors = {
	fruit: ["#e6c200", "#c99700", "#9a6b00"],
	leaf: ["#1a7f37", "#3f9b3a"],
};

/** Linear interpolation across evenly spaced hex stops, `t` in [0, 1]. */
function mix(stops: readonly string[], t: number): string {
	const segment = Math.min(1, Math.max(0, t)) * (stops.length - 1);
	const index = Math.min(stops.length - 2, Math.floor(segment));
	const f = segment - index;
	const a = Number.parseInt(stops[index]!.slice(1), 16);
	const b = Number.parseInt(stops[index + 1]!.slice(1), 16);
	let hex = "#";
	for (const shift of [16, 8, 0]) {
		const from = (a >> shift) & 0xff;
		const to = (b >> shift) & 0xff;
		hex += Math.round(from + (to - from) * f)
			.toString(16)
			.padStart(2, "0");
	}
	return hex;
}

/** Each painted cell's glyph and colour: a diagonal gradient on the fruit, a horizontal one on the leaf. */
function logoCells(theme: Theme): { x: number; y: number; glyph: string; color: string }[] {
	const colors = theme.appearance === "light" ? LIGHT_COLORS : DARK_COLORS;
	const xSpan = Math.max(1, LOGO_WIDTH - 1);
	const ySpan = Math.max(1, LEMON_LOGO.length - LEAF_ROWS - 1);
	const cells: { x: number; y: number; glyph: string; color: string }[] = [];
	LEMON_LOGO.forEach((row, y) => {
		const leafStart = row.length - row.trimStart().length;
		const leafSpan = Math.max(1, row.length - leafStart - 1);
		for (let x = 0; x < row.length; x++) {
			const glyph = row[x]!;
			if (glyph === " ") continue;
			const color =
				y < LEAF_ROWS
					? mix(colors.leaf, (x - leafStart) / leafSpan)
					: mix(colors.fruit, (x / xSpan + (y - LEAF_ROWS) / ySpan) / 2);
			cells.push({ x, y, glyph, color });
		}
	});
	return cells;
}

/** The logo as ANSI rows for cell terminals. */
function paintLogo(theme: Theme): string[] {
	const rows = LEMON_LOGO.map((row) => [...row]);
	for (const cell of logoCells(theme)) rows[cell.y]![cell.x] = theme.hex(cell.color, cell.glyph);
	return rows.map((row) => row.join(""));
}

/** SVG units per cell; a cell is twice as tall as wide, each half-block one square. */
const SVG_CELL = 8;

/**
 * The same cells as crisp SVG squares for TSP: Tern badges a painted `rows`
 * block as a fallback, and an `ansi` block's line gaps split the half-blocks.
 */
function logoSvg(theme: Theme): string {
	const rects = logoCells(theme).map(({ x, y, glyph, color }) => {
		const top = glyph === "▄" ? 1 : 0;
		const height = glyph === "█" ? 2 : 1;
		// One unit of overlap: scaled abutting squares otherwise show hairline seams.
		return `<rect x="${x * SVG_CELL}" y="${(y * 2 + top) * SVG_CELL}" width="${SVG_CELL + 1}" height="${height * SVG_CELL + 1}" fill="${color}"/>`;
	});
	const w = LOGO_WIDTH * SVG_CELL;
	const h = LEMON_LOGO.length * 2 * SVG_CELL;
	return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}" shape-rendering="crispEdges">${rects.join("")}</svg>`;
}

export class Banner implements Component {
	readonly #version: string;
	#width = -1;
	#rows: readonly string[] | undefined;
	#native: { key: string; node: NativeNode } | undefined;

	constructor(version: string) {
		this.#version = version;
	}

	render(width: number): readonly string[] {
		if (this.#rows !== undefined && this.#width === width) return this.#rows;
		const theme = getTheme();
		const title = `${theme.bold(theme.fg("bannerTitle", "lemon"))} ${theme.fg("bannerSubtitle", `tui ${this.#version}`)}`;
		const hints = ["/help · Ctrl+P commands · Ctrl+X sessions", "Ctrl+O model · Ctrl+C abort/quit"];
		let rows: string[];
		if (theme.getSymbolPreset() === "ascii" || width < MIN_LOGO_LAYOUT_WIDTH) {
			rows = [` ${title}  ${theme.fg("dim", hints.join(" · "))}`];
		} else {
			const side = ["", title, theme.fg("dim", hints[0]!), theme.fg("dim", hints[1]!), ""];
			rows = paintLogo(theme).map((logo, y) => {
				const pad = " ".repeat(LOGO_WIDTH - LEMON_LOGO[y]!.length);
				return side[y] ? ` ${logo}${pad}${GAP}${side[y]}` : ` ${logo}`;
			});
		}
		this.#rows = rows.map((row) => truncateToWidth(row, Math.max(0, width), ""));
		this.#width = width;
		return this.#rows;
	}

	/**
	 * The welcome card: lockup (painted lemon, wordmark, version) and the key
	 * hints. Rebuilt only when the logo's palette or glyph preset changes.
	 */
	describe(): NativeNode {
		const theme = getTheme();
		const ascii = theme.getSymbolPreset() === "ascii";
		const key = `${theme.appearance}\0${ascii}`;
		if (this.#native?.key === key) return this.#native.node;
		const mark = keyed(
			col(
				[
					keyed(
						text([span("lemon", "strong")], { wrap: "none", role: "omp.welcome.wordmark" }),
						"wordmark",
					),
					keyed(
						text([span(`tui ${this.#version}`, "dim mono")], {
							wrap: "none",
							role: "omp.welcome.version",
						}),
						"version",
					),
				],
				{ role: "omp.welcome.mark" },
			),
			"mark",
		);
		const lockup = ascii
			? [mark]
			: [
					nativeImageNode(
						new TextEncoder().encode(logoSvg(theme)),
						"image/svg+xml",
						{
							alt: "lemon",
							w: LOGO_WIDTH * SVG_CELL,
							h: LEMON_LOGO.length * 2 * SVG_CELL,
							max: { w: `${LOGO_WIDTH}ch` },
						},
						"logo",
					),
					mark,
				];
		const hints = NATIVE_HINTS.map((hint) =>
			row(
				hint.keys
					? [kbd(hint.keys), text([span(hint.label, "muted")])]
					: [text([span(hint.label, "mono")])],
				{ gap: "xs", align: "center" },
			),
		);
		const described = node("card", { role: "omp.welcome" }, [
			keyed(row(lockup, { align: "center", gap: "md" }), "lockup"),
			keyed(row(hints, { gap: "md", wrap: true, align: "center" }), "hints"),
		]);
		this.#native = { key, node: described };
		return described;
	}

	invalidate(): void {
		this.#rows = undefined;
		this.#width = -1;
		this.#native = undefined;
	}
}
