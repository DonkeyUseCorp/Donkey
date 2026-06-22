"use client";

import { Check, Copy } from "lucide-react";
import { useState } from "react";

import {
  API_ENDPOINT,
  BODY_PARAMS,
  CODE_SAMPLES,
  RESPONSE_FIELDS,
  RESPONSE_SAMPLE,
  type ApiField,
} from "@/app/donkeyvision/apiContract";
import { HighlightedCode, InlineMarkup } from "@/app/donkeyvision/codeHighlight";

function CopyButton({ value, label }: { value: string; label: string }) {
  const [copied, setCopied] = useState(false);

  return (
    <button
      type="button"
      aria-label={`Copy ${label}`}
      onClick={() => {
        void navigator.clipboard.writeText(value).then(() => {
          setCopied(true);
          setTimeout(() => setCopied(false), 1500);
        });
      }}
      className="inline-flex items-center justify-center rounded-md border border-white/20 p-1.5 text-white/70 transition hover:bg-white/10 hover:text-white"
    >
      {copied ? (
        <Check size={14} aria-hidden="true" />
      ) : (
        <Copy size={14} aria-hidden="true" />
      )}
    </button>
  );
}

function CodePanel({ children }: { children: string }) {
  return (
    <pre className="max-w-full overflow-x-auto px-4 py-4 text-xs leading-6 text-white md:text-[13px]">
      <code>
        <HighlightedCode code={children} />
      </code>
    </pre>
  );
}

function RequestExamples() {
  const [active, setActive] = useState(CODE_SAMPLES[0].key);
  const sample =
    CODE_SAMPLES.find((s) => s.key === active) ?? CODE_SAMPLES[0];

  return (
    <div className="overflow-hidden rounded-lg border-2 border-[#0F0E0D] bg-[#0F0E0D]">
      <div className="flex items-center justify-between gap-2 border-b border-white/15 pl-2 pr-3">
        <div className="flex items-center">
          {CODE_SAMPLES.map((s) => {
            const isActive = s.key === active;
            return (
              <button
                key={s.key}
                type="button"
                onClick={() => setActive(s.key)}
                aria-pressed={isActive}
                className={`relative px-3 py-3 text-sm font-semibold transition-colors ${
                  isActive
                    ? "text-white"
                    : "text-white/45 hover:text-white/75"
                }`}
              >
                {s.label}
                {isActive ? (
                  <span className="absolute inset-x-2 -bottom-px h-0.5 rounded-full bg-[#F5D875]" />
                ) : null}
              </button>
            );
          })}
        </div>
        <CopyButton value={sample.code} label={`${sample.label} request`} />
      </div>
      <CodePanel>{sample.code}</CodePanel>
    </div>
  );
}

function ResponseExample() {
  return (
    <div className="overflow-hidden rounded-lg border-2 border-[#0F0E0D] bg-[#0F0E0D]">
      <div className="flex items-center justify-between border-b border-white/15 px-4 py-2.5">
        <div className="flex items-center gap-2 text-sm font-semibold text-white">
          <span className="inline-flex items-center rounded-full bg-[#34C759]/15 px-2 py-0.5 font-mono text-xs text-[#34C759]">
            200
          </span>
          Response
        </div>
        <CopyButton value={RESPONSE_SAMPLE} label="response" />
      </div>
      <CodePanel>{RESPONSE_SAMPLE}</CodePanel>
    </div>
  );
}

function FieldList({ fields }: { fields: ApiField[] }) {
  return (
    <dl className="divide-y divide-[#0F0E0D]/10 rounded-lg border-2 border-[#0F0E0D] bg-white">
      {fields.map((field) => (
        <div key={field.name} className="px-4 py-3.5">
          <dt className="flex flex-wrap items-center gap-2">
            <span className="font-mono text-sm font-semibold text-[#0F0E0D]">
              {field.name}
            </span>
            <span className="rounded bg-[#0F0E0D]/8 px-1.5 py-0.5 font-mono text-[11px] text-[#0F0E0D]/70">
              {field.type}
            </span>
            <span
              className={`rounded px-1.5 py-0.5 text-[11px] font-semibold ${
                field.required
                  ? "bg-[#EC7868]/20 text-[#C0432F]"
                  : "bg-[#0F0E0D]/5 text-[#0F0E0D]/45"
              }`}
            >
              {field.required ? "required" : "optional"}
            </span>
          </dt>
          <dd className="mt-1 text-sm leading-6 text-[#555]">
            <InlineMarkup text={field.description} />
          </dd>
        </div>
      ))}
    </dl>
  );
}

export function ApiReference() {
  return (
    <div className="mt-16">
      {/* Endpoint */}
      <div className="flex flex-col gap-3 rounded-lg border-2 border-[#0F0E0D] bg-white p-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex min-w-0 items-center gap-3">
          <span className="inline-flex shrink-0 items-center rounded-md border-2 border-[#0F0E0D] bg-[#F5D875] px-2.5 py-1 text-xs font-bold uppercase tracking-[0.08em]">
            {API_ENDPOINT.method}
          </span>
          <code className="truncate font-mono text-sm font-semibold text-[#0F0E0D] md:text-base">
            {API_ENDPOINT.path}
          </code>
        </div>
        <p className="shrink-0 text-sm text-[#555]">
          Auth:{" "}
          <code className="rounded bg-[#0F0E0D]/8 px-1.5 py-0.5 font-mono text-[0.85em] text-[#0F0E0D]">
            Authorization: Bearer dk_live_...
          </code>
        </p>
      </div>

      <div className="mt-6 grid gap-8 lg:grid-cols-2">
        {/* Request side */}
        <div className="min-w-0">
          <h3 className="text-sm font-bold uppercase tracking-[0.12em] text-[#0F0E0D]">
            Request
          </h3>
          <p className="mt-2 text-sm leading-6 text-[#555]">
            Submit a base64 screenshot. Add an optional{" "}
            <code className="rounded bg-[#0F0E0D]/8 px-1 py-0.5 font-mono text-[0.85em] text-[#0F0E0D]">
              instruction
            </code>{" "}
            to return a matching click target.
          </p>
          <div className="mt-4">
            <RequestExamples />
          </div>
          <h4 className="mt-8 text-sm font-bold uppercase tracking-[0.12em] text-[#0F0E0D]">
            Body parameters
          </h4>
          <div className="mt-4">
            <FieldList fields={BODY_PARAMS} />
          </div>
        </div>

        {/* Response side */}
        <div className="min-w-0">
          <h3 className="text-sm font-bold uppercase tracking-[0.12em] text-[#0F0E0D]">
            Response
          </h3>
          <p className="mt-2 text-sm leading-6 text-[#555]">
            Coordinates are pixel values from the submitted screenshot, measured
            from the top-left corner.
          </p>
          <div className="mt-4">
            <ResponseExample />
          </div>
          <h4 className="mt-8 text-sm font-bold uppercase tracking-[0.12em] text-[#0F0E0D]">
            Response fields
          </h4>
          <div className="mt-4">
            <FieldList fields={RESPONSE_FIELDS} />
          </div>
        </div>
      </div>
    </div>
  );
}
