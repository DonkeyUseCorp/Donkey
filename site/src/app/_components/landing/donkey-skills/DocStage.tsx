"use client";

import { cn } from "@/lib/utils";
import { INV_ITEMS, SHEET_COLS, SHEET_ROWS, SHEET_TOTAL, type DocType } from "./data";
import { CAP, DOC_SURFACE, GRID4, STAGE, type DocStageProps } from "./shared";
import { usePhaseLoop } from "./usePhaseLoop";

// Spreadsheet: a clean P&L fills row by row, then totals.
function SheetDoc({ reduceMotion, loop }: DocStageProps) {
  const rows = SHEET_ROWS.length;
  const p = usePhaseLoop(rows + 3, { step: 300, reduceMotion, loop });
  const showTotal = p >= rows + 2;
  const cap =
    p <= 0
      ? "Reading sales.csv…"
      : p === 1
        ? "Cleaning 1,240 rows…"
        : p <= rows + 1
          ? `Adding ${SHEET_ROWS[p - 2][0]}`
          : p === rows + 2
            ? "Totaling columns…"
            : "Workbook ready ✓";
  const cellCls = (ci: number, extra?: string) =>
    cn(
      "min-h-[34px] px-3 flex items-center text-[13.5px] whitespace-nowrap overflow-hidden border-r border-r-[#E6DFCF] border-b border-b-[#E6DFCF] last:border-r-0",
      ci > 0 && "justify-end font-code",
      extra,
    );
  const value = (val: string) => (
    <span className="inline-block animate-[donkey-drop_0.28s_ease_both]">{val}</span>
  );
  return (
    <>
      <div className={CAP}>{cap}</div>
      <div className={DOC_SURFACE}>
        <div className="flex items-center gap-2.5 border-b-[1.5px] border-b-ink px-3 py-2 font-code text-xs bg-cream min-h-[33px]">
          <span className="italic opacity-[0.55] border border-ink rounded px-1.5">fx</span>
          <span className="text-[#0b2a6b]">{showTotal ? "=SUM(B2:B7)" : ""}</span>
        </div>
        <div className="grid auto-rows-[34px] content-start flex-1 min-h-0 overflow-hidden">
          <div className={GRID4}>
            {SHEET_COLS.map((c, i) => (
              <span key={i} className={cellCls(i, "font-bold bg-cream")}>
                {c}
              </span>
            ))}
          </div>
          {SHEET_ROWS.map((row, ri) => (
            <div
              key={ri}
              className={cn(GRID4, "transition-colors duration-[250ms] ease-out", p === ri + 2 && "bg-[#FCEAE3]")}
            >
              {row.map((val, ci) => (
                <span key={ci} className={cellCls(ci)}>
                  {p >= ri + 2 ? value(val) : ""}
                </span>
              ))}
            </div>
          ))}
          <div
            className={cn(GRID4, "transition-colors duration-[250ms] ease-out", p === rows + 2 && "bg-[#FCEAE3]")}
          >
            {SHEET_TOTAL.map((val, ci) => (
              <span key={ci} className={cellCls(ci, "font-extrabold border-t-2 border-t-ink")}>
                {showTotal ? value(val) : ""}
              </span>
            ))}
          </div>
          {Array.from({ length: 24 }).map((_, i) => (
            <div key={`fill${i}`} className={GRID4}>
              {[0, 1, 2, 3].map((ci) => (
                <span key={ci} className={cellCls(ci)} />
              ))}
            </div>
          ))}
        </div>
      </div>
    </>
  );
}

// Word: a one-page memo writes itself, block by block.
function WordDoc({ reduceMotion, loop }: DocStageProps) {
  const total = 10;
  const p = usePhaseLoop(total, { step: 360, reduceMotion, loop });
  const cap = p <= 0 ? "Opening a new doc…" : p < total ? "Drafting the memo…" : "Document ready ✓";
  const reveal = (n: number, hidden: string) =>
    cn("transition-all duration-300 ease-out", p >= n ? "opacity-100 translate-y-0" : hidden);
  const para = "text-[13.5px] leading-[1.6] mb-[13px]";
  const head = "text-[14.5px] font-extrabold mt-4 mb-[7px]";
  return (
    <>
      <div className={CAP}>{cap}</div>
      <div className={DOC_SURFACE}>
        <div className="flex items-center gap-2 border-b-[1.5px] border-b-ink px-3 py-2 font-code text-xs bg-cream">
          <span className="inline-flex items-center justify-center text-white font-extrabold rounded-[3px] bg-[#2B579A] w-[18px] h-[18px] text-xs">
            W
          </span>
          Q2_Update.docx
        </div>
        <div className="flex-1 px-7 py-6">
          <h4
            className={cn(
              "text-[21px] font-extrabold tracking-[-0.01em] mb-3.5 border-b-2 border-b-[#2B579A] pb-[7px]",
              reveal(1, "opacity-0 translate-y-[5px]"),
            )}
          >
            Q2 Board Update
          </h4>
          <p className={cn("text-xs text-[#8A8674] mt-[-8px] mb-4", reveal(1, "opacity-0"))}>
            Prepared for the Board of Directors · June 2026
          </p>
          <p className={cn(para, reveal(2, "opacity-0 translate-y-[5px]"))}>
            Revenue reached $1.85M for the quarter, up 14% from Q1, led by stronger enterprise
            renewals and two new mid-market accounts.
          </p>
          <p className={cn(para, reveal(3, "opacity-0 translate-y-[5px]"))}>
            Gross margin held at 49% as cost of goods scaled with volume, while operating expenses
            stayed essentially flat against plan.
          </p>
          <h5 className={cn(head, reveal(4, "opacity-0"))}>Highlights</h5>
          <ul className="list-disc mb-[13px] pl-5">
            {[
              "Net revenue retention climbed to 118%, a four-point gain.",
              "Average sales cycle shortened from 71 to 58 days.",
              "Cash runway extended to 22 months at the current burn.",
            ].map((item) => (
              <li
                key={item}
                className={cn("text-[13.5px] leading-[1.6]", reveal(5, "opacity-0 translate-y-[4px]"))}
              >
                {item}
              </li>
            ))}
          </ul>
          <h5 className={cn(head, reveal(6, "opacity-0"))}>Outlook</h5>
          <p className={cn(para, reveal(7, "opacity-0 translate-y-[5px]"))}>
            We expect continued momentum into Q3, with two enterprise deals in late-stage contracting
            and a pricing update planned for August.
          </p>
          <h5 className={cn(head, reveal(8, "opacity-0"))}>Risks</h5>
          <p className={cn(para, reveal(9, "opacity-0 translate-y-[5px]"))}>
            Hiring remains the gating constraint on roadmap velocity. We are prioritizing two senior
            backend roles and one product designer this quarter.
          </p>
          <p className={cn("text-[13px] italic text-[#555] mt-[18px]", reveal(9, "opacity-0"))}>
            Prepared by the Finance team.
          </p>
        </div>
      </div>
    </>
  );
}

