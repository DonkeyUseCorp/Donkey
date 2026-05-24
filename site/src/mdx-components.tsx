import type { ComponentPropsWithoutRef, ReactNode } from "react";
import type { MDXComponents } from "mdx/types";

function textFromNode(node: ReactNode): string {
  if (node === null || node === undefined || typeof node === "boolean") {
    return "";
  }

  if (typeof node === "string" || typeof node === "number") {
    return String(node);
  }

  if (Array.isArray(node)) {
    return node.map(textFromNode).join("");
  }

  if (typeof node === "object" && "props" in node) {
    const props = node.props as { children?: ReactNode };

    return textFromNode(props.children);
  }

  return "";
}

function headingId(children: ReactNode) {
  const text = textFromNode(children);

  return text
    .toLowerCase()
    .replace(/&/g, "and")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

function Heading2({ children, id, ...props }: ComponentPropsWithoutRef<"h2">) {
  return (
    <h2 id={id ?? headingId(children)} {...props}>
      {children}
    </h2>
  );
}

function Heading3({ children, id, ...props }: ComponentPropsWithoutRef<"h3">) {
  return (
    <h3 id={id ?? headingId(children)} {...props}>
      {children}
    </h3>
  );
}

function Heading4({ children, id, ...props }: ComponentPropsWithoutRef<"h4">) {
  return (
    <h4 id={id ?? headingId(children)} {...props}>
      {children}
    </h4>
  );
}

const components: MDXComponents = {
  h2: Heading2,
  h3: Heading3,
  h4: Heading4,
};

export function useMDXComponents(): MDXComponents {
  return components;
}
