import type { LucideIcon } from "lucide-react";
import {
  BarChart3,
  FileAudio,
  FileDown,
  FileSearch,
  FileText,
  ImageIcon,
  ListMusic,
  LockKeyhole,
  ReceiptText,
} from "lucide-react";

export type UseCaseArtifact = {
  description: string;
  href: string;
  label: string;
};

export type UseCaseCategory =
  | "PDF and document work"
  | "Data and reporting"
  | "Media and images"
  | "Web and app automation";

export type UseCase = {
  artifacts?: UseCaseArtifact[];
  category: UseCaseCategory;
  description: string;
  icon: LucideIcon;
  keywords: string[];
  outcome: string;
  prompt: string;
  slug: string;
  steps: string[];
  title: string;
  videoSrc?: string;
};

export const useCaseCategories: UseCaseCategory[] = [
  "Media and images",
  "Web and app automation",
  "PDF and document work",
  "Data and reporting",
];

export const useCases: UseCase[] = [
  {
    category: "PDF and document work",
    description:
      "Merge separate invoice PDFs into one file, then stamp footer page numbers so the packet is ready to send or archive.",
    icon: FileDown,
    keywords: ["merge PDFs", "add page numbers", "invoice packet"],
    outcome: "A single six-page PDF with consistent page numbers.",
    prompt:
      "merge invoice-jan.pdf, invoice-feb.pdf and invoice-mar.pdf into one file and add page numbers",
    slug: "merge-pdfs-add-page-numbers",
    steps: [
      "Inspects the available invoice PDFs.",
      "Combines them in the requested month order.",
      "Adds footer page numbers and writes the finished PDF.",
    ],
    title: "Merge invoice PDFs and add page numbers",
  },
  {
    category: "PDF and document work",
    description:
      "Find sensitive identifiers in a contract PDF, cover each match, and flatten the output so the redactions are baked into the file.",
    icon: LockKeyhole,
    keywords: ["redact PDF", "flatten PDF", "contract redaction"],
    outcome: "A flattened contract PDF with every SSN covered.",
    prompt: "redact every Social Security number from contract.pdf and flatten the result",
    slug: "redact-and-flatten-contract",
    steps: [
      "Reads the selectable contract text.",
      "Locates each sensitive identifier.",
      "Applies redaction boxes and exports a flattened PDF.",
    ],
    title: "Redact and flatten a contract",
  },
  {
    artifacts: [
      {
        description: "The source table this task reads from.",
        href: "/use-cases/artifacts/q3-figures.txt",
        label: "q3-figures.txt",
      },
    ],
    category: "PDF and document work",
    description:
      "Extract a structured table from a PDF and save it as a clean CSV that can move into a spreadsheet or reporting workflow.",
    icon: FileSearch,
    keywords: ["PDF table extraction", "PDF to CSV", "financial table"],
    outcome: "A four-column CSV with region, revenue, growth, and churn.",
    prompt: "extract the table from q3-figures.pdf into a CSV",
    slug: "extract-table-from-pdf-to-csv",
    steps: [
      "Inspects the PDF contents.",
      "Identifies the table columns and rows.",
      "Writes a CSV with the extracted values.",
    ],
    title: "Extract a PDF table to CSV",
  },
  {
    artifacts: [
      {
        description: "The starting expense ledger.",
        href: "/use-cases/artifacts/expenses.csv",
        label: "expenses.csv",
      },
    ],
    category: "Data and reporting",
    description:
      "Read a receipt image, pull out the merchant, date, category, and total, then append the expense to an existing CSV ledger.",
    icon: ReceiptText,
    keywords: ["receipt OCR", "expense CSV", "expense tracking"],
    outcome: "A new expenses.csv row for Tartine Bakery totaling $42.18.",
    prompt: "OCR receipt.jpg, then append the merchant and total as a new row in expenses.csv",
    slug: "ocr-receipt-to-expenses",
    steps: [
      "Reads the receipt image and existing CSV schema.",
      "Extracts merchant, date, total, and category.",
      "Appends the normalized row to the ledger.",
    ],
    title: "Turn a receipt photo into an expense row",
  },
  {
    artifacts: [
      {
        description: "The raw sales data this task reads.",
        href: "/use-cases/artifacts/sales.csv",
        label: "sales.csv",
      },
    ],
    category: "Data and reporting",
    description:
      "Take raw sales rows, group revenue by month, and generate a chart image suitable for a weekly update or deck.",
    icon: BarChart3,
    keywords: ["CSV analysis", "monthly revenue chart", "bar chart"],
    outcome: "A monthly revenue bar chart saved as monthly.png.",
    prompt:
      "take sales.csv, compute the monthly revenue totals, and turn it into a bar chart saved as monthly.png",
    slug: "sales-csv-monthly-chart",
    steps: [
      "Loads the sales CSV.",
      "Groups and sums revenue by month.",
      "Renders a twelve-bar chart image.",
    ],
    title: "Create a monthly sales chart from CSV",
  },
  {
    category: "Media and images",
    description:
      "Extract audio from a meeting recording, transcribe it, and pull out action items so the follow-up is ready to share.",
    icon: FileAudio,
    keywords: ["meeting transcription", "extract audio", "action items"],
    outcome: "An MP3 file plus a transcript with five action items.",
    prompt:
      "extract the audio from meeting.mov as an mp3 and give me a transcript with the action items pulled out",
    slug: "transcribe-meeting-audio",
    steps: [
      "Extracts the movie audio as an MP3.",
      "Transcribes the spoken content.",
      "Summarizes the transcript into action items.",
    ],
    title: "Transcribe a meeting and extract action items",
  },
  {
    category: "Media and images",
    description:
      "Batch resize travel photos, strip location metadata, and make a contact sheet for fast review or sharing.",
    icon: ImageIcon,
    keywords: ["batch resize photos", "remove GPS metadata", "contact sheet"],
    outcome: "Twelve resized images with GPS removed and a 3x3 contact sheet.",
    prompt:
      "resize every photo in ~/Desktop/trip to 1080px wide, strip the GPS metadata, then make a 3x3 contact sheet",
    slug: "resize-trip-photos",
    steps: [
      "Inspects the photo folder.",
      "Resizes every image to 1080px wide.",
      "Removes GPS metadata and creates a contact sheet.",
    ],
    title: "Resize trip photos and remove GPS metadata",
  },
  {
    artifacts: [
      {
        description: "The Markdown Donkey produced.",
        href: "/use-cases/artifacts/donkeyuse.md",
        label: "donkeyuse.md",
      },
    ],
    category: "Web and app automation",
    description:
      "Capture a web page and convert the readable page content into Markdown for notes, documentation, or archival.",
    icon: FileText,
    keywords: ["website to Markdown", "web capture", "page archive"],
    outcome: "A Markdown document with the page title, sections, and feature list.",
    prompt: "give me a markdown of donkeyuse.com",
    slug: "markdown-of-donkeyuse",
    steps: [
      "Fetches the page content.",
      "Extracts the main readable structure.",
      "Writes a Markdown version of the page.",
    ],
    title: "Convert a website to Markdown",
  },
  {
    category: "Web and app automation",
    description:
      "Research a ranked song list, then drive Music to build a playlist from the results without making the user assemble it manually.",
    icon: ListMusic,
    keywords: ["Music playlist", "web research", "desktop automation"],
    outcome: "A Music playlist with the top ten songs from 2021.",
    prompt: "create a playlist with the top 10 songs from 2021",
    slug: "top-songs-2021-playlist",
    steps: [
      "Searches for a reliable top-songs list.",
      "Selects ten songs from the results.",
      "Creates the playlist in Music.",
    ],
    title: "Create a Music playlist from web research",
  },
];

export function getUseCase(slug: string) {
  return useCases.find((useCase) => useCase.slug === slug);
}

export function getUseCasesByCategory(category: UseCaseCategory) {
  return useCases.filter((useCase) => useCase.category === category);
}
