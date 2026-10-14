// Colors resolve to CSS custom properties defined per theme in css/app.css,
// so every utility (bg-surface, text-muted, border-line, ...) follows the
// active light/dark theme without `dark:` variants.
const token = (name) => `rgb(var(--${name}) / <alpha-value>)`

module.exports = {
  content: ["../lib/**/*.{ex,heex}", "../priv/static/assets/js/**/*.js"],
  darkMode: ["selector", '[data-theme="dark"]'],
  theme: {
    extend: {
      colors: {
        bg: token("bg"),
        surface: token("surface"),
        "surface-2": token("surface-2"),
        elevated: token("elevated"),
        line: token("line"),
        "line-strong": token("line-strong"),
        fg: token("fg"),
        muted: token("muted"),
        subtle: token("subtle"),
        accent: token("accent"),
        "accent-fg": token("accent-fg"),
        "accent-text": token("accent-text"),
        ring: token("ring"),
        success: token("success"),
        warning: token("warning"),
        danger: token("danger"),
        info: token("info"),
        plan: token("plan")
      },
      fontFamily: {
        sans: [
          "Inter var",
          "Inter",
          "ui-sans-serif",
          "system-ui",
          "-apple-system",
          "Segoe UI",
          "Roboto",
          "Helvetica Neue",
          "Arial",
          "sans-serif"
        ],
        mono: [
          "JetBrains Mono",
          "ui-monospace",
          "SFMono-Regular",
          "Menlo",
          "Monaco",
          "Consolas",
          "Liberation Mono",
          "monospace"
        ]
      },
      fontSize: {
        "2xs": ["0.6875rem", { lineHeight: "1rem" }]
      },
      boxShadow: {
        pop: "0 1px 2px rgb(0 0 0 / 0.06), 0 8px 24px -6px rgb(0 0 0 / 0.18)",
        overlay: "0 2px 4px rgb(0 0 0 / 0.08), 0 24px 64px -12px rgb(0 0 0 / 0.35)"
      },
      keyframes: {
        "fade-in": { from: { opacity: "0" }, to: { opacity: "1" } },
        "slide-up": {
          from: { opacity: "0", transform: "translateY(6px)" },
          to: { opacity: "1", transform: "translateY(0)" }
        },
        "scale-in": {
          from: { opacity: "0", transform: "scale(0.97)" },
          to: { opacity: "1", transform: "scale(1)" }
        },
        blink: { "0%, 100%": { opacity: "1" }, "50%": { opacity: "0" } }
      },
      animation: {
        "fade-in": "fade-in 120ms ease-out",
        "slide-up": "slide-up 160ms ease-out",
        "scale-in": "scale-in 140ms ease-out",
        blink: "blink 1s step-end infinite"
      }
    }
  },
  plugins: []
}
