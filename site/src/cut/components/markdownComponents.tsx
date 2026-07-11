import type { Components } from "react-markdown";

// Markdown element styling shared by the two surfaces that render it: the chat
// messages (AiPanel) and the document view (DocText). Both want the same list,
// paragraph, and link treatment; each spreads this base and overrides `code`
// for its own type scale (DocText also adds headings, pre, and blockquote).
export const baseMarkdownComponents: Components = {
  p: (p) => <p className="mb-1.5 last:mb-0" {...p} />,
  ul: (p) => <ul className="mb-1.5 list-disc pl-4 last:mb-0" {...p} />,
  ol: (p) => <ol className="mb-1.5 list-decimal pl-4 last:mb-0" {...p} />,
  li: (p) => <li className="mb-0.5" {...p} />,
  a: (p) => <a className="text-[#0a84ff] underline" target="_blank" {...p} />,
};
