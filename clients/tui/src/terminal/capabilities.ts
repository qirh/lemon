import { shouldEnableHyperlinksByDefault } from "@oh-my-pi/pi-tui/terminal-capabilities";

export interface TerminalCapabilities {
	enabled: boolean;
	tern: boolean;
	hyperlinks: boolean;
	notifications: "osc9" | "osc777" | false;
}

/** Environment identity selects side channels; keyboard support is probed by pi-tui. */
export function detectTerminalCapabilities(
	env: NodeJS.ProcessEnv = process.env,
	isTTY = Boolean(process.stdout.isTTY),
): TerminalCapabilities {
	const program = env.TERM_PROGRAM?.toLowerCase() ?? "";
	const tern = Boolean(env.TERN_PANE) || program === "tern" || program === "stencil";
	const enabled = isTTY && env.TERM !== "dumb" && env.LEMON_TUI_TERMINAL_INTEGRATION !== "0";
	const notify = env.LEMON_TUI_NOTIFICATIONS !== "0";
	return {
		enabled,
		tern,
		// Reuse upstream's explicit opt-outs and multiplexer policy. Tern's
		// identity is not yet in pi-tui's catalog, but it consumes OSC 8.
		hyperlinks:
			enabled &&
			(tern ? shouldEnableHyperlinksByDefault(env, "kitty") : shouldEnableHyperlinksByDefault(env)),
		notifications:
			!enabled || !notify
				? false
				: tern || ["iterm.app", "ghostty", "wezterm", "warpterminal"].includes(program)
					? "osc9"
					: "osc777",
	};
}

/** No protocol delimiters or control characters from session/tool metadata. */
export function oscText(text: string): string {
	return text.replace(/\p{Cc}/gu, "").slice(0, 240);
}