// PDF: a generated invoice fills in header, line items, and totals.
function PdfDoc({ reduceMotion, loop }: DocStageProps) {
  const items = INV_ITEMS.length;
  const total = items + 3;
  const p = usePhaseLoop(total, { step: 320, reduceMotion, loop });
  const cap =
    p <= 0
      ? "Generating invoice…"
      : p === 1
        ? "Filling the header"
        : p <= items + 1
          ? "Adding line items…"
          : p === items + 2
            ? "Totaling…"
            : "Invoice ready ✓";
  const reveal = (n: number, hidden: string) =>
    cn("transition-all duration-300 ease-out", p >= n ? "opacity-100 translate-y-0" : hidden);
  const invtRow = "flex justify-between gap-10 min-w-[240px] text-[13px] py-1";
  return (
    <>
      <div className={CAP}>{cap}</div>
      <div className={DOC_SURFACE}>
        <div className="flex items-center gap-2 border-b-[1.5px] border-b-ink px-3 py-2 font-code text-xs bg-cream">
          <span className="inline-flex items-center justify-center text-white font-extrabold rounded-[3px] bg-[#C0392B] text-[10px] px-1.5 py-px">
            PDF
          </span>
          invoice_0142.pdf
        </div>
        <div className="flex-1 px-7 py-6">
          <div className={cn("flex justify-between items-start mb-1.5", reveal(1, "opacity-0 translate-y-[5px]"))}>
            <div className="font-extrabold text-base">Blue Harbor Logistics</div>
            <div className="font-extrabold text-[18px] text-[#C0392B] tracking-[0.03em]">
              INVOICE <span className="text-ink font-semibold text-[13px]">#0142</span>
            </div>
          </div>
          <div className={cn("text-[12.5px] text-[#666] mb-4", reveal(1, "opacity-0 translate-y-[5px]"))}>
            Bill to: Northwind Retail Co. · 480 Harbor Ave, Portland, ME
          </div>
          <div className="flex flex-col border-t-[1.5px] border-t-ink">
            <div className="grid grid-cols-[1fr_56px_92px] gap-3 py-[9px] border-b border-b-[#E6DFCF] font-bold text-[10.5px] uppercase tracking-[0.05em] text-[#999]">
              <span>Description</span>
              <span className="text-right">Qty</span>
              <span className="text-right">Amount</span>
            </div>
            {INV_ITEMS.map((it, i) => (
              <div
                key={i}
                className={cn(
                  "grid grid-cols-[1fr_56px_92px] gap-3 py-[9px] border-b border-b-[#E6DFCF] text-[13px]",
                  reveal(i + 2, "opacity-0 translate-y-[4px]"),
                )}
              >
                <span>{it[0]}</span>
                <span className="font-code text-right">{it[1]}</span>
                <span className="font-code text-right">{it[2]}</span>
              </div>
            ))}
          </div>
          <div
            className={cn(
              "flex flex-col items-end mt-2.5 border-t-2 border-t-ink pt-2",
              reveal(items + 2, "opacity-0 translate-y-[4px]"),
            )}
          >
            <div className={invtRow}>
              <span>Subtotal</span>
              <span className="font-code">$99,400</span>
            </div>
            <div className={invtRow}>
              <span>Tax (8%)</span>
              <span className="font-code">$7,952</span>
            </div>
            <div className={cn(invtRow, "font-extrabold text-[15px] border-t border-t-[#E6DFCF] mt-1 pt-2")}>
              <span>Total due</span>
              <span className="font-code text-[#C0392B]">$107,352</span>
            </div>
          </div>
          <div
            className={cn(
              "text-[11.5px] text-[#8A8674] leading-[1.5] mt-[18px] border-t border-t-[#E6DFCF] pt-2.5",
              reveal(items + 2, "opacity-0"),
            )}
          >
            Payment due within 30 days. Make checks payable to Blue Harbor Logistics, Inc. Thank you
            for your business.
          </div>
        </div>
      </div>
    </>
  );
}

export function DocStage({ docType, reduceMotion, loop }: DocStageProps & { docType: DocType }) {
  return (
    <div className={STAGE}>
      {docType === "sheet" && <SheetDoc key={`sheet${loop}`} reduceMotion={reduceMotion} loop={loop} />}
      {docType === "word" && <WordDoc key={`word${loop}`} reduceMotion={reduceMotion} loop={loop} />}
      {docType === "pdf" && <PdfDoc key={`pdf${loop}`} reduceMotion={reduceMotion} loop={loop} />}
    </div>
  );
}
