import type { ReactNode } from "react";

// Lightweight, language-agnostic syntax highlighter for the API reference code
// samples (TypeScript, Swift, Python) and the JSON response. It is not a full
// grammar — it tokenizes the shapes these snippets share (comments, strings,
// numbers, keywords, JSON keys, calls) and paints them with editor-style
// colors, which is enough to read like a code editor without a dependency.

// VS Code Dark+ palette, tuned for the near-black (#0F0E0D) panel background.
const COLOR = {
  comment: "#6A9955",
  string: "#CE9178",
  number: "#B5CEA8",
  keyword: "#569CD6",
  property: "#9CDCFE",
  func: "#DCDCAA",
};

const KEYWORDS = new Set([
  // shared across the three languages used in the samples
  "const", "let", "var", "await", "async", "function", "return", "try",
  "import", "from", "new", "def", "print", "true", "false", "null",
  "True", "False", "None", "as", "in",
]);

const TOKENIZER_SOURCE =
  "(\\/\\/[^\\n]*|#[^\\n]*|\\/\\*[\\s\\S]*?\\*\\/)|(\"(?:\\\\.|[^\"\\\\])*\"(?=\\s*:))|(`(?:\\\\.|[^`\\\\])*`|\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*')|(\\b\\d+(?:\\.\\d+)?\\b)|([A-Za-z_$][\\w$]*)";

// Renders a plain string, turning `backtick` spans into inline <code> chips.
// Used for prose (feature cards, parameter descriptions) where the source copy
// marks code-like tokens with backticks.
export function InlineMarkup({ text }: { text: string }): ReactNode {
  return text.split(/(`[^`]+`)/g).map((part, i) =>
    part.startsWith("`") && part.endsWith("`") ? (
      <code
        key={i}
        className="rounded bg-[#0F0E0D]/8 px-1 py-0.5 font-mono text-[0.85em] text-[#0F0E0D]"
      >
        {part.slice(1, -1)}
      </code>
    ) : (
      part
    ),
  );
}

export function HighlightedCode({ code }: { code: string }): ReactNode {
  const tokenizer = new RegExp(TOKENIZER_SOURCE, "g");
  const nodes: ReactNode[] = [];
  let lastIndex = 0;
  let key = 0;
  let match: RegExpExecArray | null;

  while ((match = tokenizer.exec(code)) !== null) {
    if (match.index > lastIndex) {
      nodes.push(code.slice(lastIndex, match.index));
    }

    const [full, comment, property, string, number, ident] = match;
    let color: string | null = null;

    if (comment) {
      color = COLOR.comment;
    } else if (property) {
      color = COLOR.property;
    } else if (string) {
      color = COLOR.string;
    } else if (number) {
      color = COLOR.number;
    } else if (ident) {
      if (KEYWORDS.has(ident)) {
        color = COLOR.keyword;
      } else {
        // A trailing "(" makes it read as a call; otherwise leave it default.
        let j = tokenizer.lastIndex;
        while (j < code.length && /\s/.test(code[j])) j += 1;
        if (code[j] === "(") color = COLOR.func;
      }
    }

    nodes.push(
      color ? (
        <span key={key} style={{ color }}>
          {full}
        </span>
      ) : (
        full
      ),
    );
    key += 1;
    lastIndex = tokenizer.lastIndex;
  }

  if (lastIndex < code.length) {
    nodes.push(code.slice(lastIndex));
  }

  return nodes;
}
